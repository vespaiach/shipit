# shellcheck shell=bash
# shipit deploy: builds a site from GitHub and switches to it (plan §5.2): resolve the site (A), build
# a release (B), switch to it (C), prune (D). cmd_deploy calls the deploy_* steps in that order.
# site_apply_config (render the config from `current`, plan §5.5) and site_restart_and_check (restart
# and health check, C.3) are shared with revert and rollback.
# Sourcing this file only defines constants and functions. Needs lib/common.sh.

# shellcheck source=lib/config.sh
. "${BASH_SOURCE[0]%/*}/config.sh"

# The PATH every repo command runs with (plus HOME=/srv/<name>/home and LANG, nothing else).
BUILD_PATH=/usr/local/bin:/usr/bin:/bin
# The health check after a node/nextjs restart (plan §5.2 C.3): polled every HEALTH_INTERVAL seconds
# for up to HEALTH_TIMEOUT seconds; each request may take up to HEALTH_MAX_TIME seconds.
HEALTH_TIMEOUT=60
HEALTH_INTERVAL=1
HEALTH_MAX_TIME=5
# The two site users' shell, and how deploy recognises users it made: their GECOS (`comment`) field.
NOLOGIN=/usr/sbin/nologin
DEPLOY_USAGE='Usage: shipit deploy <name> [ref], or shipit deploy <repo-url> <name> [ref] for a first deploy.'
# A release folder's name: <UTC time>-<full sha>. The time sorts lexically.
RELEASE_RE='^[0-9]{8}T[0-9]{6}Z-([0-9a-f]{40})$'

