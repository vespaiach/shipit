# shellcheck shell=bash
# shipit deploy (plan §3): the new-app questions (A), the guards (B), the set-up that doesn't depend on
# the release (C), then the release steps D1–D11. Sourcing this file only defines constants and
# functions.
#
# Milestone seams, marked "S3:", "S4:" and "S5:" below: private repos, deploy.conf and .env.example
# prompts (S3), the database and MIGRATE (S4), --ref and HEALTH_FAIL=rollback (S5).

CADDY_SITES=/etc/caddy/sites
CADDYFILE=/etc/caddy/Caddyfile
SYSTEMD_DIR=/etc/systemd/system
LOG_ROOT=/var/log/shipit
# The single PATH builds use, ahead of the release's node_modules/.bin (the launcher does the same).
SYSTEM_PATH=/usr/bin:/bin
BUILD_LOGS_KEEP=10
HEALTH_TIMEOUT=60

# Run as deployer by deploy_build, with the env file's lines on stdin. Root never sources repo content;
# this script runs the commands as deployer. S3: it sources deploy.conf here when the release has one.
# shellcheck disable=SC2016 # expanded by the deployer's bash, not here
BUILD_SCRIPT='set -euo pipefail
umask 022
while IFS= read -r line; do export "$line"; done
exec </dev/null
cd "$1"
export PATH="$PWD/node_modules/.bin:$PATH"
INSTALL="npm ci --no-audit --no-fund"
BUILD="npm run build"
printf "== %s\n" "$INSTALL"
bash -c "$INSTALL"
printf "== %s\n" "$BUILD"
bash -c "$BUILD"'

# This deploy's state. The app config's values (REPO BRANCH DOMAIN PORT DATABASE HEALTH_FAIL
# LOG_REDACT_QUERY) are globals too, set by deploy_load_conf or the new-app questions.
APP=''
DEPLOY_TMP=''
DEPLOY_UTC=''
DEPLOY_SHA=-
DEPLOY_RESULT=failed
DEPLOY_LOCKED=''
BUILD_LOG=''
RELEASE=''
SWITCHED=''
PROCESSES=()
HEALTH_PATH=''

# ---- Small parsers and checks (unit-tested) ------------------------------------------------------

# default_branch: reads `git ls-remote --symref <repo> HEAD` on stdin and prints the branch HEAD names.
default_branch() {
  awk '$1 == "ref:" && $3 == "HEAD" && $2 ~ /^refs\/heads\// { sub(/^refs\/heads\//, "", $2); print $2; found = 1; exit } END { exit !found }'
}

# repo_probe_url <repo>: the URL for the anonymous public-repo check. GitHub repos are checked (and,
# when public, fetched) over HTTPS; ssh:// and file:// URLs are used as they are.
repo_probe_url() {
  local LC_ALL=C
  if [[ $1 =~ ^git@github\.com:([^/]+)/(.+)$ ]]; then
    printf 'https://github.com/%s/%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  else
    printf '%s\n' "$1"
  fi
}

