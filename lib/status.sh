# shellcheck shell=bash
# shipit status [app] (plan §3): for each app, the current and previous releases, the state of each of
# the current release's processes, the health check, the last deploy.log line and the last backup;
# then `caddy validate` once, and where the backups are (plan R9). Read-only: it takes no lock and
# changes nothing. Sourcing this file only defines constants and functions.

# shellcheck source=lib/deploy.sh
. "${BASH_SOURCE[0]%/*}/deploy.sh"

# Where libexec/backup (S7) writes each app's dumps: $BACKUP_ROOT/<app>/<app>-<UTC>.dump.
BACKUP_ROOT=/var/backups/shipit

# ---- Formatting (unit-tested) --------------------------------------------------------------------

# status_line <label> <text>: one indented line of an app's block.
status_line() {
  printf '  %-10s %s\n' "$1" "$2"
}

# release_label <release dir>: "<sha> (<time> UTC)" from a releases/<YYYYmmddTHHMMSSZ>-<sha> name, or
# the bare name when it isn't one.
release_label() {
  local name=${1##*/} LC_ALL=C
  if [[ $name =~ ^([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})Z-([0-9a-f]+)$ ]]; then
    printf '%s (%s-%s-%s %s:%s:%s UTC)\n' "${BASH_REMATCH[7]}" "${BASH_REMATCH[@]:1:6}"
  else
    printf '%s\n' "$name"
  fi
}

# instance_text <app> <process> <state>: the state `systemctl is-active` gave. Anything but active is
# shouted, with where to look.
instance_text() {
  local state=${3:-unknown}
  if [ "$state" = active ]; then
    printf 'active\n'
  else
    printf '%s. See: sudo shipit logs %s %s, or systemctl status %s@%s\n' "${state^^}" "$1" "$2" "$1" "$2"
  fi
}

# health_text <path> <status code> [strict]: what the health check got, judged the way deploy does.
health_text() {
  local verdict=UNHEALTHY
  health_ok "$2" "${3-}" && verdict=healthy
  if [ "$2" = 000 ] || [ -z "$2" ]; then
    printf '%s got no answer (%s)\n' "$1" "$verdict"
  else
    printf '%s answered %s (%s)\n' "$1" "$2" "$verdict"
  fi
}

# backup_result: reads `systemctl show -p Result -p ExecMainExitTimestamp` of the backup unit on stdin
# and prints how its last run ended: success, failed (<result>), or never run.
backup_result() {
  awk -F= '
    $1 == "Result" { result = substr($0, 8) }
    $1 == "ExecMainExitTimestamp" { ran = (substr($0, 23) != "") }
    END {
      if (!ran) print "never run"
      else if (result == "success") print "success"
      else print "failed (" result ")"
    }'
}

# ---- One app -------------------------------------------------------------------------------------

# status_release <release>: prints the release's HEALTH_PATH on the first line, then its processes,
# read as data the way deploy reads them. Runs in a subshell, so a bad deploy.conf only fails this.
status_release() {
  (
    RELEASE=$1
    release_processes
    printf '%s\n' "$HEALTH_PATH" "${PROCESSES[@]}"
  )
}

status_backup() {
  local files last='none yet' result
  if [ -z "$DATABASE" ]; then
    status_line backup "none: $APP has no database"
    return 0
  fi
  files=("$BACKUP_ROOT/$APP/$APP"-*.dump)
  [ ! -e "${files[0]}" ] || last=${files[${#files[@]} - 1]##*/}
  result=$(systemctl show -p Result -p ExecMainExitTimestamp "shipit-backup@$APP.service" 2>/dev/null \
    | backup_result)
  status_line backup "$last (last run: $result)"
}

# status_app: the block for APP.
status_app() {
  local conf=$SHIPIT_ETC/apps/$APP.conf opt=$SHIPIT_OPT/$APP current previous info p state code last
  log "$APP"
  if ! DOMAIN=$(conf_get "$conf" DOMAIN) || ! PORT=$(conf_get "$conf" PORT) \
    || ! DATABASE=$(conf_get "$conf" DATABASE) || ! check_domain "$DOMAIN" "$APP" \
    || ! check_port "$PORT" "$APP"; then
    status_line config "$conf has a problem (see above). Fix it, then run sudo shipit deploy $APP"
    return 0
  fi
  status_line site "https://$DOMAIN (port $PORT)"

  current=$(readlink "$opt/current") || current=''
  previous=$(readlink "$opt/previous") || previous=''
  if [ -n "$current" ]; then
    status_line current "$(release_label "$current")"
  else
    status_line current "none yet. Deploy it with: sudo shipit deploy $APP"
  fi
  if [ -n "$previous" ]; then
    status_line previous "$(release_label "$previous")"
  else
    status_line previous none
  fi

  if [ -n "$current" ]; then
    if info=$(status_release "$current"); then
      { read -r HEALTH_PATH && mapfile -t PROCESSES; } <<<"$info"
      for p in "${PROCESSES[@]}"; do
        state=$(systemctl is-active "$APP@$p.service" 2>/dev/null) || true
        status_line "$p" "$(instance_text "$APP" "$p" "$state")"
      done
      code=$(health_code "${HEALTH_PATH:-/}")
      status_line health "$(health_text "${HEALTH_PATH:-/}" "$code" "${HEALTH_PATH:+1}")"
    else
      status_line processes "unknown: the current release's deploy.conf can't be read (see above)"
    fi
  fi

  last=$(tail -n 1 -- "$LOG_ROOT/$APP/deploy.log" 2>/dev/null) || last=''
  status_line deploy.log "${last:-none yet}"
  status_backup
}

# status_caddy: caddy validate on the live Caddyfile, once for every app.
status_caddy() {
  local out
  if out=$(caddy validate --config "$CADDYFILE" --adapter caddyfile 2>&1); then
    log "Caddy: $CADDYFILE is valid."
  else
    log "Caddy: $CADDYFILE is INVALID: $(tail -n 1 <<<"$out")"
    log "  Caddy keeps serving its old config, but no site can change until this is fixed. Check: caddy validate --config $CADDYFILE"
  fi
}

status_exit() {
  [ -z "$DEPLOY_TMP" ] || rm -rf -- "$DEPLOY_TMP"
}

cmd_status() {
  local apps=() f name
  if [ "$#" -gt 1 ] || [[ ${1-} == -* ]]; then die "Usage: sudo shipit status [app]"; fi
  if [ "$#" -eq 1 ]; then
    check_app_name "$1" || exit 1
    [ -e "$SHIPIT_ETC/apps/$1.conf" ] || die "There's no app named $1."
    apps=("$1")
  else
    for f in "$SHIPIT_ETC"/apps/*.conf; do
      [ -e "$f" ] || continue
      name=$(basename "$f" .conf)
      if check_app_name "$name"; then apps+=("$name"); fi
    done
  fi

  DEPLOY_TMP=$(mktemp -d)
  trap status_exit EXIT
  if [ "${#apps[@]}" -eq 0 ]; then
    log "No apps yet. Deploy one with: sudo shipit deploy https://github.com/<you>/<app>"
  fi
  for APP in "${apps[@]}"; do
    status_app
    log ''
  done
  status_caddy
  log "Backups are in $BACKUP_ROOT/<app>/, on this VPS's own disk, so losing the VPS loses them too. Hostinger's VPS snapshots or backups are the off-site copy."
}
