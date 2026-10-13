#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031,SC2034 # single-quoted stub bodies; tests set lib variables
# Backups: libexec/backup (DATABASE read as data, the dump's name, pruning), shipit backup (name and
# size, with systemctl stubbed), shipit restore (the file argument, the confirmation, and the run with
# systemctl and runuser stubbed) and deploy's backup timer step.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  load_common
  BACKUP_ROOT=$BATS_TEST_TMPDIR/backups
  dir=$BACKUP_ROOT/db_a
  mkdir -p "$dir"
  write_app_conf db_a REPO=file:///srv/git/db-a.git BRANCH=main DOMAIN=db-a.localhost PORT=3001 DATABASE=db_a
}

# dump <name>...: empty files in the app's backup folder.
dump() {
  local n
  for n in "$@"; do : >"$dir/$n"; done
}

# ---- Dump names ----------------------------------------------------------------------------------

@test "is_backup_name: only <app>-<YYYYmmddTHHMMSSZ>.dump" {
  is_backup_name db_a db_a-20261013T030000Z.dump
  local name
  for name in db_b-20261013T030000Z.dump db_a-20261013T0300Z.dump db_a-20261013T030000Z.dump.gz .dump-Ab12Cd \
    ../db_b/db_b-20261013T030000Z.dump db_a/../db_a-20261013T030000Z.dump "$dir/db_a-20261013T030000Z.dump"; do
    if is_backup_name db_a "$name"; then
      echo "accepted $name"
      return 1
    fi
  done
  if is_backup_name db db_a-20261013T030000Z.dump; then return 1; fi
}

@test "backup_files: the app's dumps, oldest first, ignoring temp files and foreign names" {
  dump db_a-20261013T030000Z.dump db_a-20261011T030000Z.dump db_a-20261012T030000Z.dump \
    .dump-Ab12Cd db_b-20261014T030000Z.dump db_a-latest.dump notes.txt
  mkdir "$dir/db_a-20261015T030000Z.dump"
  run backup_files db_a
  [ "$output" = $'db_a-20261011T030000Z.dump\ndb_a-20261012T030000Z.dump\ndb_a-20261013T030000Z.dump' ]
}