# Run as <name>-build (or by root, to check the file, with `true` as the command): reads the env file's
# KEY=value lines on stdin, exports them, then runs the command with stdin from /dev/null. Blank lines
# and lines starting with # or ; are skipped. The value is literal, except that spaces and tabs around
# it, then one pair of matching quotes around all of it, are removed (as systemd's EnvironmentFile=
# does; no escapes). $0 is the file's name, for messages.
# shellcheck disable=SC2016,SC1003 # expanded by sh, not here; '\'' is a quote inside the script
ENV_EXEC='n=0
while IFS= read -r line || [ -n "$line" ]; do
  n=$((n + 1))
  case $line in "" | "#"* | ";"*) continue ;; esac
  key=${line%%=*}
  case $key in
    "$line" | "" | [0-9]* | *[!A-Za-z0-9_]*)
      echo "Line $n of $0 isn'\''t KEY=value (KEY: letters, digits and _, not starting with a digit)." >&2
      exit 1
      ;;
  esac
  value=${line#*=}
  value=${value#"${value%%[! 	]*}"}
  value=${value%"${value##*[! 	]}"}
  case $value in \"*\" | \'\''*\'\'') value=${value#?} value=${value%?} ;; esac
  export "$key=$value"
done
exec "$@" </dev/null'

# Run as <name>-build: runs the command line $2 with sh, in the folder $1.
# shellcheck disable=SC2016 # expanded by sh, not here
RUN_IN='cd "$1" || exit 1
exec sh -c "$2"'

# This deploy's state.
SITE='' URL='' REF='' SITE_DIR='' BUILD_USER='' DEPLOY_TMP='' GIT_URL='' SHA=''
RELEASE='' RELEASE_DIR='' SWITCHED='' OLD_CURRENT='' OLD_PREVIOUS='' SITE_LOCK_FD=''
GIT_ENV=(GIT_TERMINAL_PROMPT=0)

# ---- Small parsers and checks (unit-tested) ------------------------------------------------------

# deploy_args <arg>...: sets SITE, URL (empty for the name form) and REF (empty: the default branch),
# validating each. The URL form is recognised by its https:// prefix.
deploy_args() {
  URL='' REF=''
  if [[ ${1-} == https://* ]]; then
    URL=$1
    shift
    check_repo_url "$URL" || return 1
  fi
  if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    err "$DEPLOY_USAGE"
    return 1
  fi
  SITE=$1
  check_site_name "$SITE" || return 1
  if [ "$#" -eq 2 ]; then
    REF=$2
    check_ref "$REF" || return 1
  fi
}

# same_repo <url> <url>: both name the same GitHub repo; .git and letter case don't matter.
same_repo() {
  local a b
  a=$(repo_slug "$1") b=$(repo_slug "$2")
  [ "${a,,}" = "${b,,}" ]
}

# default_branch: reads `git ls-remote --symref <url> HEAD` on stdin and prints the branch HEAD names.
default_branch() {
  awk '$1 == "ref:" && $3 == "HEAD" && $2 ~ /^refs\/heads\// { sub(/^refs\/heads\//, "", $2); print $2; found = 1; exit } END { exit !found }'
}

# install_default: reads the names at the commit's root on stdin and prints node.install's default
# (plan §3), by lockfile; `npm install` for a package.json without one; nothing without package.json.
install_default() {
  local names
  names=$(cat)
  if grep -qxF package-lock.json <<<"$names"; then
    echo 'npm ci'
  elif grep -qxF pnpm-lock.yaml <<<"$names"; then
    echo 'pnpm install --frozen-lockfile'
  elif grep -qxF yarn.lock <<<"$names"; then
    echo 'yarn install --immutable'
  elif grep -qxF package.json <<<"$names"; then
    echo 'npm install'
  fi
}

# build_default: reads package.json on stdin and prints node.build's default: `npm run build` when its
# scripts have a build, else nothing. Read as data with jq; a broken file means no build script.
build_default() {
  if jq -e '.scripts.build | type == "string"' >/dev/null 2>&1; then
    echo 'npm run build'
  fi
}

# missing_env_keys <env file> <key>...: prints the keys that have no KEY= line in the env file (read
# as data; a missing file has none).
missing_env_keys() {
  local file=$1 key
  shift
  for key; do
    if [ -f "$file" ] && grep -q -E "^$key=" -- "$file"; then continue; fi
    printf '%s\n' "$key"
  done
}

# release_name <UTC time> <sha>
release_name() { printf '%s-%s\n' "$1" "$2"; }

# release_sha <release name>: prints the full SHA in a release folder's name; fails on any other name.
release_sha() {
  local LC_ALL=C
  [[ $1 =~ $RELEASE_RE ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

# path_resolve <absolute path>: prints the path with every symlink followed, like `realpath -m`
# (missing parts are fine), using only readlink. Fails after 40 links (a loop).
path_resolve() {
  local rest=$1 out='' comp target n=0
  [[ $rest == /* ]] || return 1
  while [ -n "$rest" ]; do
    comp=${rest%%/*}
    if [ "$comp" = "$rest" ]; then rest=''; else rest=${rest#*/}; fi
    case $comp in
      '' | .) continue ;;
      ..)
        out=${out%/*}
        continue
        ;;
    esac
    if [ -L "$out/$comp" ]; then
      n=$((n + 1))
      [ "$n" -le 40 ] || return 1
      # The trailing . keeps a target's own trailing newlines.
      target=$(readlink -- "$out/$comp" && echo .) || return 1
      target=${target%.}
      target=${target%$'\n'}
      if [[ $target == /* ]]; then out=''; fi
      rest=$target${rest:+/$rest}
      continue
    fi
    out=$out/$comp
  done
  printf '%s\n' "${out:-/}"
}

# static_root_check <release folder> <root>: the release has the folder <root>, reached without
# symlinks, and no symlink inside it points outside it (plan §4), so Caddy serves only that folder.
static_root_check() {
  local release=$1 root=$2 dir base link target
  local -a links
  dir=$release/$root
  base=$(path_resolve "$dir") || base=''
  if [ ! -d "$dir" ] || [ -L "$dir" ] || [ "$base" != "$(path_resolve "$release")/$root" ]; then
    err "The release has no folder $root (static.root in shipit.ini), or it's a symlink. Check that the build writes $root."
    return 1
  fi
  mapfile -d '' links < <(find -P "$dir" -type l -print0)
  for link in "${links[@]}"; do
    if ! target=$(path_resolve "$link") || [[ $target != "$base" && $target != "$base"/* ]]; then
      err "$(printf '%q' "${link#"$release"/}") is a symlink to somewhere outside $root, so Caddy could serve another site's files. Remove it, or point it inside $root."
      return 1
    fi
  done
}

# prune_releases <current> <previous>: reads release folder names on stdin and prints those to delete:
# every release name but the two given.
prune_releases() {
  local name
  while IFS= read -r name; do
    release_sha "$name" >/dev/null || continue
    [ "$name" = "$1" ] || [ "$name" = "$2" ] || printf '%s\n' "$name"
  done
}

# prune_refs <kept release>...: reads refs/shipit/<sha> names on stdin and prints those no kept
# release has the SHA of (plan §5.2 D). Pins left by failed builds go too.
prune_refs() {
  local ref name keep=' '
  for name; do keep+="$(release_sha "$name") "; done
  while IFS= read -r ref; do
    [[ $ref =~ ^refs/shipit/([0-9a-f]{40})$ ]] || continue
    [[ $keep == *" ${BASH_REMATCH[1]} "* ]] || printf '%s\n' "$ref"
  done
}

# site_user_state <user> <comment>: prints missing, shipit (its GECOS field is <comment>, so deploy
# made it) or other.
site_user_state() {
  local entry gecos
  if ! entry=$(getent passwd "$1"); then
    echo missing
    return 0
  fi
  IFS=: read -r _ _ _ _ gecos _ <<<"$entry"
  if [ "$gecos" = "$2" ]; then echo shipit; else echo other; fi
}

# ---- Running things as the build user ------------------------------------------------------------

# as_build <command> [arg]...: runs a command as <name>-build with umask 027, a clean environment
# and stdin as given, after dropping every lock (a process the build leaves behind can't hold one).
as_build() {
  (
    lock_close_all
    cd / || exit 1
    exec runuser -u "$BUILD_USER" -- env -i HOME="$SITE_DIR/home" PATH="$BUILD_PATH" LANG=C.UTF-8 \
      sh -c 'umask 027 && exec "$@"' as_build "$@"
  )
}

# git_remote <git args>: git as the build user, with GIT_ENV (no prompts; the deploy key with SSH).
git_remote() { as_build env "${GIT_ENV[@]}" git "$@"; }

# git_build <git args>: the same, in the site's repo.git.
git_build() { git_remote -C "$SITE_DIR/repo.git" "$@"; }

# site_ini <sha> <file>: copies shipit.ini at that commit into a root-owned file (the build user's git
# writes to root's redirect) and loads it with ini_load (plan §3).
site_ini() {
  if ! git_build show "$1:shipit.ini" >"$2" 2>/dev/null </dev/null; then
    err "Commit $1 has no shipit.ini at the root of the repo. Add one (see docs/plan.md section 3)."
    return 1
  fi
  ini_load "$2"
}

# link_target <link>: prints where a site link (current, previous) points, releases/<name>; nothing
# when the link is missing. Fails on anything shipit wouldn't have made.
link_target() {
  local target
  [ -e "$1" ] || [ -L "$1" ] || return 0
  if [ -L "$1" ] && target=$(readlink -- "$1") && release_sha "${target#releases/}" >/dev/null \
    && [[ $target == releases/* ]]; then
    printf '%s\n' "$target"
    return 0
  fi
  err "$1 isn't a link to a release, so shipit won't touch it. Remove it by hand."
  return 1
}

# ---- Caddy ---------------------------------------------------------------------------------------

# render_site_caddy <template> <VAR>...: prints a site's Caddy file: the shared log snippet, the
# site's block (the template, with SITE, DOMAIN, SRV_ROOT and the VARs listed), then one redirect
# block per alias. Values come from INI_* (a loaded shipit.ini).
render_site_caddy() {
  # shellcheck disable=SC2034 # read by render
  local template=$1 DOMAIN=$INI_DOMAIN ROOT=$INI_ROOT ALIAS
  shift
  render "$SHIPIT_TEMPLATES/site-log.caddy" SITE SRV_ROOT LOG_ROOT || return 1
  render "$SHIPIT_TEMPLATES/$template" SITE DOMAIN SRV_ROOT "$@" || return 1
  # shellcheck disable=SC2034 # read by render
  for ALIAS in "${INI_ALIASES[@]}"; do
    render "$SHIPIT_TEMPLATES/site-alias.caddy" SITE DOMAIN ALIAS || return 1
  done
}

# site_caddy_check <file>: validates the site's Caddy file as caddy (validating opens the log file,
# plan §5.1 step 4).
site_caddy_check() {
  local out
  chmod 644 "$1"
  if ! out=$(runuser -u caddy -- caddy validate --config "$1" --adapter caddyfile 2>&1); then
    err "$out"
    err "The Caddy file for $SITE didn't pass caddy validate, so it wasn't installed."
    return 1
  fi
}

# site_caddy_install <file>: installs the checked Caddy file if it changed, and reloads Caddy (never
# restarts it) if so.
site_caddy_install() {
  local dest=$CADDY_ETC/sites/$SITE.caddy
  if install_if_changed "$1" "$dest" 644; then
    if ! systemctl reload caddy; then
      err "Reloading Caddy failed. Check: systemctl status caddy"
      return 1
    fi
    log "Wrote $dest and reloaded Caddy."
  fi
}

# ---- The unit (node, nextjs) ---------------------------------------------------------------------

# render_site_unit: prints a node/nextjs site's unit: site.service (with PORT from CONF_PORT and
# START from node.start), then site-data.service when shipit.ini has data.dir entries (StateDirectory=
# shipit-<name> and shipit-<name>/<dir> for each), then site-nextjs.service for nextjs. The parts
# after the first only add lines to its [Service] section, which comes last. Values come from INI_*.
render_site_unit() {
  # shellcheck disable=SC2034 # read by render
  local PORT=$CONF_PORT START=$INI_START STATE_DIRS dir
  render "$SHIPIT_TEMPLATES/site.service" SITE SRV_ROOT SHIPIT_ETC PORT START || return 1
  if [ "${#INI_DIRS[@]}" -gt 0 ]; then
    STATE_DIRS=shipit-$SITE
    for dir in "${INI_DIRS[@]}"; do STATE_DIRS+=" shipit-$SITE/$dir"; done
    render "$SHIPIT_TEMPLATES/site-data.service" SITE STATE_DIRS || return 1
  fi
  if [ "$INI_TYPE" = nextjs ]; then
    render "$SHIPIT_TEMPLATES/site-nextjs.service" SITE || return 1
  fi
}

# site_unit_check <file>: the unit file (named shipit-<name>.service, as systemd-analyze needs) passes
# systemd-analyze verify, and the installed unit, if any, is shipit's.
site_unit_check() {
  local dest=$SYSTEMD_DIR/shipit-$SITE.service out
  if [ -e "$dest" ] && ! is_shipit_file "$dest"; then
    err "$dest wasn't written by shipit, so it wasn't replaced. Move it away, then run the deploy again."
    return 1
  fi
  if ! out=$(systemd-analyze verify "$1" 2>&1); then
    err "$out"
    err "The unit for $SITE didn't pass systemd-analyze verify, so it wasn't installed."
    return 1
  fi
}

# site_unit_install <file>: installs the checked unit if it changed, then daemon-reload, and enables it
# (idempotent), so the site comes back after a reboot.
site_unit_install() {
  local dest=$SYSTEMD_DIR/shipit-$SITE.service
  if install_if_changed "$1" "$dest" 644; then
    if ! systemctl daemon-reload; then
      err "systemctl daemon-reload failed. Check: journalctl -u init.scope"
      return 1
    fi
    log "Wrote $dest and reloaded systemd."
  fi
  if ! systemctl enable --quiet "shipit-$SITE"; then
    err "Enabling shipit-$SITE failed. Check: systemctl status shipit-$SITE"
    return 1
  fi
}

# site_unit_remove: stops, disables and deletes the site's unit (a failed first deploy).
site_unit_remove() {
  local dest=$SYSTEMD_DIR/shipit-$SITE.service
  [ -e "$dest" ] && is_shipit_file "$dest" || return 0
  systemctl stop "shipit-$SITE" || err "Stopping shipit-$SITE failed."
  systemctl disable --quiet "shipit-$SITE" || err "Disabling shipit-$SITE failed."
  rm -f -- "$dest"
  systemctl daemon-reload || err "systemctl daemon-reload failed."
}

# site_health_check: polls http://127.0.0.1:<PORT><site.health> with Host: <site.domain> until
# health_ok accepts the status (exactly 200 when site.health is set) or HEALTH_TIMEOUT runs out.
# Values come from INI_* and CONF_PORT.
site_health_check() {
  local url=http://127.0.0.1:$CONF_PORT$INI_HEALTH code need='a status below 500'
  local end=$((SECONDS + HEALTH_TIMEOUT))
  [ -z "$INI_HEALTH_STRICT" ] || need=200
  while :; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$HEALTH_MAX_TIME" \
      -H "Host: $INI_DOMAIN" "$url" </dev/null) || true
    if health_ok "$code" "$INI_HEALTH_STRICT"; then
      log "$url answered $code."
      return 0
    fi
    [ "$SECONDS" -lt "$end" ] || break
    sleep "$HEALTH_INTERVAL"
  done
  [[ $code =~ ^[1-5][0-9][0-9]$ ]] && code="answered $code" || code='gave no answer'
  err "$url (Host: $INI_DOMAIN) $code within $HEALTH_TIMEOUT s; it needs $need. Check: journalctl -u shipit-$SITE"
  return 1
}

# site_restart_and_check: after site_apply_config, restarts a node/nextjs site and health-checks it
# (plan §5.2 C.3). nextjs: stop, empty the cache, start, so a release never sees another's cache.
# Static: nothing to do. Fails if the restart or the health check does. Shared with revert and
# rollback.
site_restart_and_check() {
  local unit=shipit-$SITE
  case "$INI_TYPE" in
    static) return 0 ;;
    node) systemctl restart "$unit" || {
      err "Restarting $unit failed. Check: journalctl -u $unit"
      return 1
    } ;;
    nextjs)
      if ! systemctl stop "$unit" || ! systemctl clean --what=cache "$unit" || ! systemctl start "$unit"; then
        err "Restarting $unit failed. Check: journalctl -u $unit"
        return 1
      fi
      ;;
  esac
  log "Restarted $unit."
  site_health_check
}

# site_apply_config: renders the site's config from the shipit.ini of the release `current` points at,
# checked again as in plan §3 (with the clash check), validates all of it, installs it, and writes
# TYPE, DOMAIN and ALIASES to <name>.conf (plan §5.5). node/nextjs: the unit too, and a proxy to PORT.
# Used after every switch, revert and rollback; site_restart_and_check follows it.
site_apply_config() {
  local target sha caddy=$DEPLOY_TMP/site.caddy unit=$DEPLOY_TMP/unit/shipit-$SITE.service PORT
  target=$(link_target "$SITE_DIR/current") || return 1
  if [ -z "$target" ]; then
    err "$SITE_DIR/current is missing."
    return 1
  fi
  sha=$(release_sha "${target#releases/}") || return 1
  site_ini "$sha" "$DEPLOY_TMP/current.ini" || return 1
  ini_check_name "$SITE" no || return 1
  ini_check_clash "$SITE" || return 1
  if [ "$INI_TYPE" = static ]; then
    render_site_caddy site-static.caddy ROOT >"$caddy" || return 1
  else
    # shellcheck disable=SC2034 # read by render
    PORT=$CONF_PORT
    mkdir -p -- "$DEPLOY_TMP/unit"
    render_site_caddy site-proxy.caddy PORT >"$caddy" || return 1
    render_site_unit >"$unit" || return 1
    site_unit_check "$unit" || return 1
  fi
  site_caddy_check "$caddy" || return 1
  if [ "$INI_TYPE" != static ]; then
    site_unit_install "$unit" || return 1
  fi
  site_caddy_install "$caddy" || return 1
  # shellcheck disable=SC2034 # written by site_conf_write
  CONF_TYPE=$INI_TYPE CONF_DOMAIN=$INI_DOMAIN CONF_ALIASES=("${INI_ALIASES[@]}")
  site_conf_write "$SITE"
}

# ---- A. Resolve the site -------------------------------------------------------------------------

# site_dir <path> <owner:group> <mode>. A folder under a setgid one inherits the bit, and GNU chmod
# keeps it for a 3- or 4-digit mode, so modes without it are given with 5 digits (00700).
site_dir() {
  if ! mkdir -p -- "$1" || ! chown -- "$2" "$1" || ! chmod -- "$3" "$1"; then
    die "Couldn't set up $1."
  fi
}

# site_users: the two site users (plan §4). Refuses, before creating either, if one exists and
# deploy didn't make it.
site_users() {
  local user comment
  for user in "$SITE" "$BUILD_USER"; do
    comment="shipit site $SITE"
    [ "$user" = "$SITE" ] || comment="shipit build $SITE"
    if [ "$(site_user_state "$user" "$comment")" = other ]; then
      die "A user named $user already exists, and shipit didn't create it, so the site can't be called $SITE. Pick another name."
    fi
  done
  if [ "$(site_user_state "$SITE" "shipit site $SITE")" = missing ]; then
    useradd --system --user-group --no-create-home --home-dir /nonexistent --shell "$NOLOGIN" \
      --comment "shipit site $SITE" "$SITE" || die "Creating the user $SITE failed."
    log "Created the user $SITE."
  fi
  if [ "$(site_user_state "$BUILD_USER" "shipit build $SITE")" = missing ]; then
    useradd --system --gid "$SITE" --no-create-home --home-dir "$SITE_DIR/home" --shell "$NOLOGIN" \
      --comment "shipit build $SITE" "$BUILD_USER" || die "Creating the user $BUILD_USER failed."
    log "Created the user $BUILD_USER."
  fi
}

# site_dirs: the root-owned /srv/<name> skeleton and the log folder (plan §4). Every deploy re-checks
# them, so a first deploy that stopped half-way resumes.
site_dirs() {
  site_dir "$SITE_DIR" "root:$SITE" 2750
  site_dir "$SITE_DIR/releases" "root:$SITE" 2750
  site_dir "$SITE_DIR/home" "$BUILD_USER:$SITE" 00700
  site_dir "$SITE_DIR/.ssh" "$BUILD_USER:$SITE" 00700
  site_dir "$SITE_DIR/repo.git" "$BUILD_USER:$SITE" 00700
  site_dir "$LOG_ROOT/$SITE" caddy:caddy 750
}

# A.1: loads <name>.conf, or registers a new site (users, folders, a conf with REPO only).
deploy_resolve() {
  local conf=$SHIPIT_ETC/sites/$SITE.conf
  if [ -e "$conf" ]; then
    conf_parse "$conf" || die "Fix $conf, then run the deploy again."
    if [ -n "$URL" ] && ! same_repo "$URL" "$CONF_REPO"; then
      die "The site $SITE is deployed from $CONF_REPO, not $URL. Pick another name for this repo, or run: shipit deploy $SITE"
    fi
    site_users
    site_dirs
    return 0
  fi
  if [ -z "$URL" ]; then
    site_conf_read "$SITE" || exit 1
  fi
  site_users
  site_dirs
  # shellcheck disable=SC2034 # written by site_conf_write
  CONF_REPO=$URL CONF_TYPE='' CONF_DOMAIN='' CONF_PORT='' CONF_ALIASES=()
  site_conf_write "$SITE" || die "Couldn't write $conf."
  log "Registered the site $SITE ($URL) in $conf."
}

# git_ssh_command <key file>: the deploy key only, never asking, and only GitHub's pinned host keys.
git_ssh_command() {
  printf 'ssh -i %q -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=%q -o GlobalKnownHostsFile=/dev/null\n' \
    "$1" "$SHIPIT_TEMPLATES/github_known_hosts"
}

# use_key: fetch over SSH with the site's deploy key.
use_key() {
  GIT_URL=$(repo_ssh_url "$CONF_REPO")
  GIT_ENV=(GIT_TERMINAL_PROMPT=0 "GIT_SSH_COMMAND=$(git_ssh_command "$SITE_DIR/.ssh/id_ed25519")")
}

# remote_head: `git ls-remote --symref` of GIT_URL's HEAD, into $DEPLOY_TMP/head.
remote_head() {
  git_remote ls-remote --symref "$GIT_URL" HEAD >"$DEPLOY_TMP/head" 2>/dev/null </dev/null
}

# A.2: how git reaches the repo. Until the first deploy succeeds (no TYPE yet): HTTPS without
# credentials if that works (public), else SSH with the deploy key, made if missing. Later: SSH if the
# site has a deploy key, else HTTPS.
deploy_access() {
  local key=$SITE_DIR/.ssh/id_ed25519 pub
  GIT_URL=$CONF_REPO
  GIT_ENV=(GIT_TERMINAL_PROMPT=0)
  if [ -n "$CONF_TYPE" ]; then
    if as_build test -f "$key" </dev/null; then use_key; fi
    return 0
  fi
  if remote_head; then
    # Public: a key left by an earlier try isn't needed, and later deploys use HTTPS without it.
    as_build rm -f -- "$key" "$key.pub" </dev/null || true
    return 0
  fi
  # shellcheck disable=SC2016 # expanded by the build user's sh
  as_build sh -c '[ -f "$1" ] || ssh-keygen -q -t ed25519 -N "" -C "$2" -f "$1"' keygen "$key" \
    "shipit-$SITE" </dev/null >/dev/null || die "Creating the deploy key $key failed."
  use_key
  remote_head && return 0
  pub=$(as_build cat -- "$key.pub" </dev/null) || pub=''
  [[ $pub =~ ^ssh-ed25519\ [A-Za-z0-9+/]+=*(\ [[:print:]]*)?$ ]] || pub="(couldn't read $key.pub)"
  log "$pub"
  die "Can't fetch $CONF_REPO. If it's a private repo, add this key as a read-only deploy key at https://github.com/$(repo_slug "$CONF_REPO")/settings/keys/new, then run the same command again."
}

# A.3: fetches, resolves the ref to a full SHA, and checks shipit.ini at that commit.
deploy_fetch() {
  local rev=$REF branch first=no env=$SHIPIT_ETC/sites/$SITE.env missing
  [ -n "$CONF_TYPE" ] || first=yes
  if [ -z "$rev" ]; then
    { [ -s "$DEPLOY_TMP/head" ] || remote_head; } \
      || die "Can't reach $CONF_REPO to find its default branch. Check the network, or give a ref."
    if ! branch=$(default_branch <"$DEPLOY_TMP/head") || ! check_ref "$branch"; then
      die "Couldn't find the default branch of $CONF_REPO. Give a ref: shipit deploy $SITE <ref>"
    fi
    rev=refs/heads/$branch
  fi
  if ! as_build test -f "$SITE_DIR/repo.git/HEAD" </dev/null; then
    git_build init --quiet --bare </dev/null >/dev/null || die "Creating $SITE_DIR/repo.git failed."
  fi
  log "Fetching $CONF_REPO."
  git_build fetch --quiet --prune "$GIT_URL" '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*' \
    </dev/null || die "Fetching $CONF_REPO failed. Check the network and the repo's access, then run the deploy again."
  SHA=$(git_build rev-parse --verify --quiet --end-of-options "$rev^{commit}" </dev/null) || SHA=''
  [[ $SHA =~ ^[0-9a-f]{40}$ ]] \
    || die "Can't find ${REF:-$branch} in $CONF_REPO. Use a branch, a tag, or the full SHA of a commit on one."

  site_ini "$SHA" "$DEPLOY_TMP/shipit.ini" || die "Fix shipit.ini, then run the deploy again."
  ini_check_name "$SITE" "$first" || exit 1
  [ "$first" = yes ] || ini_check_type "$CONF_TYPE" || exit 1
  ini_check_clash "$SITE" || exit 1
  if [ -e "$env" ]; then
    # shellcheck disable=SC2094 # $0 is only the file's name, for messages
    sh -c "$ENV_EXEC" "$env" true <"$env" || die "Fix $env, then run the deploy again."
  fi
  missing=$(missing_env_keys "$env" "${INI_ENV[@]}")
  if [ -n "$missing" ]; then
    die "$env is missing ${missing//$'\n'/, }, which site.env in shipit.ini needs. Add them as KEY=value lines, then run the deploy again."
  fi
}

# ---- B. Build ------------------------------------------------------------------------------------

# release_create: root creates releases/<UTC>-<sha> and hands it to the build user. A name that's
# taken (the same commit within one second) waits a second for a new one.
release_create() {
  local try
  for try in 1 2; do
    RELEASE=$(release_name "$(date -u +%Y%m%dT%H%M%SZ)" "$SHA")
    if mkdir -- "$SITE_DIR/releases/$RELEASE" 2>/dev/null; then
      RELEASE_DIR=$SITE_DIR/releases/$RELEASE
      if ! chown -- "$BUILD_USER:$SITE" "$RELEASE_DIR" || ! chmod -- 2750 "$RELEASE_DIR"; then
        die "Couldn't set up $RELEASE_DIR."
      fi
      return 0
    fi
    [ "$try" = 2 ] || sleep 1
  done
  die "Couldn't create a release folder in $SITE_DIR/releases."
}

# B.2: runs the install step without secrets, then the build step with the env file on stdin.
release_commands() {
  local names install build env=$SHIPIT_ETC/sites/$SITE.env
  names=$(git_build ls-tree --name-only "$SHA" </dev/null) || die "Reading commit $SHA failed."
  install=${INI_INSTALL:-$(install_default <<<"$names")}
  build=$INI_BUILD
  if [ -z "$build" ] && grep -qxF package.json <<<"$names"; then
    build=$(git_build show "$SHA:package.json" </dev/null 2>/dev/null | build_default) || build=''
  fi
  if [ -n "$install" ]; then
    log "Install: $install"
    as_build sh -c "$RUN_IN" run "$RELEASE_DIR" "$install" </dev/null \
      || die "The install step ($install) failed, so the release was deleted and the site wasn't changed."
  fi
  if [ -n "$build" ]; then
    log "Build: $build"
    [ -e "$env" ] || env=/dev/null
    # shellcheck disable=SC2094 # $0 is only the file's name, for messages
    as_build sh -c "$ENV_EXEC" "$env" sh -c "$RUN_IN" run "$RELEASE_DIR" "$build" <"$env" \
      || die "The build step ($build) failed, so the release was deleted and the site wasn't changed."
  fi
}

# deploy_port: a node/nextjs site's first deploy gets the lowest free port (decision 25), written to
# <name>.conf next to REPO at once. It runs under build.lock, which every deploy takes, so two first
# deploys of different sites can't pick the same port. Later deploys (and reruns) keep CONF_PORT.
deploy_port() {
  [ "$INI_TYPE" != static ] && [ -z "$CONF_PORT" ] || return 0
  CONF_PORT=$(site_next_port) || exit 1
  site_conf_write "$SITE" || die "Couldn't write $SHIPIT_ETC/sites/$SITE.conf."
  log "Gave $SITE the port $CONF_PORT."
}

# B.3, nextjs: the release's .next/cache (the build cache) becomes a link to the site's cache folder,
# which systemd makes (CacheDirectory=), so `next start` can write its image and ISR cache there.
release_nextjs_cache() {
  # shellcheck disable=SC2016 # expanded by the build user's sh
  as_build sh -c 'cd "$1" && rm -rf .next/cache && mkdir -p .next && ln -s "$2" .next/cache' \
    nextcache "$RELEASE_DIR" "$CACHE_ROOT/shipit-$SITE" </dev/null \
    || die "Linking .next/cache to $CACHE_ROOT/shipit-$SITE failed."
}

# B: builds the release under build.lock, then takes it back and, for a static site, checks <root> and
# gives Caddy read access to it.
deploy_build() {
  lock_wait "$SHIPIT_VAR/build.lock" "Another site is building; waiting." \
    || die "Couldn't take $SHIPIT_VAR/build.lock."
  deploy_port
  release_create
  log "Building $SHA in $RELEASE_DIR."
  # shellcheck disable=SC2016 # expanded by the build user's bash
  as_build bash -c 'set -o pipefail && git -C "$1" archive --format=tar "$2" | tar -x -f - -C "$3"' \
    extract "$SITE_DIR/repo.git" "$SHA" "$RELEASE_DIR" </dev/null || die "Extracting $SHA failed."
  git_build update-ref "refs/shipit/$SHA" "$SHA" </dev/null || die "Pinning $SHA in repo.git failed."
  release_commands
  [ "$INI_TYPE" != nextjs ] || release_nextjs_cache
  # A process the build left running could still write to the release through files it holds open.
  pkill -KILL -u "$BUILD_USER" 2>/dev/null || true
  chown -R -- "root:$SITE" "$RELEASE_DIR" || die "Taking back $RELEASE_DIR (chown) failed."
  if [ "$INI_TYPE" = static ]; then
    static_root_check "$RELEASE_DIR" "$INI_ROOT" || die "Refused the release; the site wasn't changed."
    if ! setfacl -m u:caddy:x -- "$SITE_DIR" "$SITE_DIR/releases" "$RELEASE_DIR" \
      || ! setfacl -R -P -m u:caddy:rX -- "$RELEASE_DIR/$INI_ROOT"; then
      die "Giving Caddy access to $RELEASE_DIR/$INI_ROOT (setfacl) failed."
    fi
  fi
  lock_release
}

# ---- C. Switch -----------------------------------------------------------------------------------

# C.1: previous -> old current, current -> the new release; both relative, both atomic.
deploy_switch() {
  OLD_CURRENT=$(link_target "$SITE_DIR/current") || exit 1
  OLD_PREVIOUS=$(link_target "$SITE_DIR/previous") || exit 1
  if [ -n "$OLD_CURRENT" ]; then
    atomic_link "$OLD_CURRENT" "$SITE_DIR/previous" || die "Switching $SITE_DIR/previous failed."
  fi
  SWITCHED=1
  if ! atomic_link "releases/$RELEASE" "$SITE_DIR/current"; then
    deploy_revert "Switching $SITE_DIR/current failed"
  fi
}

# C.4 revert <reason>: puts current and previous back, re-renders from the restored release, restarts
# it, deletes the failed one and exits non-zero. A first deploy leaves nothing served: the unit is
# stopped, disabled and deleted, and <name>.conf goes back to REPO (and PORT), so a rerun starts over.
deploy_revert() {
  local caddy=$CADDY_ETC/sites/$SITE.caddy
  if [ -z "$OLD_CURRENT" ]; then
    site_unit_remove
    rm -f -- "$SITE_DIR/current"
    if [ -e "$caddy" ] && is_shipit_file "$caddy"; then
      rm -f -- "$caddy"
      systemctl reload caddy || err "Reloading Caddy failed. Check: systemctl status caddy"
    fi
    rm -rf -- "$RELEASE_DIR"
    # shellcheck disable=SC2034 # written by site_conf_write
    CONF_TYPE='' CONF_DOMAIN='' CONF_ALIASES=()
    site_conf_write "$SITE" || err "Couldn't write $SHIPIT_ETC/sites/$SITE.conf."
    die "First deploy of $SITE failed; nothing is served."
  fi
  atomic_link "$OLD_CURRENT" "$SITE_DIR/current" || die "Switching $SITE_DIR/current back failed."
  if [ -n "$OLD_PREVIOUS" ]; then
    atomic_link "$OLD_PREVIOUS" "$SITE_DIR/previous"
  else
    rm -f -- "$SITE_DIR/previous"
  fi
  if ! site_apply_config; then
    err "Installing the config of ${OLD_CURRENT#releases/} again failed too; fix the error above."
  elif ! site_restart_and_check; then
    err "${OLD_CURRENT#releases/} didn't come back up either; fix the error above."
  fi
  rm -rf -- "$RELEASE_DIR"
  die "$1; still serving ${OLD_CURRENT#releases/}."
}

# C.2, C.3: the config from the new current, then (node/nextjs) restart and health check; revert if
# either fails.
deploy_config() {
  site_apply_config || deploy_revert "Deploy failed: the new release's config couldn't be installed"
  site_restart_and_check || deploy_revert "Deploy failed health check"
}

# ---- D. Prune ------------------------------------------------------------------------------------

deploy_prune() {
  local current previous name ref
  local -a names=() gone refs
  current=$(link_target "$SITE_DIR/current") && previous=$(link_target "$SITE_DIR/previous") || exit 1
  current=${current#releases/} previous=${previous#releases/}
  for name in "$SITE_DIR"/releases/*; do
    [ -e "$name" ] && names+=("${name##*/}")
  done
  mapfile -t gone < <(printf '%s\n' "${names[@]}" | prune_releases "$current" "$previous")
  for name in "${gone[@]}"; do
    rm -rf -- "${SITE_DIR:?}/releases/$name" || die "Deleting $SITE_DIR/releases/$name failed."
  done
  mapfile -t refs < <(git_build for-each-ref --format='%(refname)' refs/shipit/ </dev/null \
    | prune_refs "$current" ${previous:+"$previous"})
  for ref in "${refs[@]}"; do
    git_build update-ref -d "$ref" </dev/null || die "Unpinning $ref in repo.git failed."
  done
}

# ---- The command ---------------------------------------------------------------------------------

# site_lock: takes the site lock (held for a whole deploy or rollback) into SITE_LOCK_FD, waiting with
# one message for both.
site_lock() {
  lock_wait "$SHIPIT_VAR/$SITE.lock" "Another deploy or rollback of $SITE is running; waiting." \
    || die "Couldn't take $SHIPIT_VAR/$SITE.lock."
  SITE_LOCK_FD=$LOCK_FD
}

# Deletes a release that was never switched to, and the temp folder.
deploy_exit() {
  if [ -n "$RELEASE_DIR" ] && [ -z "$SWITCHED" ]; then rm -rf -- "$RELEASE_DIR"; fi
  [ -z "$DEPLOY_TMP" ] || rm -rf -- "$DEPLOY_TMP"
}

cmd_deploy() {
  deploy_args "$@" || exit 1
  SITE_DIR=$SRV_ROOT/$SITE BUILD_USER=$SITE-build
  DEPLOY_TMP=$(mktemp -d) || die "Couldn't make a temp folder."
  trap deploy_exit EXIT
  # caddy validates the site's Caddy file from here as the caddy user. Nothing in it is secret.
  chmod 755 "$DEPLOY_TMP"

  site_lock
  deploy_resolve
  deploy_access
  deploy_fetch
  deploy_build
  deploy_switch
  deploy_config
  deploy_prune
  LOCK_FD=$SITE_LOCK_FD
  lock_release
  log "Deployed $SITE: now serving $RELEASE."
}
