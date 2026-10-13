# shellcheck shell=bash
# shipit deploy (plan §3): the new-app questions (A), the guards (B), the set-up that doesn't depend on
# the release (C), then the release steps D1–D11. Sourcing this file only defines constants and
# functions.
#
# The rollback steps (switch_back) live here too, because HEALTH_FAIL=rollback runs them from D11;
# lib/rollback.sh sources this file.

CADDY_SITES=/etc/caddy/sites
CADDYFILE=/etc/caddy/Caddyfile
SYSTEMD_DIR=/etc/systemd/system
LOG_ROOT=/var/log/shipit
# The single PATH builds use, ahead of the release's node_modules/.bin (the launcher does the same).
SYSTEM_PATH=/usr/bin:/bin
BUILD_LOGS_KEEP=10
HEALTH_TIMEOUT=60
# How often a private repo's ls-remote is retried while waiting for its deploy key to be added.
KEY_RETRY_SECONDS=5
# Where DATABASE_URL points: the shared cluster over TCP on loopback, with the role's password. TCP
# rather than the socket because migrations run as deployer, which peer auth would refuse.
PG_HOST=127.0.0.1
PG_PORT=5432

# Run as deployer by deploy_fetch: fetches BRANCH into the bare repo $1 from $2, then prints the commit
# to deploy: the branch's tip, or the --ref $4 when it's a commit reachable from that tip. Exits 3 when
# the ref isn't one.
# shellcheck disable=SC2016 # expanded by the deployer's bash, not here
FETCH_SCRIPT='set -euo pipefail
[ -f "$1/HEAD" ] || git init --quiet --bare "$1"
git -C "$1" fetch --quiet --no-tags "$2" "refs/heads/$3"
tip=$(git -C "$1" rev-parse --verify "FETCH_HEAD^{commit}")
if [ -z "$4" ]; then
  printf "%s\n" "$tip"
  exit 0
fi
sha=$(git -C "$1" rev-parse --verify --quiet "$4^{commit}") || exit 3
git -C "$1" merge-base --is-ancestor "$sha" "$tip" || exit 3
printf "%s\n" "$sha"'

# Run as deployer by deploy_commands when the release has a deploy.conf: sources it the way the build
# will, and checks it sets what deploy needs. Root never sources repo content.
# shellcheck disable=SC2016 # expanded by the deployer's bash, not here
CONF_CHECK_SCRIPT='set -u
cd "$1" || exit 1
. ./deploy.conf || exit 1
missing=""
[ -n "${INSTALL-}" ] || missing="$missing INSTALL"
[ -n "${BUILD-}" ] || missing="$missing BUILD"
[ -n "$(compgen -v PROCESS_)" ] || missing="$missing PROCESS_<name>"
if [ -n "$missing" ]; then
  echo "deploy.conf must set$missing." >&2
  exit 1
fi'

# Run as deployer by deploy_build, with the env file's lines on stdin. Root never sources repo content;
# this script sources the release's deploy.conf, if any, and runs the commands as deployer.
# shellcheck disable=SC2016 # expanded by the deployer's bash, not here
BUILD_SCRIPT='set -euo pipefail
umask 022
while IFS= read -r line; do export "$line"; done
exec </dev/null
cd "$1"
export PATH="$PWD/node_modules/.bin:$PATH"
INSTALL="npm ci --no-audit --no-fund"
BUILD="npm run build"
if [ -f deploy.conf ]; then . ./deploy.conf; fi
printf "== %s\n" "$INSTALL"
bash -c "$INSTALL"
printf "== %s\n" "$BUILD"
bash -c "$BUILD"'

# Run as deployer by deploy_migrate, like BUILD_SCRIPT: MIGRATE from deploy.conf if the release has one,
# or else the zero-config default root passes as $2 (empty when there's nothing to run).
# shellcheck disable=SC2016 # expanded by the deployer's bash, not here
MIGRATE_SCRIPT='set -euo pipefail
umask 022
while IFS= read -r line; do export "$line"; done
exec </dev/null
cd "$1"
export PATH="$PWD/node_modules/.bin:$PATH"
MIGRATE=$2
if [ -f deploy.conf ]; then . ./deploy.conf; fi
[ -n "${MIGRATE-}" ] || exit 0
printf "== %s\n" "$MIGRATE"
bash -c "$MIGRATE"'

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
HEALTH_CODE=''
MIGRATE=''
REF=''
GIT_ENV=(GIT_TERMINAL_PROMPT=0)

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