@test "backup_files: nothing when there are no dumps" {
  run backup_files db_a
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---- libexec/backup ------------------------------------------------------------------------------

load_libexec() {
  # shellcheck source=libexec/backup
  . "$REPO_ROOT/libexec/backup"
  BACKUP_ROOT=$BATS_TEST_TMPDIR/backups
  SHIPIT_ETC=$BATS_TEST_TMPDIR/etc
  SHIPIT_OWNER_UID=$(id -u)
}

@test "backup_database: plain, quoted, commented and empty values, last line wins" {
  load_libexec
  local c=$BATS_TEST_TMPDIR/c.conf
  for line in 'DATABASE=db_a' 'DATABASE="db_a"' "DATABASE='db_a'" 'DATABASE=db_a   # optional' 'DATABASE=db_a  '; do
    printf 'REPO=x\n%s\nPORT=1\n' "$line" >"$c"
    [ "$(backup_database "$c")" = db_a ] || {
      echo "misread: $line"
      return 1
    }
  done
  for line in 'DATABASE=' "DATABASE=''" 'DATABASE=""' 'DATABASE= # none' 'REPO=x'; do
    printf '%s\n' "$line" >"$c"
    run backup_database "$c"
    [ "$status" -eq 0 ] && [ -z "$output" ] || {
      echo "misread: $line -> $output"
      return 1
    }
  done
  printf 'DATABASE=old\nDATABASE=new\n' >"$c"
  [ "$(backup_database "$c")" = new ]
}

@test "backup_database: computed, odd or invalid values are refused, never run" {
  load_libexec
  local c=$BATS_TEST_TMPDIR/c.conf
  for line in 'DATABASE=$(touch '"$BATS_TEST_TMPDIR"'/ran)' 'DATABASE=`touch x`' 'DATABASE=$OTHER' \
    'DATABASE=a b' 'DATABASE=db_a#x' 'DATABASE="db_a"#x' 'DATABASE="db_a' 'DATABASE=Db' 'DATABASE=1db' \
    'DATABASE=db-a' 'DATABASE=db;rm'; do
    printf '%s\n' "$line" >"$c"
    run --separate-stderr backup_database "$c"
    [ "$status" -eq 1 ] || {
      echo "accepted: $line -> $output"
      return 1
    }
  done
  [ ! -e "$BATS_TEST_TMPDIR/ran" ]
  # Indented and exported lines aren't read (deploy writes plain lines).
  printf '  DATABASE=x\nexport DATABASE=y\n' >"$c"
  [ -z "$(backup_database "$c")" ]
}

@test "backup: dumps to a temp file, renames it to <app>-<UTC>.dump and prints the name and size" {
  load_libexec
  stub pg_dump 'echo "$*" >"'"$BATS_TEST_TMPDIR"'/pg_dump.args"; f=${2#--file=}; printf "PGDMP-data" >"$f"'
  BACKUP_KEEP=3 run backup db_a
  [ "$status" -eq 0 ]
  local names
  names=$(ls -A "$dir")
  [[ $names =~ ^db_a-[0-9]{8}T[0-9]{6}Z\.dump$ ]]
  [ "$(cat "$dir/$names")" = PGDMP-data ]
  [ "$output" = "Wrote $dir/$names (10 bytes)." ]
  [[ $(cat "$BATS_TEST_TMPDIR/pg_dump.args") =~ ^--format=custom\ --file=$dir/\.dump-[A-Za-z0-9]+\ db_a$ ]]
}

@test "backup: a failed pg_dump leaves no dump and no temp file, and exits non-zero" {
  load_libexec
  dump db_a-20261011T030000Z.dump
  stub pg_dump 'f=${2#--file=}; printf "half" >"$f"; exit 1'
  BACKUP_KEEP=1 run backup db_a
  [ "$status" -eq 1 ]
  [[ $output == *"pg_dump db_a failed, so no backup was written."* ]]
  [ "$(ls -A "$dir")" = db_a-20261011T030000Z.dump ]
}

@test "backup: keeps the newest BACKUP_KEEP dumps, leaving temp files and other names alone" {
  load_libexec
  dump db_a-20261010T030000Z.dump db_a-20261011T030000Z.dump db_a-20261012T030000Z.dump .dump-old \
    db_b-20261001T030000Z.dump
  stub pg_dump 'f=${2#--file=}; printf x >"$f"'
  BACKUP_KEEP=2 run backup db_a
  [ "$status" -eq 0 ]
  [[ $output == *$'Deleted db_a-20261010T030000Z.dump.\nDeleted db_a-20261011T030000Z.dump.' ]]
  run backup_files db_a
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = db_a-20261012T030000Z.dump ]
  [ -e "$dir/.dump-old" ]
  [ -e "$dir/db_b-20261001T030000Z.dump" ]
}

@test "backup: refuses a bad app, a bad BACKUP_KEEP, an app without a database and an unsafe config" {
  load_libexec
  stub pg_dump 'exit 99'
  BACKUP_KEEP=3 run backup ../x
  [ "$status" -eq 1 ]
  BACKUP_KEEP=0 run backup db_a
  [ "$status" -eq 1 ]
  [[ $output == *"Set BACKUP_KEEP in $SHIPIT_ETC/host.conf." ]]
  BACKUP_KEEP='' run backup db_a
  [ "$status" -eq 1 ]
  write_app_conf web REPO=x DATABASE=
  mkdir -p "$BACKUP_ROOT/web"
  BACKUP_KEEP=3 run backup web
  [ "$status" -eq 1 ]
  [[ $output == "web has no DATABASE in $SHIPIT_ETC/apps/web.conf, so there's nothing to back up." ]]
  chmod 666 "$SHIPIT_ETC/apps/db_a.conf"
  BACKUP_KEEP=3 run backup db_a
  [ "$status" -eq 1 ]
  [[ $output == *"must be owned by root and not writable"* ]]
  [ -z "$(ls -A "$dir")" ]
}

# ---- shipit backup -------------------------------------------------------------------------------

load_backup() {
  # shellcheck source=lib/backup.sh
  . "$REPO_ROOT/lib/backup.sh"
}

