# shellcheck shell=bash
# shipit backup <app> (plan §3): runs the app's backup unit now (shipit-backup@<app>.service, pg_dump as
# postgres, for BACKUP=postgres; shipit-state-backup@<app>.service, tar of the state folder, for
# BACKUP=state), waits for it, then prints the new file's name and size. lib/restore.sh sources this
# file for the fresh backup it takes first. Sourcing this file only defines constants and functions.

APP=''
DATABASE=''
BACKUP=''
BACKUP_PATHS=''
BACKUP_UNIT=''
BACKUP_EXT=''

# backup_load <app>: sets APP, DATABASE, BACKUP (the mode, default applied), BACKUP_PATHS, BACKUP_UNIT and
# BACKUP_EXT from the app's config. Refuses an app with BACKUP=none, or whose backup folder deploy
# hasn't made yet.
backup_load() {
  local conf value
  check_app_name "$1" || exit 1
  APP=$1
  conf=$SHIPIT_ETC/apps/$APP.conf
  [ -e "$conf" ] || die "There's no app named $APP."
  DATABASE=$(conf_get "$conf" DATABASE) || exit 1
  value=$(conf_get "$conf" BACKUP) || exit 1
  BACKUP_PATHS=$(conf_get "$conf" BACKUP_PATHS) || exit 1
  [ -z "$value" ] || check_backup_mode "$value" || die "Fix $conf first."
  BACKUP=$(backup_mode "$value" "$DATABASE")
  case $BACKUP in
    none)
      [ -n "$value" ] || die "$APP has no backups: BACKUP is none by default, because DATABASE is empty in $conf. Set BACKUP=state in $conf to back up $STATE_ROOT/$APP."
      die "$APP has no backups, because $conf sets BACKUP=none."
      ;;
    postgres)
      [ -n "$DATABASE" ] || die "$conf sets BACKUP=postgres, but DATABASE is empty. Fix $conf first."
      check_database "$DATABASE" "$APP" || die "Fix $conf first."
      BACKUP_UNIT=shipit-backup@$APP.service
      ;;
    state)
      [ -z "$BACKUP_PATHS" ] || check_backup_paths "$BACKUP_PATHS" || die "Fix $conf first."
      BACKUP_UNIT=shipit-state-backup@$APP.service
      ;;
  esac
  BACKUP_EXT=$(backup_ext "$BACKUP")
  [ -d "$BACKUP_ROOT/$APP" ] || die "$BACKUP_ROOT/$APP doesn't exist yet. Deploy the app first: sudo shipit deploy $APP"
}

# backup_now: runs the backup unit and waits for it, then prints the newest backup's name and size.
backup_now() {
  local name file
  systemctl start "$BACKUP_UNIT" \
    || die "The backup of $APP failed. Check: journalctl -u $BACKUP_UNIT"
  name=$(backup_files "$APP" "$BACKUP_EXT" | tail -n 1)
  [ -n "$name" ] || die "The backup unit finished, but there's no backup in $BACKUP_ROOT/$APP."
  file=$BACKUP_ROOT/$APP/$name
  log "Backed up $APP to $file ($(wc -c <"$file" | tr -d ' ') bytes)."
}

cmd_backup() {
  if [ "$#" -ne 1 ] || [ -z "$1" ] || [[ $1 == -* ]]; then die "Usage: sudo shipit backup <app>"; fi
  backup_load "$1"
  backup_now
}
