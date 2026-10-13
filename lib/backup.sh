# shellcheck shell=bash
# shipit backup <app> (plan §3): runs shipit-backup@<app>.service now (libexec/backup, as postgres),
# waits for it, then prints the new dump's name and size. lib/restore.sh sources this file for the
# fresh backup it takes first. Sourcing this file only defines constants and functions.

APP=''
DATABASE=''

# backup_load <app>: sets APP and DATABASE from the app's config. Refuses an app without a database, or
# whose backup folder deploy hasn't made yet.
backup_load() {
  local conf
  check_app_name "$1" || exit 1
  APP=$1
  conf=$SHIPIT_ETC/apps/$APP.conf
  [ -e "$conf" ] || die "There's no app named $APP."
  DATABASE=$(conf_get "$conf" DATABASE) || exit 1
  [ -n "$DATABASE" ] || die "$APP has no database (DATABASE is empty in $conf), so it has no backups."
  check_database "$DATABASE" "$APP" || die "Fix $conf first."
  [ -d "$BACKUP_ROOT/$APP" ] || die "$BACKUP_ROOT/$APP doesn't exist yet. Deploy the app first: sudo shipit deploy $APP"
}

# backup_now: runs the backup unit and waits for it, then prints the newest dump's name and size.
backup_now() {
  local name file
  systemctl start "shipit-backup@$APP.service" \
    || die "The backup of $APP failed. Check: journalctl -u shipit-backup@$APP.service"
  name=$(backup_files "$APP" | tail -n 1)
  [ -n "$name" ] || die "The backup unit finished, but there's no dump in $BACKUP_ROOT/$APP."
  file=$BACKUP_ROOT/$APP/$name
  log "Backed up $APP to $file ($(wc -c <"$file" | tr -d ' ') bytes)."
}

cmd_backup() {
  if [ "$#" -ne 1 ] || [ -z "$1" ] || [[ $1 == -* ]]; then die "Usage: sudo shipit backup <app>"; fi
  backup_load "$1"
  backup_now
}