@test "shipit backup: starts the unit, then prints the new dump's name and size" {
  load_backup
  stub systemctl 'echo "$*" >>"'"$BATS_TEST_TMPDIR"'/systemctl.calls"
printf 12345 >"'"$dir"'/db_a-20261013T120000Z.dump"'
  dump db_a-20261012T030000Z.dump .dump-x
  run cmd_backup db_a
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/systemctl.calls")" = 'start shipit-backup@db_a.service' ]
  [ "$output" = "Backed up db_a to $dir/db_a-20261013T120000Z.dump (5 bytes)." ]
}

@test "shipit backup: a failed unit says where to look" {
  load_backup
  stub systemctl 'exit 1'
  run cmd_backup db_a
  [ "$status" -eq 1 ]
  [ "$output" = 'The backup of db_a failed. Check: journalctl -u shipit-backup@db_a.service' ]
}

@test "shipit backup: refuses bad arguments, unknown apps, apps without a database or not deployed" {
  load_backup
  stub systemctl 'echo "$*" >>"'"$BATS_TEST_TMPDIR"'/systemctl.calls"'
  run cmd_backup
  [[ $output == Usage:* ]]
  run cmd_backup db_a extra
  [[ $output == Usage:* ]]
  run cmd_backup Bad
  [ "$status" -eq 1 ]
  run cmd_backup nope
  [ "$output" = "There's no app named nope." ]
  write_app_conf web REPO=x DOMAIN=web.localhost PORT=3002 DATABASE=
  run cmd_backup web
  [ "$status" -eq 1 ]
  [ "$output" = "web has no database (DATABASE is empty in $SHIPIT_ETC/apps/web.conf), so it has no backups." ]
  write_app_conf db_b REPO=x DOMAIN=db-b.localhost PORT=3003 DATABASE=db_b
  run cmd_backup db_b
  [ "$status" -eq 1 ]
  [ "$output" = "$BACKUP_ROOT/db_b doesn't exist yet. Deploy the app first: sudo shipit deploy db_b" ]
  [ ! -e "$BATS_TEST_TMPDIR/systemctl.calls" ]
}

# ---- shipit restore ------------------------------------------------------------------------------

load_restore() {
  # shellcheck source=lib/restore.sh
  . "$REPO_ROOT/lib/restore.sh"
}

@test "restore_file: latest is the newest dump" {
  load_restore
  dump db_a-20261011T030000Z.dump db_a-20261013T030000Z.dump db_a-20261012T030000Z.dump .dump-x \
    db_a-20261099T999999Z.dump.tmp
  [ "$(restore_file db_a latest)" = "$dir/db_a-20261013T030000Z.dump" ]
}

@test "restore_file: latest with no dumps says how to take one" {
  load_restore
  dump .dump-x
  run --separate-stderr restore_file db_a latest
  [ "$status" -eq 1 ]
  [ "$stderr" = "There are no backups of db_a in $dir yet. Take one with: sudo shipit backup db_a" ]
}

@test "restore_file: an explicit dump name in the app's folder" {
  load_restore
  dump db_a-20261011T030000Z.dump db_a-20261013T030000Z.dump
  [ "$(restore_file db_a db_a-20261011T030000Z.dump)" = "$dir/db_a-20261011T030000Z.dump" ]
  run --separate-stderr restore_file db_a db_a-20261012T030000Z.dump
  [ "$status" -eq 1 ]
  [ "$stderr" = "There's no backup named db_a-20261012T030000Z.dump in $dir." ]
}

@test "restore_file: paths, traversal, other apps' dumps, temp files and symlinks are refused" {
  load_restore
  mkdir -p "$BACKUP_ROOT/db_b"
  : >"$BACKUP_ROOT/db_b/db_b-20261013T030000Z.dump"
  dump .dump-x
  ln -s /etc/passwd "$dir/db_a-20261014T030000Z.dump"
  local arg
  for arg in ../db_b/db_b-20261013T030000Z.dump db_b-20261013T030000Z.dump "$dir/db_a-20261013T030000Z.dump" \
    ./db_a-20261013T030000Z.dump '../../etc/passwd' .dump-x '' db_a-20261013T030000Z.dump/ \
    'db_a-20261013T030000Z.dump
x'; do
    run --separate-stderr restore_file db_a "$arg"
    [ "$status" -eq 1 ] && [[ $stderr == "Invalid backup '"* ]] || {
      echo "accepted: $arg -> $output $stderr"
      return 1
    }
  done
  run --separate-stderr restore_file db_a db_a-20261014T030000Z.dump
  [ "$status" -eq 1 ]
  [ "$stderr" = "There's no backup named db_a-20261014T030000Z.dump in $dir." ]
}

