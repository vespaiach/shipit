# shellcheck shell=bash
# shipit logs <app> [process | access | deploy] (plan §3): `tail -n 100 -F` on the chosen log, or on
# every current log of the app (each *.log in /var/log/shipit/<app>, not the rotated ones or builds/).
# Sourcing this file only defines constants and functions.

# shellcheck source=lib/deploy.sh
. "${BASH_SOURCE[0]%/*}/deploy.sh"

# log_targets <dir>: the names `shipit logs` accepts for the logs in <dir>, one per line: each
# <name>.log, with the <process>.error.log files folded into their process.
log_targets() {
  local f name
  for f in "$1"/*.log; do
    [ -f "$f" ] || continue
    name=${f##*/}
    name=${name%.log}
    [[ $name == *.error ]] || printf '%s\n' "$name"
  done
}

# log_files <dir> [target]: the files to follow: <target>.log (and <target>.error.log, if there is one),
# or every *.log in <dir> when no target is given. Fails, listing the targets there are, for a target
# that has no log.
log_files() {
  local dir=$1 target=${2-} f
  if [ -z "$target" ]; then
    for f in "$dir"/*.log; do
      [ ! -f "$f" ] || printf '%s\n' "$f"
    done
    return 0
  fi
  check_process_name "$target" || return 1
  if [ ! -f "$dir/$target.log" ]; then
    err "There's no $target log in $dir. Choose one of: $(log_targets "$dir" | paste -sd ' ' -)."
    return 1
  fi
  printf '%s\n' "$dir/$target.log"
  [ ! -f "$dir/$target.error.log" ] || printf '%s\n' "$dir/$target.error.log"
}

cmd_logs() {
  local dir out files=()
  if [ "$#" -lt 1 ] || [ "$#" -gt 2 ] || [ -z "$1" ] || [[ $1 == -* ]]; then
    die "Usage: sudo shipit logs <app> [process | access | deploy]"
  fi
  check_app_name "$1" || exit 1
  [ -e "$SHIPIT_ETC/apps/$1.conf" ] || die "There's no app named $1."
  dir=$LOG_ROOT/$1
  out=$(log_files "$dir" "${2-}") || exit 1
  [ -n "$out" ] || die "There are no logs in $dir yet. Deploy the app first: sudo shipit deploy $1"
  mapfile -t files <<<"$out"
  exec tail -n 100 -F -- "${files[@]}"
}