# repo_ssh_url <url>: the URL a deploy key works with. GitHub's HTTPS form becomes
# git@github.com:<owner>/<repo>.git; SSH URLs are used as they are. Fails for anything else (file://).
repo_ssh_url() {
  local LC_ALL=C part='[A-Za-z0-9_.-]+'
  if [[ $1 =~ ^https://github\.com/($part)/($part)$ ]]; then
    printf 'git@github.com:%s/%s.git\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]%.git}"
  elif repo_uses_key "$1"; then
    printf '%s\n' "$1"
  else
    return 1
  fi
}

# repo_uses_key <repo>: SSH URLs are fetched with the app's deploy key; HTTPS and file:// without.
repo_uses_key() {
  [[ $1 == git@github.com:* || $1 == ssh://* ]]
}

# deploy_key_url <repo>: GitHub's page for adding a deploy key to the repo. Nothing for other hosts.
deploy_key_url() {
  local key
  key=$(repo_key "$1")
  [[ $key != github.com/* ]] || printf 'https://%s/settings/keys/new\n' "$key"
}

# git_ssh_command <key file>: how deployer's git reaches an SSH repo: with that key only, never asking,
# and trusting only the host keys in /etc/ssh/ssh_known_hosts (GitHub's are pinned by setup).
git_ssh_command() {
  printf 'ssh -i %s -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/dev/null\n' "$1"
}

# new_app_repo <url> <head file>: prints the REPO a new app uses. When an anonymous ls-remote of the
# HTTPS (or file://) URL works, the repo is public: that URL, with the ls-remote output left in <head
# file>. Otherwise, and always for ssh:// URLs, the repo is private: its SSH URL, fetched with a deploy
# key. Fails when there's no SSH form to fall back to.
new_app_repo() {
  local url
  url=$(repo_probe_url "$1")
  if [[ $1 != ssh://* ]] \
    && as_deployer GIT_TERMINAL_PROMPT=0 git ls-remote --symref "$url" HEAD >"$2" 2>/dev/null; then
    printf '%s\n' "$url"
    return 0
  fi
  repo_ssh_url "$1"
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

# package_wants_database <package.json>: package.json lists a PostgreSQL client or ORM in dependencies
# or devDependencies. Read as data with jq; a missing or broken file means no.
package_wants_database() {
  jq -e '(.dependencies // {}) + (.devDependencies // {})
    | has("pg") or has("postgres") or has("drizzle-orm") or has("prisma") or has("@prisma/client")' \
    "$1" >/dev/null 2>&1 || return 1
}

# package_has_script <package.json> <name>: package.json's scripts has <name>.
package_has_script() {
  jq -e --arg s "$2" '.scripts[$s] | type == "string"' "$1" >/dev/null 2>&1 || return 1
}

# ---- SQL (run as postgres by pg_psql; names are validated first, and quoted all the same) ---------

# sql_ident <name> and sql_literal <text>: a quoted identifier and a quoted string literal.
sql_ident() {
  local q='"'
  printf '"%s"' "${1//$q/$q$q}"
}

sql_literal() {
  local q="'"
  printf "'%s'" "${1//$q/$q$q}"
}

# sql_role_exists <role>: prints 1 when the role exists.
sql_role_exists() {
  printf 'SELECT 1 FROM pg_roles WHERE rolname = %s;\n' "$(sql_literal "$1")"
}

# sql_database_owner <db>: prints the database's owner, if it exists.
sql_database_owner() {
  printf 'SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = %s;\n' "$(sql_literal "$1")"
}

# sql_create_role <role> <password>: sent on stdin, so the password is never on a command line.
sql_create_role() {
  printf 'CREATE ROLE %s LOGIN PASSWORD %s;\n' "$(sql_ident "$1")" "$(sql_literal "$2")"
}

# sql_database <role> <db>: the database owned by the role, if it's missing (CREATE DATABASE can't run
# in a DO block, so psql's \gexec runs it), then only that role may connect to it.
sql_database() {
  local role db
  role=$(sql_ident "$1")
  db=$(sql_ident "$2")
  printf 'SELECT %s WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = %s)\\gexec\n' \
    "$(sql_literal "CREATE DATABASE $db OWNER $role")" "$(sql_literal "$2")"
  printf 'REVOKE CONNECT ON DATABASE %s FROM PUBLIC;\n' "$db"
  printf 'GRANT CONNECT ON DATABASE %s TO %s;\n' "$db" "$role"
}

# database_url <role> <password> <db>
database_url() {
  printf 'postgresql://%s:%s@%s:%s/%s\n' "$1" "$2" "$PG_HOST" "$PG_PORT" "$3"
}

# db_password: 48 random hex characters, so it needs no escaping in a URL, SQL or the env file.
db_password() {
  od -An -tx1 -N24 /dev/urandom | tr -d ' \n'
}

# conf_processes: reads deploy.conf on stdin and prints its process names, one per line, in order and
# without repeats. Root never sources deploy.conf, so only lines that start with PROCESS_<name>= count:
# indented, commented, `export`ed or computed names ($(...)) are ignored, and the value is never read.
conf_processes() {
  LC_ALL=C awk 'match($0, /^PROCESS_[a-z][a-z0-9_]*=/) { n = substr($0, 9, RLENGTH - 9); if (!seen[n]++) print n }'
}

# conf_health_path: reads deploy.conf on stdin and prints HEALTH_PATH: the value of the last line that
# starts with HEALTH_PATH=, or nothing. The value must be a plain path (/ then letters, digits and
# . _ ~ / -), optionally quoted and followed by a # comment. Any other value is refused, naming the line.
conf_health_path() {
  local line n=0 value='' LC_ALL=C p='/[A-Za-z0-9._~/-]*' re
  re="^HEALTH_PATH=($p|\"$p\"|'$p')?([[:space:]]+#.*)?[[:space:]]*\$"
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [[ $line == HEALTH_PATH=* ]] || continue
    if ! [[ $line =~ $re ]]; then
      err "deploy.conf line $n: HEALTH_PATH must be a plain path, like HEALTH_PATH=/health."
      return 1
    fi
    value=${BASH_REMATCH[1]//[\"\']/}
  done
  printf '%s\n' "$value"
}

# stale_instances <app> <process>...: reads `systemctl list-units` lines on stdin and prints the
# app's instance units whose process isn't one of those given, one per line.
stale_instances() {
  local app=$1
  shift
  LC_ALL=C awk -v app="$app" -v keep=" $* " '
    { u = $1; p = substr(u, length(app) + 2, length(u) - length(app) - 9) }
    index(u, app "@") == 1 && u ~ /\.service$/ && index(keep, " " p " ") == 0 { print u }'
}

# env_example_keys: reads .env.example on stdin and prints its key names, one per line, in order and
# without repeats. Only lines that start with KEY= (uppercase letters, digits and _) count: comments,
# indented and `export` lines are ignored, and the example values are never used.
env_example_keys() {
  LC_ALL=C awk 'match($0, /^[A-Z_][A-Z0-9_]*=/) { k = substr($0, 1, RLENGTH - 1); if (!seen[k]++) print k }'
}

# env_missing_keys <env file>: reads key names on stdin and prints those the env file doesn't set yet.
# PORT and NODE_ENV come from the unit (and the env file would override them), so they're never asked.
env_missing_keys() {
  local key
  while IFS= read -r key; do
    case $key in PORT | NODE_ENV) continue ;; esac
    if [ -f "$1" ] && grep -q "^$key=" -- "$1"; then continue; fi
    printf '%s\n' "$key"
  done
}

# env_file_lines <file> [name]: prints the env file's KEY=value lines, read literally the way systemd
# reads them: blank lines and # or ; comments are skipped, nothing is expanded or unquoted. Fails on a
# line that isn't KEY=value or a value the env-value rule refuses, naming the line (and the file as
# <name>, when given: shipit env checks a temp copy).
env_file_lines() {
  local line n=0 name=${2:-$1} LC_ALL=C
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [[ $line =~ ^[[:space:]]*([#\;].*)?$ ]] && continue
    if ! [[ $line =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      err "$name line $n isn't KEY=value."
      return 1
    fi
    if ! check_env_value "${line#*=}" 2>/dev/null; then
      err "$name line $n (${line%%=*}): values can't contain quotes, backslashes or line breaks, or start or end with whitespace."
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
  printf 'REPO=%q\nBRANCH=%q\nDOMAIN=%q\nPORT=%q\nDATABASE=%q\n' "$REPO" "$BRANCH" "$DOMAIN" "$PORT" "$DATABASE"
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
  (lock_close_all && cd / && runuser -u "$DEPLOY_USER" -- env -i HOME="$home" PATH="$SYSTEM_PATH" LANG=C.UTF-8 "$@")
}

# release_has <file> and release_cat <file>: read a file in the release as deployer, so a symlink in
# the repo can't make root read something else. Root only ever treats what it reads as data.
release_has() {
  as_deployer test -f "$RELEASE/$1"
}

release_cat() {
  as_deployer cat -- "$RELEASE/$1" </dev/null
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

# deploy_key_path: deployer's key for this app's repo.
deploy_key_path() {
  printf '%s/.ssh/shipit_%s\n' "$(user_home "$DEPLOY_USER")" "$APP"
}

# set_git_env: the environment deployer's git runs with. SSH repos use the app's deploy key.
set_git_env() {
  GIT_ENV=(GIT_TERMINAL_PROMPT=0)
  if repo_uses_key "$REPO"; then GIT_ENV+=("GIT_SSH_COMMAND=$(git_ssh_command "$(deploy_key_path)")"); fi
}

repo_ls_remote() {
  as_deployer "${GIT_ENV[@]}" git ls-remote --symref "$REPO" HEAD >"$DEPLOY_TMP/head" 2>/dev/null </dev/null
}

# repo_package_json: prints package.json from the tip of BRANCH, fetched by deployer into a throwaway
# bare repo (a new app has no repo of its own yet). Root only reads the output, with jq.
repo_package_json() {
  # shellcheck disable=SC2016 # expanded by the deployer's bash
  as_deployer "${GIT_ENV[@]}" bash -c '
    set -euo pipefail
    d=$(mktemp -d)
    trap "rm -rf -- $d" EXIT
    git init --quiet --bare "$d"
    git -C "$d" fetch --quiet --depth 1 --no-tags "$1" "refs/heads/$2"
    git -C "$d" show FETCH_HEAD:package.json' package "$REPO" "$BRANCH" </dev/null 2>/dev/null
}

# pg_psql: runs the SQL on stdin as postgres, printing bare query results.
pg_psql() {
  (cd / && runuser -u postgres -- psql -X -q -t -A -v ON_ERROR_STOP=1 -d postgres)
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
  local url=$1 ip conf
  log "== New app from $url"
  # Public or private: an anonymous ls-remote, which leaves its output in head for a public repo.
  REPO=$(new_app_repo "$url" "$DEPLOY_TMP/head") || die "Couldn't read $url. Check the URL."
  if repo_uses_key "$REPO"; then
    log "$url needs credentials, so shipit will fetch it over SSH ($REPO) with a read-only deploy key."
  fi

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

  # A private repo's default branch can only be read once its deploy key works.
  if repo_uses_key "$REPO"; then deploy_repo_access; fi
  BRANCH=$(default_branch <"$DEPLOY_TMP/head") || die "Couldn't find the default branch of $url."
  check_branch "$BRANCH" || exit 1
  ask_database

  conf=$SHIPIT_ETC/apps/$APP.conf
  app_conf_text >"$DEPLOY_TMP/app.conf"
  install -m 644 "$DEPLOY_TMP/app.conf" "$conf"
  log "Wrote $conf (port $PORT, branch $BRANCH)."
}

# ask_database: sets DATABASE to the app's name, or to nothing. The default is yes when the branch's
# package.json lists a PostgreSQL client or ORM.
ask_database() {
  local default=n prompt='[y/N]' answer
  if repo_package_json >"$DEPLOY_TMP/package.json" && package_wants_database "$DEPLOY_TMP/package.json"; then
    default=y
    prompt='[Y/n]'
  fi
  while :; do
    ask "Create a PostgreSQL database? $prompt " answer || need_answer
    case ${answer:-$default} in
      [Yy] | [Yy][Ee][Ss])
        DATABASE=$APP
        return 0
        ;;
      [Nn] | [Nn][Oo])
        DATABASE=''
        return 0
        ;;
    esac
  done
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
  [ -z "$DATABASE" ] || check_database "$DATABASE" "$APP" || ok=''
  [ -n "$ok" ] || die "Fix $conf, then re-run sudo shipit deploy $APP."
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
}

# Repo access (C): private repos only. Creates deployer's ed25519 key for the app if it's missing.
# While the repo refuses it, prints the public key and where to add it, and retries every
# KEY_RETRY_SECONDS. Ctrl-C stops it, and the next deploy picks up from here (the key is kept).
deploy_repo_access() {
  local key url
  set_git_env
  repo_uses_key "$REPO" || return 0
  key=$(deploy_key_path)
  # shellcheck disable=SC2016 # expanded by the deployer's bash
  as_deployer bash -c 'umask 077; mkdir -p "${1%/*}"; [ -f "$1" ] || ssh-keygen -q -t ed25519 -N "" -C "$2" -f "$1"' \
    keygen "$key" "shipit-$APP@$(hostname)" </dev/null || die "Creating the deploy key $key failed."
  repo_ls_remote && return 0

  url=$(deploy_key_url "$REPO")
  if [ -n "$url" ]; then
    log "Add this read-only deploy key to the repo at $url (leave \"Allow write access\" unticked):"
  else
    log "Add this public key as a read-only deploy key for $REPO:"
  fi
  printf '\n  %s\n\n' "$(as_deployer cat -- "$key.pub" </dev/null)"
  log "Waiting for the repo to accept it (checking every $KEY_RETRY_SECONDS seconds; Ctrl-C stops, and the next deploy picks up from here)…"
  until repo_ls_remote; do sleep "$KEY_RETRY_SECONDS"; done
  log "The deploy key works."
}

# Database (C): only when DATABASE is set. The role is the app's name, with a random password made
# once and kept only in DATABASE_URL in the env file, which is written right after the role is created
# (so a later failing step can't lose it). Then the database, owned by the role, and only that role may
# connect to it. Everything runs as postgres.
deploy_database() {
  local env=/etc/$APP/env exists owner has_url='' password
  [ -n "$DATABASE" ] || return 0
  exists=$(sql_role_exists "$APP" | pg_psql) || die "Couldn't query PostgreSQL. Check: systemctl status postgresql"
  if [ -f "$env" ] && grep -q '^DATABASE_URL=' -- "$env"; then has_url=1; fi
  if [ -n "$exists" ] && [ -z "$has_url" ]; then
    die "The PostgreSQL role $APP already exists, but $env has no DATABASE_URL, so its password can't be recovered." \
      "Set a new one: run sudo -u postgres psql, then ALTER ROLE $(sql_ident "$APP") PASSWORD '<new password>';" \
      "Then add DATABASE_URL=$(database_url "$APP" '<new password>' "$DATABASE") to $env and re-run the deploy."
  fi
  if [ -z "$exists" ] && [ -n "$has_url" ]; then
    die "$env has a DATABASE_URL, but there's no PostgreSQL role $APP. Remove the DATABASE_URL line from $env and re-run the deploy; it creates the role with a new password."
  fi
  owner=$(sql_database_owner "$DATABASE" | pg_psql) || die "Couldn't query PostgreSQL. Check: systemctl status postgresql"
  if [ -n "$owner" ] && [ "$owner" != "$APP" ]; then
    die "A PostgreSQL database named $DATABASE already exists and belongs to $owner, not $APP. Set another DATABASE in $SHIPIT_ETC/apps/$APP.conf, then re-run the deploy."
  fi

  if [ -z "$exists" ]; then
    password=$(db_password)
    [[ $password =~ ^[0-9a-f]{48}$ ]] || die "Couldn't make a random password."
    sql_create_role "$APP" "$password" | pg_psql >/dev/null || die "Creating the PostgreSQL role $APP failed."
    env_add_missing "$env" "DATABASE_URL=$(database_url "$APP" "$password" "$DATABASE")" >"$DEPLOY_TMP/env"
    install -m 600 "$DEPLOY_TMP/env" "$env"
    log "Created the PostgreSQL role $APP, and added its DATABASE_URL to $env."
  fi
  sql_database "$APP" "$DATABASE" | pg_psql >/dev/null || die "Creating the PostgreSQL database $DATABASE failed."
}

# ---- D. The release ------------------------------------------------------------------------------

# D1–D2: fetch BRANCH into the bare repo, resolve --ref (REF) or the branch's tip, and extract it into
# releases/<UTC>-<sha>, all as deployer.
deploy_fetch() {
  local repo=$SHIPIT_OPT/$APP/repo sha release status=0
  log "== Fetching $BRANCH from $REPO"
  sha=$(as_deployer "${GIT_ENV[@]}" bash -c "$FETCH_SCRIPT" fetch "$repo" "$REPO" "$BRANCH" "$REF" \
    2>>"$BUILD_LOG" </dev/null) || status=$?
  [ "$status" -ne 3 ] || die "$REF isn't a commit on $BRANCH, so it can't be deployed. Only commits the branch contains ship."
  [ "$status" -eq 0 ] || die "Fetching $BRANCH from $REPO failed. See $BUILD_LOG"
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

# D3: the commands. A release with deploy.conf uses it: deployer sources it to check it, and root reads
# only the process names and HEALTH_PATH, as data (release_processes; its MIGRATE is read by deployer,
# in MIGRATE_SCRIPT). Otherwise the zero-config defaults, with MIGRATE only if package.json has
# db:migrate.
deploy_commands() {
  local out
  MIGRATE=''
  if release_has deploy.conf; then
    out=$(as_deployer PORT="$PORT" bash -c "$CONF_CHECK_SCRIPT" check "$RELEASE" 2>&1 </dev/null) || die "$out"
  else
    zero_config_check "$RELEASE" || exit 1
    release_cat package.json >"$DEPLOY_TMP/package.json" || die "Reading the release's package.json failed."
    if package_has_script "$DEPLOY_TMP/package.json" db:migrate; then MIGRATE="npm run db:migrate"; fi
  fi
  release_processes
}

# release_processes: sets PROCESSES and HEALTH_PATH for RELEASE. From a copy of its deploy.conf, read as
# data (conf_processes, conf_health_path), or the zero-config web process and lenient health check.
release_processes() {
  local conf=$DEPLOY_TMP/deploy.conf p
  HEALTH_PATH=''
  PROCESSES=(web)
  if release_has deploy.conf; then
    release_cat deploy.conf >"$conf" || die "Reading the release's deploy.conf failed."
    mapfile -t PROCESSES < <(conf_processes <"$conf")
    HEALTH_PATH=$(conf_health_path <"$conf") || exit 1
  fi
  for p in "${PROCESSES[@]}"; do check_process_name "$p" || exit 1; done
  [ "${#PROCESSES[@]}" -gt 0 ] \
    || die "deploy.conf defines no process to run. Add a line that starts with PROCESS_<name>=, like PROCESS_web=\"node server.js\"."
}

# D4: the env file. It only ever gains keys: APP_URL, then a value for each key of the release's
# .env.example it doesn't have yet, asked with hidden input. DATABASE_URL is already there for an app
# with a database: deploy_database wrote it.
deploy_env() {
  local file=/etc/$APP/env lines=("APP_URL=https://$DOMAIN") missing=() key value
  env_add_missing "$file" "${lines[@]}" >"$DEPLOY_TMP/env"
  if install_if_changed "$DEPLOY_TMP/env" "$file" 600; then log "Wrote $file."; fi
  chown root:root "$file"
  env_file_lines "$file" >/dev/null || die "Fix it with: sudo shipit env $APP"
  # APP_URL is only ever added, so a changed DOMAIN doesn't change it.
  if ! grep -qxF "APP_URL=https://$DOMAIN" -- "$file" && grep -q '^APP_URL=' -- "$file"; then
    log "$file sets an APP_URL other than https://$DOMAIN. If the domain changed, update it with: sudo shipit env $APP"
  fi

  release_has .env.example || return 0
  release_cat .env.example >"$DEPLOY_TMP/env.example" || die "Reading the release's .env.example failed."
  mapfile -t missing < <(env_example_keys <"$DEPLOY_TMP/env.example" | env_missing_keys "$file")
  [ "${#missing[@]}" -gt 0 ] || return 0
  [ -t 0 ] || die "$file has no value for ${missing[*]} from .env.example, and there's no terminal to ask in. Add them with: sudo shipit env $APP, then re-run the deploy."
  log "== $file needs a value for each new .env.example key (input is hidden; blank is allowed)"
  for key in "${missing[@]}"; do
    while :; do
      ask_hidden "$key: " value || need_answer
      check_env_value "$value" && break
    done
    lines+=("$key=$value")
  done
  env_add_missing "$file" "${lines[@]}" >"$DEPLOY_TMP/env"
  install_if_changed "$DEPLOY_TMP/env" "$file" 600 || true
  log "Added ${missing[*]} to $file."
}

# D5: INSTALL then BUILD as deployer, holding the shared build lock. Root reads the env file literally
# and hands it over on stdin, so it never appears in a command line and deployer can't read it at rest.
deploy_build() {
  local app_fd=$LOCK_FD
  lock_wait "$SHIPIT_VAR/build.lock" "Waiting for another app's build…" || die "Couldn't take the build lock."
  log "== Building $DEPLOY_SHA (output in $BUILD_LOG)"
  printf '== Build lock taken at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$BUILD_LOG"
  if ! env_file_lines "/etc/$APP/env" \
    | as_deployer PORT="$PORT" bash -c "$BUILD_SCRIPT" build "$RELEASE" 2>&1 | tee -a "$BUILD_LOG"; then
    die "The build failed, so nothing was switched. See $BUILD_LOG"
  fi
  printf '== Build lock released at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$BUILD_LOG"
  lock_release
  LOCK_FD=$app_fd
}

# D6: MIGRATE, if there is one, as deployer with the env file on stdin like the build. On failure the
# release is deleted (deploy_exit) and current stays as it was.
deploy_migrate() {
  local old
  if env_file_lines "/etc/$APP/env" \
    | as_deployer PORT="$PORT" bash -c "$MIGRATE_SCRIPT" migrate "$RELEASE" "$MIGRATE" 2>&1 | tee -a "$BUILD_LOG"; then
    return 0
  fi
  old=$(readlink "$SHIPIT_OPT/$APP/current") || old=''
  [ -z "$old" ] || die "Migrations failed, so nothing was switched. Still serving ${old##*/}. See $BUILD_LOG"
  die "Migrations failed, so nothing was switched. See $BUILD_LOG"
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
  deploy_backups
}

# D7 (end): an app with a DATABASE gets its backup folder (postgres:postgres 700) and an enabled
# shipit-backup@<app>.timer. Without one, a timer left enabled from before is disabled; its dumps stay.
deploy_backups() {
  local timer=shipit-backup@$APP.timer
  if [ -z "$DATABASE" ]; then
    systemctl is-enabled --quiet "$timer" 2>/dev/null || return 0
    systemctl disable --quiet --now "$timer" || die "Disabling $timer failed."
    log "Disabled $timer, because $APP has no DATABASE now. Its dumps stay in $BACKUP_ROOT/$APP."
    return 0
  fi
  install -d -m 700 -o postgres -g postgres "$BACKUP_ROOT/$APP" || die "Creating $BACKUP_ROOT/$APP failed."
  systemctl is-enabled --quiet "$timer" 2>/dev/null && return 0
  systemctl enable --quiet --now "$timer" || die "Enabling $timer failed."
  log "Enabled $timer: daily backups of $DATABASE to $BACKUP_ROOT/$APP."
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

# D9: stops the app's instances the release doesn't list (the launcher would exit 78 for them), then
# restarts <app>.target. PartOf= passes the restart on to every listed process.
deploy_restart() {
  local stale=() unit
  mapfile -t stale < <(systemctl list-units --all --plain --no-legend --type=service "$APP@*.service" \
    | stale_instances "$APP" "${PROCESSES[@]}")
  for unit in "${stale[@]}"; do
    systemctl stop "$unit" || die "Stopping $unit failed."
    log "Stopped $unit: this release doesn't run it."
  done
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

# health_wait: polls for up to HEALTH_TIMEOUT seconds, leaving the last status in HEALTH_CODE.
# HEALTH_PATH (from deploy.conf) makes it strict.
health_wait() {
  local path=${HEALTH_PATH:-/} strict=${HEALTH_PATH:+1} deadline=$((SECONDS + HEALTH_TIMEOUT))
  log "== Checking http://127.0.0.1:$PORT$path"
  while :; do
    HEALTH_CODE=$(health_code "$path")
    health_ok "$HEALTH_CODE" "$strict" && return 0
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 2
  done
}

# D11: the health check. When it fails, HEALTH_FAIL=rollback switches back to previous (the app lock
# is already held); report, the default, says how to.
deploy_health() {
  local old report
  if health_wait; then
    DEPLOY_RESULT=deployed
    log "Deployed $DEPLOY_SHA. https://$DOMAIN"
    return 0
  fi
  DEPLOY_RESULT=unhealthy
  report="Deployed $DEPLOY_SHA, but ${HEALTH_PATH:-/} answered $HEALTH_CODE."
  if [ "$HEALTH_FAIL" = rollback ]; then
    if old=$(previous_release); then
      err "$report Rolling back to ${old##*/}, because HEALTH_FAIL=rollback."
      switch_back "$old"
      DEPLOY_RESULT=rolled-back
      health_wait || err "${old##*/} isn't healthy either: ${HEALTH_PATH:-/} answered $HEALTH_CODE."
      die "Rolled back to ${old##*/}; the database keeps $DEPLOY_SHA's migrations."
    fi
    err "There's no previous release to roll back to."
  fi
  die "$report Switch back with: sudo shipit rollback $APP"
}

# ---- Rollback (plan §3), also run by D11 with HEALTH_FAIL=rollback --------------------------------

# previous_release: prints the release previous points at, failing when there's none.
previous_release() {
  local p
  p=$(readlink "$SHIPIT_OPT/$APP/previous") && [ -d "$p" ] && printf '%s\n' "$p"
}

# switch_links <release>: points current at the release atomically, then removes previous.
switch_links() {
  local opt=$SHIPIT_OPT/$APP
  rm -f -- "$opt/current.new"
  { ln -s "$1" "$opt/current.new" && mv -T "$opt/current.new" "$opt/current"; } \
    || die "Switching $opt/current failed."
  rm -f -- "$opt/previous"
}

# switch_back <release>: rollback steps 1–3, with the app lock held. Re-renders <app>.target from the
# release's process names (read as data), switches current to it and removes previous, then restarts
# the target, which stops the instances that release doesn't list. Sets PROCESSES and HEALTH_PATH for
# it. Never touches the database: the launcher reads current/deploy.conf, so its commands come back.
switch_back() {
  local RELEASE=$1 t=$DEPLOY_TMP/rollback out
  release_processes
  mkdir -p "$t"
  render_target "${PROCESSES[@]}" >"$t/$APP.target" || exit 1
  cp -- "$SYSTEMD_DIR/$APP@.service" "$t/" || die "$SYSTEMD_DIR/$APP@.service is missing. Run: sudo shipit deploy $APP"
  out=$(systemd-analyze verify "$t/$APP@.service" "$t/$APP.target" 2>&1) \
    || die "$out"$'\n'"$APP.target didn't pass systemd-analyze verify, so nothing was changed."
  if install_if_changed "$t/$APP.target" "$SYSTEMD_DIR/$APP.target" 644; then
    log "Wrote $SYSTEMD_DIR/$APP.target."
    systemctl daemon-reload || die "systemctl daemon-reload failed."
  fi
  switch_links "$RELEASE"
  deploy_restart
}

cmd_deploy() {
  local usage="Usage: sudo shipit deploy <github-url | app> [--ref <sha>]"
  case $# in
    1) ;;
    3)
      [ "$2" = --ref ] || die "$usage"
      check_ref "$3" || exit 1
      REF=$3
      ;;
    *) die "$usage" ;;
  esac
  if [ -z "$1" ] || [[ $1 == -* ]]; then die "$usage"; fi
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
  deploy_repo_access
  deploy_database
  BUILD_LOG=$LOG_ROOT/$APP/builds/deploy-$DEPLOY_UTC.log
  ensure_file "$BUILD_LOG" root:adm 640
  prune_build_logs "$LOG_ROOT/$APP/builds" "$BUILD_LOGS_KEEP"

  deploy_fetch
  deploy_commands
  deploy_env
  deploy_build
  deploy_migrate
  log "== Installing units and site"
  deploy_units_and_site
  log "== Switching to $DEPLOY_SHA"
  deploy_switch
  deploy_restart
  deploy_prune
  deploy_health
}
