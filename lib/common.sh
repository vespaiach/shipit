# shellcheck shell=bash
# Shared helpers for every shipit command: output, validators, locks, render(), file installs and the
# atomic symlink switch. Sourcing this file only defines constants and functions. It never runs
# anything, so tests can source it.

# Test seams (plan §4): plain constants, never read from the environment. Unit tests reassign them.
# shellcheck disable=SC2034 # used by the command libraries that source this file
SHIPIT_ETC=/etc/shipit
# shellcheck disable=SC2034 # used by the command libraries that source this file
SHIPIT_VAR=/var/lib/shipit
# Where each site's code lives: $SRV_ROOT/<name>/{repo.git,releases,current,previous}.
# shellcheck disable=SC2034 # used by the command libraries that source this file
SRV_ROOT=/srv
# Caddy's config (Caddyfile, sites/<name>.caddy) and the per-site access logs.
# shellcheck disable=SC2034 # used by the command libraries that source this file
CADDY_ETC=/etc/caddy
# shellcheck disable=SC2034 # used by the command libraries that source this file
LOG_ROOT=/var/log/shipit
# Where a node/nextjs site's unit goes: $SYSTEMD_DIR/shipit-<name>.service.
# shellcheck disable=SC2034 # used by the command libraries that source this file
SYSTEMD_DIR=/etc/systemd/system
# systemd's CacheDirectory= root: a Next.js release's .next/cache links to $CACHE_ROOT/shipit-<name>.
# shellcheck disable=SC2034 # used by the command libraries that source this file
CACHE_ROOT=/var/cache
# Host files setup reads or writes (plan §5.1).
# shellcheck disable=SC2034 # used by the command libraries that source this file
OS_RELEASE=/etc/os-release
# apt's config: sources.list.d, preferences.d, apt.conf.d and keyrings.
# shellcheck disable=SC2034 # used by the command libraries that source this file
APT_ETC=/etc/apt
# sshd's config: sshd_config.d and the host keys (ssh_host_*_key.pub).
# shellcheck disable=SC2034 # used by the command libraries that source this file
SSH_ETC=/etc/ssh
# shellcheck disable=SC2034 # used by the command libraries that source this file
FAIL2BAN_ETC=/etc/fail2ban
# Root's home, for .ssh/authorized_keys.
# shellcheck disable=SC2034 # used by the command libraries that source this file
ROOT_HOME=/root

# Where render's templates live: templates/ next to lib/, in a checkout and when installed.
# shellcheck disable=SC2034 # used by the command libraries that source this file
SHIPIT_TEMPLATES=${BASH_SOURCE[0]%/*}/../templates

log() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }
die() {
  err "$@"
  exit 1
}

# ---- Validators ----------------------------------------------------------------------------------
# Each is silent on success, and prints the reason to stderr and returns 1 when the value is refused.
# LC_ALL=C keeps [a-z] ASCII.

# check_domain <domain>: a lowercase hostname with at least one dot.
check_domain() {
  local LC_ALL=C label='[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?'
  [[ $1 =~ ^$label(\.$label)+$ ]] && return 0
  err "Invalid domain '$1': use a lowercase hostname with at least one dot, like app.example.com."
  return 1
}

# check_port <port>: a number from 1024 to 65535.
check_port() {
  local LC_ALL=C
  if [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && [ "$1" -ge 1024 ] && [ "$1" -le 65535 ]; then
    return 0
  fi
  err "Invalid port '$1': use a number from 1024 to 65535."
  return 1
}

# ---- Health checks -------------------------------------------------------------------------------

# health_ok <status code> [strict]: strict (site.health set) needs exactly 200. Otherwise any answer
# below 500 counts, because many sites redirect / to a login page. 000 means no answer at all.
health_ok() {
  local LC_ALL=C
  [[ $1 =~ ^[1-5][0-9][0-9]$ ]] || return 1
  if [ -n "${2-}" ]; then
    [ "$1" = 200 ]
  else
    [ "$1" -lt 500 ]
  fi
}

# ---- Users ---------------------------------------------------------------------------------------

# user_state <user> <comment>: prints missing, shipit (its GECOS field is <comment>, so shipit made it)
# or other.
user_state() {
  local entry gecos
  if ! entry=$(getent passwd "$1"); then
    echo missing
    return 0
  fi
  IFS=: read -r _ _ _ _ gecos _ <<<"$entry"
  if [ "$gecos" = "$2" ]; then echo shipit; else echo other; fi
}

# ---- Files ---------------------------------------------------------------------------------------

# install_if_changed <new file> <dest> <mode>: installs only when the content differs. Fails (1) when
# there was nothing to change.
install_if_changed() {
  if [ -f "$2" ] && cmp -s "$1" "$2"; then
    chmod "$3" "$2"
    return 1
  fi
  install -m "$3" "$1" "$2"
}

# is_shipit_file <file>: one of its first three lines is the managed marker, as a # or // comment.
# grep reads everything (no -q), so head never gets SIGPIPE under pipefail.
is_shipit_file() {
  head -n 3 -- "$1" 2>/dev/null | grep -E '^(#|//) managed by shipit' >/dev/null
}

# atomic_link <target> <link>: points link at target in one rename(2), so a reader sees either the
# old target or the new one, never no link.
atomic_link() {
  rm -f -- "$2.new"
  ln -s -- "$1" "$2.new" && mv -T -- "$2.new" "$2"
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
