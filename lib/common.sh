# shellcheck shell=bash
# Shared helpers for every shipit command: output, validators, config reads, locks and render().
# Sourcing this file only defines constants and functions. It never runs anything, so tests can source it.

# Test seams (plan §2): plain constants, never read from the environment. Unit tests reassign them.
# shellcheck disable=SC2034 # used by the command libraries that source this file
DEPLOY_USER=deployer
SHIPIT_ETC=/etc/shipit
SHIPIT_VAR=/var/lib/shipit
# Where each app's code lives: $SHIPIT_OPT/<app>/{repo,releases,current,previous}.
SHIPIT_OPT=/opt
# The owner every file root sources from SHIPIT_ETC must have. Tests set it to their own uid.
SHIPIT_OWNER_UID=0
# Where libexec/backup writes each app's dumps: $BACKUP_ROOT/<app>/<app>-<YYYYmmddTHHMMSSZ>.dump, and
# libexec/state-backup its archives: <app>-<YYYYmmddTHHMMSSZ>.tar.gz.
BACKUP_ROOT=/var/backups/shipit
# Where systemd keeps each app's state folder (StateDirectory=<app> in <app>@.service).
STATE_ROOT=/var/lib

# Where render's templates live: templates/ next to lib/, in a checkout and when installed.
SHIPIT_TEMPLATES=${BASH_SOURCE[0]%/*}/../templates

# The first port deploy hands out, and the marker on every file shipit writes.
FIRST_APP_PORT=3001
MANAGED_MARKER='# managed by shipit'

log() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }
die() {
  err "$@"
  exit 1
}

# ---- Validators ----------------------------------------------------------------------------------
# Each prints the reason to stderr and returns 1 when the value is refused. LC_ALL=C keeps [a-z] ASCII.

check_app_name() {
  local LC_ALL=C
  [[ $1 =~ ^[a-z][a-z0-9_]{0,30}$ ]] && return 0
  err "Invalid app name '$1': use a lowercase letter, then up to 30 lowercase letters, digits or _."
  return 1
}

# The app's Linux user may already exist only if shipit created it (GECOS 'shipit app').
check_app_user() {
  local entry gecos
  entry=$(getent passwd "$1") || return 0
  IFS=: read -r _ _ _ _ gecos _ <<<"$entry"
  [ "$gecos" = "shipit app" ] && return 0
  err "A system user named '$1' already exists and wasn't created by shipit. Choose another app name."
  return 1
}

# <app>@.service and <app>.target may already exist only if shipit wrote them. `systemctl cat`
# prints a '# /path' header line, then the unit file, whose first line must be the marker.
check_app_units() {
  local unit first
  for unit in "$1@.service" "$1.target"; do
    first=$(systemctl cat -- "$unit" 2>/dev/null | sed -n 2p) || true
    if [ -n "$first" ] && [[ $first != "$MANAGED_MARKER"* ]]; then
      err "A unit named $unit already exists and wasn't written by shipit. Choose another app name."
      return 1
    fi
  done
}

check_process_name() {
  local LC_ALL=C
  [[ $1 =~ ^[a-z][a-z0-9_]*$ ]] && return 0
  err "Invalid process name '$1': use a lowercase letter, then lowercase letters, digits or _."
  return 1
}

# check_domain <domain> [app]: syntax, then unique across every app config except <app>'s own.
check_domain() {
  local LC_ALL=C label='[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?'
  if ! [[ $1 =~ ^$label(\.$label)+$ ]]; then
    err "Invalid domain '$1': use a lowercase hostname with at least one dot, like app.example.com."
    return 1
  fi
  local other
  other=$(app_using DOMAIN "$1" "${2-}") || return 1
  if [ -n "$other" ]; then
    err "The domain $1 is already used by the app $other."
    return 1
  fi
}

# check_port <port> [app]: syntax and range, then unique across every app config except <app>'s own.
check_port() {
  local LC_ALL=C
  if ! [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] || [ "$1" -lt 1024 ] || [ "$1" -gt 65535 ]; then
    err "Invalid port '$1': use a number from 1024 to 65535."
    return 1
  fi
  local other
  other=$(app_using PORT "$1" "${2-}") || return 1
  if [ -n "$other" ]; then
    err "Port $1 is already used by the app $other."
    return 1
  fi
}

# check_port_free <port> <app>: for a port the app is newly given. Nothing may listen on it, unless the
# app's installed <app>@.service already sets that same PORT (then the listener is the app itself).
check_port_free() {
  unit_sets_port "$2" "$1" && return 0
  port_is_listening "$1" || return 0
  err "Something is already listening on port $1."
  return 1
}

port_is_listening() {
  ss -ltnH | awk -v p=":$1" '{ if (substr($4, length($4) - length(p) + 1) == p) found = 1 } END { exit !found }'
}

unit_sets_port() {
  systemctl cat -- "$1@.service" 2>/dev/null | grep -Eq "^Environment=(.* )?PORT=$2( |\$)"
}

# check_database <name> [app]: a PostgreSQL database name (at most 63 bytes, like any Postgres name),
# unique across every app config except <app>'s own.
check_database() {
  local LC_ALL=C other
  if ! [[ $1 =~ ^[a-z][a-z0-9_]{0,62}$ ]]; then
    err "Invalid DATABASE '$1': use a lowercase letter, then up to 62 lowercase letters, digits or _."
    return 1
  fi
  other=$(app_using DATABASE "$1" "${2-}") || return 1
  if [ -n "$other" ]; then
    err "The database $1 is already used by the app $other."
    return 1
  fi
}

# A git branch name as `git ls-remote --symref` reports it, or as written in an app config.
check_branch() {
  local LC_ALL=C
  if [[ $1 =~ ^[A-Za-z0-9_][A-Za-z0-9._/-]*$ ]] && [[ $1 != *..* && $1 != */ && $1 != *.lock ]]; then
    return 0
  fi
  err "Invalid branch '$1'."
  return 1
}

