# shellcheck shell=bash
# shipit restore <app> [file | latest] (plan §3): asks you to type the app name, then, holding the app
# lock, takes a fresh backup, stops <app>.target and restores the chosen file from $BACKUP_ROOT/<app>/.
# BACKUP=postgres: pg_restore as postgres, then starts the target again (also when the restore fails).
# BACKUP=state: as the app's user, removes BACKUP_PATHS (or everything) from the state folder and
# extracts the archive, then starts the target and checks its health; a failed extract leaves the app
# stopped. lib/deploy.sh is sourced for the health check. Sourcing this file only defines constants and
# functions.

# shellcheck source=lib/backup.sh
. "${BASH_SOURCE[0]%/*}/backup.sh"
# shellcheck source=lib/deploy.sh
. "${BASH_SOURCE[0]%/*}/deploy.sh"

RESTORE_STOPPED=''

# restore_file <app> <file | latest>: prints the chosen backup's path. latest is the newest backup; a
# file must be one of the app's backup names (a bare name, no path, with BACKUP_EXT: dump by default)
# that exists in its backup folder.
restore_file() {
  local dir=$BACKUP_ROOT/$1 name=$2 ext=${BACKUP_EXT:-dump}
  if [ "$name" = latest ]; then
    name=$(backup_files "$1" "$ext" | tail -n 1)
    if [ -z "$name" ]; then
      err "There are no backups of $1 in $dir yet. Take one with: sudo shipit backup $1"
      return 1
    fi
  elif ! is_backup_name "$1" "$name" "$ext"; then
    err "Invalid backup '$name': give latest, or a file name from $dir, like $1-20261013T030000Z.$ext."
    return 1
  fi
  if [ ! -f "$dir/$name" ] || [ -L "$dir/$name" ]; then
    err "There's no backup named $name in $dir."
    return 1
  fi
  printf '%s\n' "$dir/$name"
}

# restore_confirm <app>: the app's name must be typed exactly.
restore_confirm() {
  local answer=''
  ask "Type the app name ($1) to confirm: " answer || true
  [ "$answer" = "$1" ] && return 0
  err "That isn't $1, so nothing was restored."
  return 1
}

# Starts the target again if the restore stopped it and then failed.
restore_exit() {
  [ -z "$RESTORE_STOPPED" ] && return 0
  systemctl start "$APP.target" || err "Starting $APP.target failed. Check: systemctl status '$APP@*'"
}

# restore_run <dump>: the fresh backup, then stop, pg_restore and start. The dump is opened first,
# because the fresh backup's pruning deletes the oldest dump, which may be the chosen one.
restore_run() {
  local fd name=${1##*/}
  exec {fd}<"$1" || die "Can't open $1."
  backup_now
  trap restore_exit EXIT
  systemctl stop "$APP.target" || die "Stopping $APP.target failed, so nothing was restored."
  RESTORE_STOPPED=1
  log "== Restoring $name into $DATABASE"
  # One transaction: if any of it fails, the database is left as it was.
  if ! (cd / && runuser -u postgres -- pg_restore --clean --if-exists --no-owner --role="$APP" \
    --single-transaction --dbname "$DATABASE") <&"$fd"; then
    die "Restoring $name failed, so $DATABASE is unchanged. Starting $APP again."
  fi
  exec {fd}<&-
  RESTORE_STOPPED=''
  systemctl start "$APP.target" || die "Restored $name, but starting $APP.target failed. Check: systemctl status '$APP@*'"
  log "Restored $name into $DATABASE, and started $APP again. Check it with: sudo shipit status $APP"
}

# restore_health_path: prints the current release's HEALTH_PATH (empty for the lenient check), read as
# data the way deploy reads it, in a subshell with its own temp folder.
restore_health_path() {
  (
    RELEASE=$(readlink "$SHIPIT_OPT/$APP/current") || die "$APP has no current release."
    DEPLOY_TMP=$(mktemp -d)
    trap 'rm -rf -- "$DEPLOY_TMP"' EXIT
    release_processes
    printf '%s\n' "$HEALTH_PATH"
  )
}

# restore_state_run <archive>: the fresh backup, then stop, extract as the app's user, start and check
# health. The archive is opened first, because the fresh backup's pruning may delete it. A failed
# extract can leave the folder half restored, so the app is left stopped and you're told how to go on.
restore_state_run() {
  local fd name=${1##*/} dir=$STATE_ROOT/$APP conf=$SHIPIT_ETC/apps/$APP.conf fresh
  DOMAIN=$(conf_get "$conf" DOMAIN) || exit 1
  PORT=$(conf_get "$conf" PORT) || exit 1
  { check_domain "$DOMAIN" "$APP" && check_port "$PORT" "$APP"; } || die "Fix $conf first."
  HEALTH_PATH=$(restore_health_path) || exit 1
  exec {fd}<"$1" || die "Can't open $1."
  backup_now
  fresh=$(backup_files "$APP" "$BACKUP_EXT" | tail -n 1)
  systemctl stop "$APP.target" || die "Stopping $APP.target failed, so nothing was restored."
  log "== Restoring $name into $dir"
  # shellcheck disable=SC2086 # split on spaces; check_backup_paths allows no glob characters
  if ! as_app "$APP" bash -c "$STATE_RESTORE_SCRIPT" restore "$dir" $BACKUP_PATHS <&"$fd"; then
    die "Restoring $name failed partway, so $dir may be incomplete, and $APP is left stopped." \
      "Put back what was there with sudo shipit restore $APP $fresh, or start $APP as it is with sudo systemctl start $APP.target"
  fi
  exec {fd}<&-
  systemctl start "$APP.target" || die "Restored $name, but starting $APP.target failed. Check: systemctl status '$APP@*'"
  health_wait || die "Restored $name into $dir and started $APP, but ${HEALTH_PATH:-/} answered $HEALTH_CODE." \
    "Check: sudo shipit logs $APP. Put back what was there with: sudo shipit restore $APP $fresh"
  log "Restored $name into $dir, and started $APP again. ${HEALTH_PATH:-/} answered $HEALTH_CODE."
}

cmd_restore() {
  local file
  if [ "$#" -lt 1 ] || [ "$#" -gt 2 ] || [ -z "$1" ] || [[ $1 == -* ]]; then
    die "Usage: sudo shipit restore <app> [file | latest]"
  fi
  backup_load "$1"
  [ -t 0 ] || die "restore asks you to type the app name to confirm, and there's no terminal to ask in. Run it in a terminal."
  lock_try "$SHIPIT_VAR/$APP.lock" || die "Another deploy or rollback of $APP is running."
  file=$(restore_file "$APP" "${2:-latest}") || exit 1
  if [ "$BACKUP" = state ]; then
    log "This replaces ${BACKUP_PATHS:-everything} in $STATE_ROOT/$APP with ${file##*/}, and stops $APP while it runs. A fresh backup is taken first."
    restore_confirm "$APP" || exit 1
    restore_state_run "$file"
    return
  fi
  log "This replaces everything in the $DATABASE database with ${file##*/}, and stops $APP while it runs. A fresh backup is taken first."
  restore_confirm "$APP" || exit 1
  restore_run "$file"
}