@test "restore_confirm: only the exact app name confirms" {
  load_restore
  run restore_confirm db_a <<<db_a
  [ "$status" -eq 0 ]
  local answer
  for answer in db_b DB_A db_a_x 'db a' yes ''; do
    run --separate-stderr restore_confirm db_a <<<"$answer"
    [ "$status" -eq 1 ] && [ "$stderr" = "That isn't db_a, so nothing was restored." ] || {
      echo "confirmed with '$answer'"
      return 1
    }
  done
  run restore_confirm db_a </dev/null
  [ "$status" -eq 1 ]
}

@test "shipit restore: refuses without a terminal, before taking the lock or touching anything" {
  load_restore
  stub systemctl 'echo "$*" >>"'"$BATS_TEST_TMPDIR"'/systemctl.calls"'
  dump db_a-20261013T030000Z.dump
  run cmd_restore db_a latest </dev/null
  [ "$status" -eq 1 ]
  [ "$output" = "restore asks you to type the app name to confirm, and there's no terminal to ask in. Run it in a terminal." ]
  [ ! -e "$BATS_TEST_TMPDIR/systemctl.calls" ]
  [ ! -e "$SHIPIT_VAR/db_a.lock" ]
}

@test "shipit restore: refuses bad arguments and apps without a database" {
  load_restore
  run cmd_restore
  [[ $output == Usage:* ]]
  run cmd_restore db_a latest extra
  [[ $output == Usage:* ]]
  run cmd_restore --help
  [[ $output == Usage:* ]]
  write_app_conf web REPO=x DOMAIN=web.localhost PORT=3002 DATABASE=
  run cmd_restore web
  [ "$status" -eq 1 ]
  [[ $output == "web has no database"* ]]
}

# restore_stubs [pg_restore exit status]: systemctl logs its calls; the backup unit writes a new dump;
# runuser logs its arguments and the bytes it gets on stdin.
restore_stubs() {
  stub systemctl 'echo "$*" >>"'"$BATS_TEST_TMPDIR"'/systemctl.calls"
[ "$1 $2" != "start shipit-backup@db_a.service" ] || printf now >"'"$dir"'/db_a-20261013T120000Z.dump"'
  stub runuser 'echo "$*" >"'"$BATS_TEST_TMPDIR"'/runuser.args"; cat >"'"$BATS_TEST_TMPDIR"'/restored"; exit '"${1:-0}"
}

@test "restore_run: fresh backup, stop, pg_restore as postgres from the dump, start" {
  load_restore
  restore_stubs
  APP=db_a DATABASE=db_a
  printf old-data >"$dir/db_a-20261011T030000Z.dump"
  run restore_run "$dir/db_a-20261011T030000Z.dump"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/systemctl.calls")" = $'start shipit-backup@db_a.service\nstop db_a.target\nstart db_a.target' ]
  [ "$(cat "$BATS_TEST_TMPDIR/runuser.args")" = '-u postgres -- pg_restore --clean --if-exists --no-owner --role=db_a --single-transaction --dbname db_a' ]
  [ "$(cat "$BATS_TEST_TMPDIR/restored")" = old-data ]
  [[ $output == *"Backed up db_a to $dir/db_a-20261013T120000Z.dump (3 bytes)."* ]]
  [[ $output == *"Restored db_a-20261011T030000Z.dump into db_a, and started db_a again."* ]]
}