check_repo() {
  local LC_ALL=C part='[A-Za-z0-9_.-]+'
  [[ $1 =~ ^https://github\.com/$part/$part$ ]] && return 0
  [[ $1 =~ ^git@github\.com:$part/$part\.git$ ]] && return 0
  [[ $1 =~ ^(ssh|file)://[^[:space:]]+$ ]] && return 0
  err "Invalid repo '$1': use https://github.com/<owner>/<repo>, git@github.com:<owner>/<repo>.git, ssh:// or file://."
  return 1
}

# --ref: a commit sha (4 to 64 lowercase hex characters). deploy then checks the branch contains it.
check_ref() {
  local LC_ALL=C
  [[ $1 =~ ^[0-9a-f]{4,64}$ ]] && return 0
  err "Invalid --ref '$1': give a commit sha from the app's branch, like 1a2b3c4."
  return 1
}

# Env values are read literally by systemd and the build, so refuse anything they'd read differently.
check_env_value() {
  local bad=$'\n\r"\'\\'
  if [[ $1 == *["$bad"]* ]]; then
    err "Env values can't contain quotes, backslashes or line breaks."
    return 1
  fi
  if [[ $1 =~ ^[[:space:]] || $1 =~ [[:space:]]$ ]]; then
    err "Env values can't start or end with whitespace."
    return 1
  fi
}

# LOG_REDACT_QUERY: query parameter names, separated by spaces. Each becomes a Caddy `delete` line.
check_redact_query() {
  local LC_ALL=C
  [[ $1 =~ ^[A-Za-z0-9_.-]+( [A-Za-z0-9_.-]+)*$ ]] && return 0
  err "Invalid LOG_REDACT_QUERY '$1': list query parameter names (letters, digits, _ . -) separated by spaces."
  return 1
}

# BACKUP: what the app's backups hold. Empty means the default (see backup_mode).
check_backup_mode() {
  case $1 in
    postgres | state | none) return 0 ;;
  esac
  err "Invalid BACKUP '$1': use postgres, state or none."
  return 1
}

# BACKUP_PATHS: paths inside the app's state folder, separated by single spaces. Each is relative, made
# of letters, digits and . _ -, never . or .., and no part starts with - (tar would read it as an
# option). Symlinks are checked when the backup runs (state_archive).
check_backup_paths() {
  local LC_ALL=C part='[A-Za-z0-9_.][A-Za-z0-9_.-]*' paths p
  if ! [[ $1 =~ ^[^[:space:]]+( [^[:space:]]+)*$ ]]; then
    err "Invalid BACKUP_PATHS '$1': separate the paths with single spaces."
    return 1
  fi
  read -r -a paths <<<"$1"
  for p in "${paths[@]}"; do
    if [[ $p =~ ^$part(/$part)*$ ]] && [[ /$p/ != */./* && /$p/ != */../* ]]; then continue; fi
    err "Invalid BACKUP_PATHS entry '$p': list paths inside the state folder, like backups photos (no leading /, and no . or .. parts)."
    return 1
  done
}

# EXTRA_PACKAGES: Debian package names, separated by spaces.
check_packages() {
  local LC_ALL=C
  [[ $1 =~ ^[a-z0-9][a-z0-9+.-]+( [a-z0-9][a-z0-9+.-]+)*$ ]] && return 0
  err "Invalid EXTRA_PACKAGES '$1': list Debian package names separated by spaces, like build-essential python3."
  return 1
}

# check_state_dir <app>: $STATE_ROOT/<app> may already exist only as the app's own folder. systemd hands
# a StateDirectory= to the unit's user, recursively, so an app named like a system folder (apt, or
# shipit, which holds the locks) would take that folder over.
check_state_dir() {
  local dir=$STATE_ROOT/$1 owner uid
  if [ "$dir" != "$SHIPIT_VAR" ]; then
    [ -e "$dir" ] || [ -L "$dir" ] || return 0
    if [ -d "$dir" ] && [ ! -L "$dir" ] && uid=$(id -u "$1" 2>/dev/null); then
      read -r _ _ owner _ < <(ls -ldn -- "$dir")
      [ "$owner" != "$uid" ] || return 0
    fi
  fi
  err "$dir already exists and isn't the $1 app's own folder, so systemd would hand it to $1. Choose another app name."
  return 1
}

check_number() {
  [[ $2 =~ ^[1-9][0-9]*$ ]] && return 0
  err "Invalid $1 '$2'."
  return 1
}

# The admin account setup uses: root, or a named login user other than the deploy account.
check_admin_user() {
  local LC_ALL=C
  if [[ $1 =~ ^[a-z][a-z0-9_-]{0,31}$ ]] && [ "$1" != "$DEPLOY_USER" ]; then
    return 0
  fi
  err "Invalid admin username '$1': use root, or a lowercase name (letters, digits, _ or -) other than $DEPLOY_USER."
  return 1
}

# The ACME email goes into the Caddyfile and host.conf, so only plain address characters are allowed.
check_email() {
  local LC_ALL=C
  [[ $1 =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] && return 0
  err "Invalid email '$1': use an address like you@example.com, or leave it blank."
  return 1
}

# Root sources files from SHIPIT_ETC, so each must be a regular file owned by root and not writable
# by group or others.
check_sourced_file() {
  local perms owner
  if [ ! -f "$1" ] || [ -L "$1" ]; then
    err "$1 is missing or isn't a regular file."
    return 1
  fi
  read -r perms _ owner _ < <(ls -ldn -- "$1")
  if [ "$owner" != "$SHIPIT_OWNER_UID" ] || [ "${perms:5:1}" = w ] || [ "${perms:8:1}" = w ]; then
    err "$1 must be owned by root and not writable by group or others. Fix it with: chown root:root $1 && chmod go-w $1"
    return 1
  fi
}

# ---- App configs ---------------------------------------------------------------------------------

# conf_get <file> <VAR>: prints VAR's value from a config file, sourced in a subshell after the
# ownership check. VAR is unset first, so a key the file doesn't set is empty rather than the caller's.
conf_get() {
  check_sourced_file "$1" || return 1
  (
    unset -v "$2"
    # shellcheck source=/dev/null
    . "$1"
    printf '%s' "${!2-}"
  )
}

# app_using <VAR> <value> [app]: prints the first app (other than <app>) whose config sets VAR to value.
app_using() {
  local f name value
  for f in "$SHIPIT_ETC"/apps/*.conf; do
    [ -e "$f" ] || continue
    name=$(basename "$f" .conf)
    [ "$name" != "${3-}" ] || continue
    value=$(conf_get "$f" "$1") || return 1
    if [ "$value" = "$2" ]; then
      printf '%s' "$name"
      return 0
    fi
  done
}

# The repo name, lowercased, with - and . turned into _. Not validated: the caller checks the result.
app_name_from_repo() {
  local name=${1%/}
  name=${name##*/}
  name=${name##*:}
  name=${name%.git}
  name=$(printf '%s' "$name" | LC_ALL=C tr 'A-Z.-' 'a-z__')
  printf '%s\n' "$name"
}

# The lowest port from FIRST_APP_PORT up that no app config uses and nothing listens on.
allocate_port() {
  local port=$FIRST_APP_PORT other
  while [ "$port" -le 65535 ]; do
    other=$(app_using PORT "$port") || return 1
    if [ -z "$other" ] && ! port_is_listening "$port"; then
      printf '%s\n' "$port"
      return 0
    fi
    port=$((port + 1))
  done
  err "No free port from $FIRST_APP_PORT to 65535."
  return 1
}

# ---- Backups -------------------------------------------------------------------------------------

# backup_mode <BACKUP> <DATABASE>: the app's backup mode. BACKUP when it's set; otherwise postgres for
# an app with a database and none without one, so configs written before BACKUP existed keep working.
backup_mode() {
  if [ -n "$1" ]; then
    printf '%s\n' "$1"
  elif [ -n "$2" ]; then
    printf 'postgres\n'
  else
    printf 'none\n'
  fi
}

# backup_ext <mode>: the extension of the mode's files. postgres dumps are .dump, state archives .tar.gz.
backup_ext() {
  if [ "$1" = state ]; then printf 'tar.gz\n'; else printf 'dump\n'; fi
}

# is_backup_name <app> <name> [ext]: whether name is one of the app's backups,
# <app>-<YYYYmmddTHHMMSSZ>.<ext> (ext defaults to dump). A path, a temp file or any other name isn't.
# <app> must already be a valid app name.
is_backup_name() {
  local LC_ALL=C ext=${3:-dump}
  [[ $2 =~ ^$1-[0-9]{8}T[0-9]{6}Z\.${ext//./\\.}$ ]]
}

# backup_files <app> [ext]: the names of the app's backups in $BACKUP_ROOT/<app>, oldest first (the
# names sort by time).
backup_files() {
  local f LC_ALL=C ext=${2:-dump}
  for f in "$BACKUP_ROOT/$1/$1"-*."$ext"; do
    if is_backup_name "$1" "${f##*/}" "$ext" && [ -f "$f" ]; then printf '%s\n' "${f##*/}"; fi
  done
}

# backup_prune <app> <keep> [ext]: deletes all but the newest <keep> of the app's backups. Temp files
# and other names in the folder are left alone.
backup_prune() {
  local names=() i
  mapfile -t names < <(backup_files "$1" "${3:-dump}")
  for ((i = 0; i < ${#names[@]} - $2; i++)); do
    rm -f -- "$BACKUP_ROOT/$1/${names[i]}"
    log "Deleted ${names[i]}."
  done
}

# Run as the app's user by state_archive, in the app's state folder ($1): checks each path ($2...; the
# whole folder when there are none) and writes a gzip'd tar of them to stdout. A path that isn't there
# yet is skipped; one that leads outside the folder (a symlink) stops the backup. Running as the app's
# user means a symlink can't reach anything the app can't read already.
# shellcheck disable=SC2016 # expanded by the app user's bash, not here
STATE_ARCHIVE_SCRIPT='set -euo pipefail
cd "$1"
root=$(pwd -P)
shift
[ "$#" -gt 0 ] || set -- .
paths=()
for p in "$@"; do
  if [ ! -e "$p" ] && [ ! -L "$p" ]; then
    echo "Skipped $p: it isn'"'"'t in $root yet." >&2
    continue
  fi
  real=$(realpath -e -- "$p") || { echo "$p is a broken symlink, so nothing was backed up." >&2; exit 1; }
  case $real in
    "$root" | "$root"/*) paths+=("$p") ;;
    *) echo "$p leads outside $root, so nothing was backed up." >&2; exit 1 ;;
  esac
done
[ "${#paths[@]}" -gt 0 ] || { echo "None of $* is in $root yet, so there is nothing to back up." >&2; exit 1; }
tar -czf - "${paths[@]}"'

# Run as the app's user by restore, in the app's state folder ($1), with an archive on stdin: removes
# the paths ($2...; everything in the folder when there are none), then extracts the archive. As the
# app's user, so neither step can touch anything the app can't.
# shellcheck disable=SC2016 # expanded by the app user's bash, not here
STATE_RESTORE_SCRIPT='set -euo pipefail
umask 027
cd "$1"
shift
if [ "$#" -eq 0 ]; then
  find . -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
else
  for p in "$@"; do rm -rf -- "$p"; done
fi
tar -xzf -'

# as_app <app> <command>...: runs the command as the app's user and group, with no other groups, a clean
# environment and from /. setpriv needs no PAM, so it also works inside the state backup unit, whose
# only capabilities are CAP_SETUID and CAP_SETGID.
as_app() {
  local app=$1
  shift
  (cd / && setpriv --reuid="$app" --regid="$app" --clear-groups -- env -i PATH=/usr/bin:/bin LANG=C.UTF-8 "$@")
}

# state_archive <app> [path]...: a gzip'd tar of the app's state folder, or of those paths in it, on
# stdout (STATE_ARCHIVE_SCRIPT, as the app's user).
state_archive() {
  local app=$1
  shift
  as_app "$app" bash -c "$STATE_ARCHIVE_SCRIPT" archive "$STATE_ROOT/$app" "$@" </dev/null
}

# ---- Files, users and prompts --------------------------------------------------------------------

is_shipit_file() {
  head -n 3 -- "$1" | grep "^$MANAGED_MARKER" >/dev/null
}

# install_if_changed <new file> <dest> <mode>: installs only when the content differs. Fails (1) when
# there was nothing to change.
install_if_changed() {
  if [ -f "$2" ] && cmp -s "$1" "$2"; then
    chmod "$3" "$2"
    return 1
  fi
  install -m "$3" "$1" "$2"
}

user_home() {
  getent passwd "$1" | cut -d: -f6
}

# ask <prompt> <var>: reads one answer. Fails when input runs out with nothing typed.
ask() {
  local reply
  read -r -p "$1" reply || [ -n "$reply" ] || return 1
  printf -v "$2" '%s' "$reply"
}

# ask_hidden <prompt> <var>: like ask, without showing what's typed (for secrets).
ask_hidden() {
  local reply
  read -r -s -p "$1" reply || [ -n "$reply" ] || return 1
  printf '\n' >&2
  printf -v "$2" '%s' "$reply"
}

# ---- Locks ---------------------------------------------------------------------------------------
# Each takes the lock file's path. The lock is held on the file descriptor in LOCK_FD until
# lock_release or the process exits. Save LOCK_FD before taking a second lock. LOCK_FDS lists every
# lock descriptor held, so lock_close_all can drop them before running code that may outlive us.
LOCK_FDS=()

lock_open() {
  exec {LOCK_FD}>>"$1" || return 1
  LOCK_FDS+=("$LOCK_FD")
}

# lock_try <path>: take the lock without waiting. Returns 1 if someone else holds it.
lock_try() {
  lock_open "$1" || return 1
  flock -n "$LOCK_FD" && return 0
  lock_release
  return 1
}

# lock_wait <path> [message]: take the lock, printing message first if it has to wait.
lock_wait() {
  lock_open "$1" || return 1
  flock -n "$LOCK_FD" && return 0
  [ -z "${2-}" ] || log "$2"
  flock "$LOCK_FD"
}

lock_release() {
  local fd kept=()
  exec {LOCK_FD}>&-
  for fd in "${LOCK_FDS[@]}"; do
    [ "$fd" = "$LOCK_FD" ] || kept+=("$fd")
  done
  LOCK_FDS=("${kept[@]}")
}

# lock_close_all: close every held lock descriptor in this shell. Call it in a subshell before
# running repo code, so a process the build leaves behind can't keep holding a lock.
lock_close_all() {
  local fd
  for fd in "${LOCK_FDS[@]}"; do
    exec {fd}>&-
  done
}

# ---- Templates -----------------------------------------------------------------------------------

# render <template> <VAR>...: prints the template with only the listed variables substituted. Every
# listed variable must be set and non-empty; otherwise it names the variable and prints nothing.
render() {
  local template=$1 var vars=''
  shift
  if [ ! -r "$template" ]; then
    err "render: can't read template $template"
    return 1
  fi
  for var in "$@"; do
    if [ -z "${!var-}" ]; then
      err "render: $var is unset or empty (template $template)"
      return 1
    fi
    vars+="\${$var} "
  done
  (
    # envsubst only sees exported variables.
    # shellcheck disable=SC2163
    for var in "$@"; do export "$var"; done
    envsubst "$vars" <"$template"
  )
}