# repo_key <repo>: what two URLs for the same repo have in common. GitHub's HTTPS and SSH forms, with or
# without .git and in any case, become github.com/<owner>/<repo>.
repo_key() {
  local LC_ALL=C url
  url=$(repo_probe_url "$1")
  if [[ $url =~ ^https://github\.com/([^/]+)/([^/]+)$ ]]; then
    url="github.com/${BASH_REMATCH[1]}/${BASH_REMATCH[2]%.git}"
    printf '%s\n' "$url" | tr '[:upper:]' '[:lower:]'
  else
    printf '%s\n' "$url"
  fi
}

# app_for_repo <repo>: prints the app whose REPO is this repo, if any.
app_for_repo() {
  local f value key
  key=$(repo_key "$1")
  for f in "$SHIPIT_ETC"/apps/*.conf; do
    [ -e "$f" ] || continue
    value=$(conf_get "$f" REPO) || return 1
    if [ -n "$value" ] && [ "$(repo_key "$value")" = "$key" ]; then
      basename "$f" .conf
      return 0
    fi
  done
}

# app_name_free <name>: the name is valid and no other app, system user or unit has it.
app_name_free() {
  check_app_name "$1" || return 1
  if [ -e "$SHIPIT_ETC/apps/$1.conf" ]; then
    err "The name $1 is already used by another app."
    return 1
  fi
  check_app_user "$1" && check_app_units "$1"
}

# zero_config_check <release>: without deploy.conf, package.json must list next and the repo must have
# package-lock.json. Root reads package.json as data only, with jq.
zero_config_check() {
  if [ ! -f "$1/package.json" ]; then
    err "This repo has no package.json or deploy.conf, so shipit doesn't know how to build it. Add a deploy.conf (see examples/deploy.conf)."
    return 1
  fi
  if ! jq -e '(.dependencies.next // .devDependencies.next) != null' "$1/package.json" >/dev/null 2>&1; then
    err "package.json doesn't list next, so this isn't a zero-config Next.js app. Add a deploy.conf (see examples/deploy.conf)."
    return 1
  fi
  if [ ! -f "$1/package-lock.json" ]; then
    err "Zero-config deploys need package-lock.json. Run npm install and commit package-lock.json, or add a deploy.conf."
    return 1
  fi
}

# release_processes <release>: the process names the release runs, one per line. S3: read from
# deploy.conf with grep -E '^PROCESS_[a-z][a-z0-9_]*=' when the release has one.
release_processes() {
  printf '%s\n' web
}

# env_file_lines <file>: prints the env file's KEY=value lines, read literally the way systemd reads
# them: blank lines and # or ; comments are skipped, nothing is expanded or unquoted. Fails on a line
# that isn't KEY=value or a value the env-value rule refuses.
env_file_lines() {
  local line n=0 LC_ALL=C
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [[ $line =~ ^[[:space:]]*([#\;].*)?$ ]] && continue
    if ! [[ $line =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      err "$1 line $n isn't KEY=value."
      return 1
    fi
    if ! check_env_value "${line#*=}" 2>/dev/null; then
      err "$1 line $n (${line%%=*}): values can't contain quotes, backslashes or line breaks, or start or end with whitespace."
      return 1
    fi
    printf '%s\n' "$line"
  done <"$1"
}

# env_add_missing <file> <KEY=value>...: prints the env file (if it exists) followed by each given
# line whose key it doesn't have yet. Existing keys are never changed.
env_add_missing() {
  local file=$1 line
  shift
  if [ -f "$file" ]; then
    cat -- "$file"
    [ ! -s "$file" ] || [ -z "$(tail -c 1 -- "$file")" ] || printf '\n'
  fi
  for line in "$@"; do
    if [ -f "$file" ] && grep -q "^${line%%=*}=" -- "$file"; then continue; fi
    printf '%s\n' "$line"
  done
}

# health_ok <status code> [strict]: strict (HEALTH_PATH set) needs exactly 200. Otherwise any answer
# below 500 counts, because many apps redirect / to a login page. 000 means no answer at all.
health_ok() {
  local LC_ALL=C
  [[ $1 =~ ^[1-5][0-9][0-9]$ ]] || return 1
  if [ -n "${2-}" ]; then
    [ "$1" = 200 ]
  else
    [ "$1" -lt 500 ]
  fi
}

# free_gb <path>: whole GB free on the path's filesystem.
free_gb() {
  df -Pk -- "$1" | awk 'NR == 2 { print int($4 / 1048576) }'
}

# prune_build_logs <dir> <keep>: deletes all but the newest <keep> deploy-<UTC>.log files.
prune_build_logs() {
  local files
  files=("$1"/deploy-*.log)
  [ -e "${files[0]}" ] || return 0
  [ "${#files[@]}" -gt "$2" ] || return 0
  rm -f -- "${files[@]:0:${#files[@]}-$2}"
}

app_conf_text() {
  printf '%s\n' "# Written by the first \`shipit deploy\` of $APP. Edit it, then run \`sudo shipit deploy $APP\` to apply it. No secrets."
  printf 'REPO=%q\nBRANCH=%q\nDOMAIN=%q\nPORT=%q\n' "$REPO" "$BRANCH" "$DOMAIN" "$PORT"
  printf '%s\n' 'HEALTH_FAIL=report'
}

render_service() {
  render "$SHIPIT_TEMPLATES/app@.service" APP PORT
}

# render_target <process>...: <app>.target, whose Wants= lists the processes.
render_target() {
  local WANTS='' p
  for p in "$@"; do WANTS+="${WANTS:+ }$APP@$p.service"; done
  render "$SHIPIT_TEMPLATES/app.target" APP WANTS
}

# render_site: the Caddy site. Each LOG_REDACT_QUERY name becomes a `delete` line; with none, the
# template's `format filter` block is left out before rendering.
render_site() {
  local tpl=$SHIPIT_TEMPLATES/site.caddy tab=$'\t' REDACT_LINES='' p
  if [ -z "${LOG_REDACT_QUERY-}" ]; then
    render <(sed "/^$tab${tab}format filter {\$/,/^$tab$tab}\$/d" "$tpl") APP DOMAIN PORT
    return
  fi
  # shellcheck disable=SC2086 # split on spaces; check_redact_query allows no glob characters
  for p in $LOG_REDACT_QUERY; do REDACT_LINES+="${REDACT_LINES:+$'\n'}$tab$tab$tab${tab}delete $p"; done
  render "$tpl" APP DOMAIN PORT REDACT_LINES
}

# ---- Host helpers --------------------------------------------------------------------------------

# as_deployer [VAR=value]... <command>...: runs the command as the deploy account, with a clean
# environment and from /, so nothing of root's leaks into it.
as_deployer() {
  local home
  home=$(user_home "$DEPLOY_USER")
  (cd / && runuser -u "$DEPLOY_USER" -- env -i HOME="$home" PATH="$SYSTEM_PATH" LANG=C.UTF-8 "$@")
}

# ensure_file <path> <owner:group> <mode>: creates an empty file if it's missing. Never overwrites.
ensure_file() {
  [ -e "$1" ] || install -m "$3" -o "${2%%:*}" -g "${2#*:}" /dev/null "$1"
}

public_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }'
}

# dns_points_at <domain> <ip>
dns_points_at() {
  getent ahosts "$1" | awk -v ip="$2" '$1 == ip { found = 1 } END { exit !found }'
}

need_answer() {
  die "deploy needs answers to its questions. Run it in a terminal."
}

# Appends one line to deploy.log for every deploy that got the app lock, deletes a release that was
# never switched to, and removes the temp folder.
deploy_exit() {
  if [ -n "$RELEASE" ] && [ -z "$SWITCHED" ]; then rm -rf -- "$RELEASE"; fi
  if [ -n "$DEPLOY_LOCKED" ] && [ -d "$LOG_ROOT/$APP" ]; then
    printf '%s %s %s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$APP" "$DEPLOY_SHA" "${SUDO_USER:-root}" \
      "$DEPLOY_RESULT" >>"$LOG_ROOT/$APP/deploy.log"
  fi
  [ -z "$DEPLOY_TMP" ] || rm -rf -- "$DEPLOY_TMP"
}

# ---- A. New app: questions -----------------------------------------------------------------------

# deploy_resolve <github-url | app>: sets APP, asking the new-app questions when it's a new repo.
deploy_resolve() {
  local LC_ALL=C
  if [[ $1 =~ ^[a-z][a-z0-9_]{0,30}$ ]]; then
    [ -e "$SHIPIT_ETC/apps/$1.conf" ] \
      || die "There's no app named $1. Deploy a new app with its repo URL: sudo shipit deploy https://github.com/<you>/<app>"
    APP=$1
    return 0
  fi
  check_repo "$1" || exit 1
  APP=$(app_for_repo "$1") || exit 1
  if [ -n "$APP" ]; then
    log "$1 is the app $APP."
    return 0
  fi
  deploy_new_app "$1"
}

deploy_new_app() {
  local url=$1 head ip conf
  log "== New app from $url"
  REPO=$(repo_probe_url "$url")
  # Public or private: an anonymous ls-remote. S3: on failure, use the SSH URL and a deploy key.
  head=$(as_deployer GIT_TERMINAL_PROMPT=0 git ls-remote --symref "$REPO" HEAD 2>/dev/null) \
    || die "Couldn't read $url without credentials. Private repos aren't supported yet: make it public, or check the URL."
  BRANCH=$(default_branch <<<"$head") || die "Couldn't find the default branch of $url."
  check_branch "$BRANCH" || exit 1

  APP=$(app_name_from_repo "$url")
  if ! app_name_free "$APP"; then
    while :; do
      ask 'App name: ' APP || need_answer
      app_name_free "$APP" && break
    done
  fi
  while :; do
    ask "Domain for $APP (like app.example.com): " DOMAIN || need_answer
    check_domain "$DOMAIN" && break
  done
  ip=$(public_ip) || true
  if [ -n "$ip" ] && ! dns_points_at "$DOMAIN" "$ip"; then
    log "Point an A record for $DOMAIN at $ip. Caddy will get the certificate once it does."
  fi
  PORT=$(allocate_port) || exit 1
  # S4: ask "Create a PostgreSQL database? [Y/n]" here, defaulting from package.json.

  conf=$SHIPIT_ETC/apps/$APP.conf
  app_conf_text >"$DEPLOY_TMP/app.conf"
  install -m 644 "$DEPLOY_TMP/app.conf" "$conf"
  log "Wrote $conf (port $PORT, branch $BRANCH)."
}

# ---- B. Guards -----------------------------------------------------------------------------------

# deploy_load_conf: reads the app config after the ownership check, and validates every value.
deploy_load_conf() {
  local conf=$SHIPIT_ETC/apps/$APP.conf var value ok=1
  for var in REPO BRANCH DOMAIN PORT DATABASE HEALTH_FAIL LOG_REDACT_QUERY; do
    value=$(conf_get "$conf" "$var") || exit 1
    printf -v "$var" '%s' "$value"
  done
  HEALTH_FAIL=${HEALTH_FAIL:-report}
  check_app_name "$APP" && check_app_user "$APP" && check_app_units "$APP" || exit 1
  check_repo "$REPO" || ok=''
  check_branch "$BRANCH" || ok=''
  check_domain "$DOMAIN" "$APP" || ok=''
  { check_port "$PORT" "$APP" && check_port_free "$PORT" "$APP"; } || ok=''
  case $HEALTH_FAIL in
    report | rollback) ;;
    *)
      err "Invalid HEALTH_FAIL '$HEALTH_FAIL': use report or rollback."
      ok=''
      ;;
  esac
  [ -z "$LOG_REDACT_QUERY" ] || check_redact_query "$LOG_REDACT_QUERY" || ok=''
  [ -n "$ok" ] || die "Fix $conf, then re-run sudo shipit deploy $APP."
  # S4: create and use the database.
  [ -z "$DATABASE" ] || die "$conf sets DATABASE, but shipit doesn't create databases yet. Remove the line for now."
}

deploy_guards() {
  local min free
  min=$(conf_get "$SHIPIT_ETC/host.conf" MIN_FREE_DISK_GB) || exit 1
  check_number MIN_FREE_DISK_GB "$min" || die "Fix $SHIPIT_ETC/host.conf."
  free=$(free_gb "$SHIPIT_OPT") || die "Couldn't read the free disk space under $SHIPIT_OPT."
  if [ "$free" -lt "$min" ]; then
    die "Only $free GB is free under $SHIPIT_OPT, and a deploy needs $min GB (MIN_FREE_DISK_GB). Free some space, then re-run."
  fi
  lock_try "$SHIPIT_VAR/$APP.lock" || die "Another deploy or rollback of $APP is running."
  DEPLOY_LOCKED=1
}

# ---- C. Set-up that doesn't depend on the release ------------------------------------------------

deploy_user() {
  getent passwd "$APP" >/dev/null && return 0
  useradd --system --shell /usr/sbin/nologin --comment 'shipit app' "$APP" \
    || die "Creating the $APP account failed."
  log "Created the $APP account."
}

deploy_folders() {
  local opt=$SHIPIT_OPT/$APP logs=$LOG_ROOT/$APP group
  group=$(id -gn "$DEPLOY_USER")
  # 750 with group <app>: the app's user can read its code, other apps' users can't.
  install -d -m 750 -o "$DEPLOY_USER" -g "$APP" "$opt"
  install -d -m 755 -o "$DEPLOY_USER" -g "$group" "$opt/releases"
  install -d -m 700 -o "$DEPLOY_USER" -g "$group" "$opt/repo"
  # 751: caddy must reach access.log, but can't list the folder.
  install -d -m 751 -o root -g adm "$logs"
  install -d -m 750 -o root -g adm "$logs/builds"
  ensure_file "$logs/access.log" caddy:adm 640
  install -d -m 700 "/etc/$APP"
  # S3: private repos get their deploy key here. S4: the database is created here.
}

# ---- D. The release ------------------------------------------------------------------------------

# D1–D2: fetch BRANCH into the bare repo and extract it into releases/<UTC>-<sha>, both as deployer.
deploy_fetch() {
  local repo=$SHIPIT_OPT/$APP/repo sha release
  log "== Fetching $BRANCH from $REPO"
  # shellcheck disable=SC2016 # expanded by the deployer's bash
  sha=$(as_deployer GIT_TERMINAL_PROMPT=0 bash -c '
    set -euo pipefail
    [ -f "$1/HEAD" ] || git init --quiet --bare "$1"
    git -C "$1" fetch --quiet --no-tags "$2" "refs/heads/$3"
    git -C "$1" rev-parse --verify "FETCH_HEAD^{commit}"' fetch "$repo" "$REPO" "$BRANCH" 2>>"$BUILD_LOG") \
    || die "Fetching $BRANCH from $REPO failed. See $BUILD_LOG"
  # S5: resolve --ref here and check it's reachable from the branch.
  [[ $sha =~ ^[0-9a-f]{40,64}$ ]] || die "git returned an unexpected commit id: $sha"
  DEPLOY_SHA=${sha:0:7}

  release=$SHIPIT_OPT/$APP/releases/$DEPLOY_UTC-$DEPLOY_SHA
  [ ! -e "$release" ] || die "$release already exists. Wait a second and re-run."
  RELEASE=$release
  # shellcheck disable=SC2016 # expanded by the deployer's bash
  as_deployer bash -c 'set -euo pipefail; umask 022; mkdir "$1"; git -C "$2" archive "$3" | tar -x -C "$1"' \
    extract "$RELEASE" "$repo" "$sha" >>"$BUILD_LOG" 2>&1 \
    || die "Extracting $DEPLOY_SHA failed. See $BUILD_LOG"
}

# D3: the commands. S3: a release with deploy.conf uses it (sourced by deployer only).
deploy_commands() {
  [ ! -e "$RELEASE/deploy.conf" ] \
    || die "This release has a deploy.conf, which shipit doesn't support yet. Remove it to deploy with zero config."
  zero_config_check "$RELEASE" || exit 1
  mapfile -t PROCESSES < <(release_processes "$RELEASE")
  local p
  for p in "${PROCESSES[@]}"; do check_process_name "$p" || exit 1; done
  [ "${#PROCESSES[@]}" -gt 0 ] || die "This release defines no process to run."
}

# D4: the env file. It only ever gains keys. S3: ask for missing .env.example keys here. S4: add
# DATABASE_URL.
deploy_env() {
  local file=/etc/$APP/env
  env_add_missing "$file" "APP_URL=https://$DOMAIN" >"$DEPLOY_TMP/env"
  if install_if_changed "$DEPLOY_TMP/env" "$file" 600; then log "Wrote $file."; fi
  chown root:root "$file"
  env_file_lines "$file" >/dev/null || die "Fix it with: sudo shipit env $APP"
}

# D5: INSTALL then BUILD as deployer, holding the shared build lock. Root reads the env file literally
# and hands it over on stdin, so it never appears in a command line and deployer can't read it at rest.
deploy_build() {
  local app_fd=$LOCK_FD
  lock_wait "$SHIPIT_VAR/build.lock" "Waiting for another app's build…" || die "Couldn't take the build lock."
  log "== Building $DEPLOY_SHA (output in $BUILD_LOG)"
  if ! env_file_lines "/etc/$APP/env" \
    | as_deployer PORT="$PORT" bash -c "$BUILD_SCRIPT" build "$RELEASE" 2>&1 | tee -a "$BUILD_LOG"; then
    die "The build failed, so nothing was switched. See $BUILD_LOG"
  fi
  lock_release
  LOCK_FD=$app_fd
  # S4: D6, MIGRATE, runs here.
}

# D7: units and site, validated on temp copies, installed only when changed.
deploy_units_and_site() {
  local t=$DEPLOY_TMP/units logs=$LOG_ROOT/$APP f p out units_changed='' site_changed=''
  mkdir -p "$t/sites"
  render_service >"$t/$APP@.service" || exit 1
  render_target "${PROCESSES[@]}" >"$t/$APP.target" || exit 1
  render_site >"$t/sites/$APP.caddy" || exit 1

  out=$(systemd-analyze verify "$t/$APP@.service" "$t/$APP.target" 2>&1) \
    || die "$out"$'\n'"The units didn't pass systemd-analyze verify, so nothing was changed."

  # Validate with the new site in place, next to every other app's site.
  ensure_file "$CADDY_SITES/$APP.extra" root:root 644
  for f in "$CADDY_SITES"/*.caddy; do
    if [ -e "$f" ] && [ "$f" != "$CADDY_SITES/$APP.caddy" ]; then cp -- "$f" "$t/sites/"; fi
  done
  printf 'import %s/sites/*.caddy\n' "$t" >"$t/Caddyfile"
  out=$(caddy validate --config "$t/Caddyfile" --adapter caddyfile 2>&1) \
    || die "$out"$'\n'"The Caddy site didn't pass caddy validate, so nothing was changed."

  # Process logs exist before systemd opens them, so they're never world-readable.
  for p in "${PROCESSES[@]}"; do
    ensure_file "$logs/$p.log" root:adm 640
    ensure_file "$logs/$p.error.log" root:adm 640
  done
  for f in "$APP@.service" "$APP.target"; do
    if install_if_changed "$t/$f" "$SYSTEMD_DIR/$f" 644; then
      units_changed=1
      log "Wrote $SYSTEMD_DIR/$f."
    fi
  done
  [ -z "$units_changed" ] || systemctl daemon-reload || die "systemctl daemon-reload failed."
  systemctl enable --quiet "$APP.target" || die "Enabling $APP.target failed."

  if install_if_changed "$t/sites/$APP.caddy" "$CADDY_SITES/$APP.caddy" 644; then
    site_changed=1
    log "Wrote $CADDY_SITES/$APP.caddy."
  fi
  if [ -n "$site_changed" ]; then
    if is_shipit_file "$CADDYFILE"; then
      systemctl reload caddy || die "Reloading Caddy failed; it keeps its old config. Check: systemctl status caddy"
    else
      log "Caddy wasn't reloaded, because $CADDYFILE isn't shipit's yet. Switch to $CADDYFILE.shipit (sudo shipit setup says how) to serve $DOMAIN."
    fi
  fi
  # S4: enable shipit-backup@<app>.timer when DATABASE is set.
}

# D8: point current, then previous, at their releases, each atomically.
deploy_switch() {
  local opt=$SHIPIT_OPT/$APP old
  old=$(readlink "$opt/current") || old=''
  rm -f -- "$opt/current.new" "$opt/previous.new"
  { ln -s "$RELEASE" "$opt/current.new" && mv -T "$opt/current.new" "$opt/current"; } \
    || die "Switching $opt/current failed."
  SWITCHED=1
  if [ -n "$old" ] && [ "$old" != "$RELEASE" ]; then
    { ln -s "$old" "$opt/previous.new" && mv -T "$opt/previous.new" "$opt/previous"; } \
      || die "Switching $opt/previous failed."
  fi
}

# D9: PartOf= passes the restart on to every process.
deploy_restart() {
  systemctl restart "$APP.target" || die "Restarting $APP.target failed. Check: systemctl status '$APP@*'"
}

# D10: every release except current and previous.
deploy_prune() {
  local opt=$SHIPIT_OPT/$APP previous dir
  previous=$(readlink "$opt/previous") || previous=''
  for dir in "$opt"/releases/*; do
    [ -d "$dir" ] || continue
    [ "$dir" = "$RELEASE" ] || [ "$dir" = "$previous" ] || rm -rf -- "$dir"
  done
}

health_code() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Host: $DOMAIN" "http://127.0.0.1:$PORT$1" || true
}

# D11: poll for up to HEALTH_TIMEOUT seconds. S3: HEALTH_PATH comes from deploy.conf and is strict.
deploy_health() {
  local path=${HEALTH_PATH:-/} strict=${HEALTH_PATH:+1} code deadline=$((SECONDS + HEALTH_TIMEOUT))
  log "== Checking http://127.0.0.1:$PORT$path"
  while :; do
    code=$(health_code "$path")
    if health_ok "$code" "$strict"; then
      DEPLOY_RESULT=deployed
      log "Deployed $DEPLOY_SHA. https://$DOMAIN"
      return 0
    fi
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep 2
  done
  DEPLOY_RESULT=unhealthy
  # S5: with HEALTH_FAIL=rollback, run the rollback steps here (the lock is already held).
  die "Deployed $DEPLOY_SHA, but $path answered $code. Switch back with: sudo shipit rollback $APP"
}

cmd_deploy() {
  # S5: --ref <sha>.
  [ "${2-}" != --ref ] || die "deploy --ref isn't implemented yet."
  if [ "$#" -ne 1 ] || [ -z "$1" ] || [[ $1 == -* ]]; then
    die "Usage: sudo shipit deploy <github-url | app>"
  fi
  [ -e "$SHIPIT_ETC/host.conf" ] || die "This VPS isn't set up yet. Run: sudo shipit setup"

  DEPLOY_TMP=$(mktemp -d)
  trap deploy_exit EXIT
  DEPLOY_UTC=$(date -u +%Y%m%dT%H%M%SZ)

  deploy_resolve "$1"
  deploy_load_conf
  deploy_guards

  log "== Setting up $APP"
  deploy_user
  deploy_folders
  BUILD_LOG=$LOG_ROOT/$APP/builds/deploy-$DEPLOY_UTC.log
  ensure_file "$BUILD_LOG" root:adm 640
  prune_build_logs "$LOG_ROOT/$APP/builds" "$BUILD_LOGS_KEEP"

  deploy_fetch
  deploy_commands
  deploy_env
  deploy_build
  log "== Installing units and site"
  deploy_units_and_site
  log "== Switching to $DEPLOY_SHA"
  deploy_switch
  deploy_restart
  deploy_prune
  deploy_health
}