@test "restore_run: the chosen dump is restored even if the fresh backup prunes it" {
  load_restore
  APP=db_a DATABASE=db_a
  printf oldest >"$dir/db_a-20261011T030000Z.dump"
  stub systemctl '[ "$1" != start ] || [ "$2" != shipit-backup@db_a.service ] || {
  printf now >"'"$dir"'/db_a-20261013T120000Z.dump"; rm "'"$dir"'/db_a-20261011T030000Z.dump"; }'
  stub runuser 'cat >"'"$BATS_TEST_TMPDIR"'/restored"'
  run restore_run "$dir/db_a-20261011T030000Z.dump"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/restored")" = oldest ]
}

@test "restore_run: a failed pg_restore still starts the target again" {
  load_restore
  restore_stubs 1
  APP=db_a DATABASE=db_a
  : >"$dir/db_a-20261011T030000Z.dump"
  run restore_run "$dir/db_a-20261011T030000Z.dump"
  [ "$status" -eq 1 ]
  [ "$(cat "$BATS_TEST_TMPDIR/systemctl.calls")" = $'start shipit-backup@db_a.service\nstop db_a.target\nstart db_a.target' ]
  [[ $output == *"Restoring db_a-20261011T030000Z.dump failed, so db_a is unchanged. Starting db_a again." ]]
}

@test "restore_run: a failed fresh backup stops before anything is stopped" {
  load_restore
  stub systemctl 'echo "$*" >>"'"$BATS_TEST_TMPDIR"'/systemctl.calls"; exit 1'
  stub runuser 'touch "'"$BATS_TEST_TMPDIR"'/ran"'
  APP=db_a DATABASE=db_a
  : >"$dir/db_a-20261011T030000Z.dump"
  run restore_run "$dir/db_a-20261011T030000Z.dump"
  [ "$status" -eq 1 ]
  [ "$(cat "$BATS_TEST_TMPDIR/systemctl.calls")" = 'start shipit-backup@db_a.service' ]
  [ ! -e "$BATS_TEST_TMPDIR/ran" ]
}

# ---- deploy's backup timer step ------------------------------------------------------------------

load_deploy() {
  # shellcheck source=lib/deploy.sh
  . "$REPO_ROOT/lib/deploy.sh"
  APP=db_a
  stub install 'echo "$*" >>"'"$BATS_TEST_TMPDIR"'/install.calls"'
  # systemctl: is-enabled answers from the file "enabled"; enable and disable change it.
  stub systemctl 'echo "$*" >>"'"$BATS_TEST_TMPDIR"'/systemctl.calls"
e="'"$BATS_TEST_TMPDIR"'/enabled"
case $1 in
  is-enabled) [ -e "$e" ] ;;
  enable) touch "$e" ;;
  disable) rm -f "$e" ;;
esac'
}

@test "deploy_backups: an app with a database gets its folder and an enabled timer, once" {
  load_deploy
  DATABASE=db_a
  run deploy_backups
  [ "$status" -eq 0 ]
  [ "$output" = "Enabled shipit-backup@db_a.timer: daily backups of db_a to $BACKUP_ROOT/db_a." ]
  [ "$(cat "$BATS_TEST_TMPDIR/install.calls")" = "-d -m 700 -o postgres -g postgres $BACKUP_ROOT/db_a" ]
  grep -qx 'enable --quiet --now shipit-backup@db_a.timer' "$BATS_TEST_TMPDIR/systemctl.calls"
  rm "$BATS_TEST_TMPDIR/systemctl.calls"
  run deploy_backups
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$BATS_TEST_TMPDIR/systemctl.calls")" = 'is-enabled --quiet shipit-backup@db_a.timer' ]
}

@test "deploy_backups: without a database, nothing; a timer left enabled is disabled, keeping dumps" {
  load_deploy
  DATABASE=''
  run deploy_backups
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$BATS_TEST_TMPDIR/systemctl.calls")" = 'is-enabled --quiet shipit-backup@db_a.timer' ]
  touch "$BATS_TEST_TMPDIR/enabled"
  run deploy_backups
  [ "$output" = "Disabled shipit-backup@db_a.timer, because db_a has no DATABASE now. Its dumps stay in $BACKUP_ROOT/db_a." ]
  grep -qx 'disable --quiet --now shipit-backup@db_a.timer' "$BATS_TEST_TMPDIR/systemctl.calls"
  [ ! -e "$BATS_TEST_TMPDIR/install.calls" ]
}
