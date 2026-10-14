#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031,SC2034 # single-quoted stub bodies; tests set lib variables
# The state folder and BACKUP=state: as_app (setpriv stubbed to run the command as the test user), the
# archive and restore scripts, libexec/state-backup, shipit backup and restore in state mode, and that
# nothing deploy or rollback removes is in the state folder.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  load_common
  BACKUP_ROOT=$BATS_TEST_TMPDIR/backups
  SHIPIT_OPT=$BATS_TEST_TMPDIR/opt
  dir=$BACKUP_ROOT/st
  state=$STATE_ROOT/st
  mkdir -p "$dir" "$state"
  write_app_conf st REPO=file:///srv/git/st.git BRANCH=main DOMAIN=st.localhost PORT=3001 DATABASE= \
    BACKUP=state 'BACKUP_PATHS="backups photos"'
  # setpriv: logs its arguments, then runs the command after -- as the test user.
  stub setpriv 'echo "$*" >>"'"$BATS_TEST_TMPDIR"'/setpriv.calls"
while [ "$1" != -- ]; do shift; done
shift
exec "$@"'
}

# need_gnu: the archive script uses realpath -e (GNU coreutils), as on Debian.
need_gnu() {
  realpath -e / >/dev/null 2>&1 || skip "needs GNU realpath (realpath -e), as on Debian"
}

# files <dir>: the files under dir, relative and sorted, with their contents.
files() {
  (cd "$1" && find . -type f | LC_ALL=C sort | while read -r f; do printf '%s=%s\n' "$f" "$(cat "$f")"; done)
}

# fill_state: a live database, snapshots and photos in the state folder.
fill_state() {
  mkdir -p "$state/backups" "$state/photos/2026"
  printf live >"$state/glance.db"
  printf snap >"$state/backups/glance-1.db"
  printf jpg >"$state/photos/2026/a.jpg"
}

# archive <name> [path]...: state_archive straight into a file in the backup folder (a shell variable
# can't hold the archive's NUL bytes), leaving its exit status in $status and its stderr in $stderr.
archive() {
  local name=$1
  shift
  status=0
  state_archive st "$@" >"$dir/$name" 2>"$BATS_TEST_TMPDIR/stderr" || status=$?
  stderr=$(cat "$BATS_TEST_TMPDIR/stderr")
}

# ---- as_app --------------------------------------------------------------------------------------

@test "as_app: the app's user and group, no other groups, a clean environment, from /" {
  cd "$BATS_TEST_TMPDIR"
  SECRET=x run as_app st bash -c 'pwd; echo "${SECRET-unset}"'
  [ "$status" -eq 0 ]
  [ "$output" = $'/\nunset' ]
  [ "$(cat "$BATS_TEST_TMPDIR/setpriv.calls")" = '--reuid=st --regid=st --clear-groups -- env -i PATH=/usr/bin:/bin LANG=C.UTF-8 bash -c pwd; echo "${SECRET-unset}"' ]
}

# ---- The archive and restore scripts -------------------------------------------------------------

@test "state_archive: only the listed paths, as the app's user" {
  need_gnu
  fill_state
  state_archive st backups photos >"$dir/a.tar.gz"
  [ "$(tar -tzf "$dir/a.tar.gz" | LC_ALL=C sort | tr '\n' ' ')" = 'backups/ backups/glance-1.db photos/ photos/2026/ photos/2026/a.jpg ' ]
  grep -q -- "--reuid=st --regid=st" "$BATS_TEST_TMPDIR/setpriv.calls"
}

@test "state_archive: the whole folder when no paths are listed" {
  need_gnu
  fill_state
  state_archive st >"$dir/a.tar.gz"
  tar -tzf "$dir/a.tar.gz" | grep -qx './glance.db'
  tar -tzf "$dir/a.tar.gz" | grep -qx './photos/2026/a.jpg'
}

@test "state_archive: a path that isn't there yet is skipped; with none there, nothing is backed up" {
  need_gnu
  fill_state
  rm -rf "$state/photos"
  archive a.tar.gz backups photos
  [ "$status" -eq 0 ]
  [ "$stderr" = "Skipped photos: it isn't in $(cd "$state" && pwd -P) yet." ]
  [ "$(tar -tzf "$dir/a.tar.gz" | LC_ALL=C sort | tr '\n' ' ')" = 'backups/ backups/glance-1.db ' ]
  rm -rf "$state/backups"
  archive b.tar.gz backups photos
  [ "$status" -eq 1 ]
  [[ $stderr == *"None of backups photos is in $(cd "$state" && pwd -P) yet, so there is nothing to back up." ]]
}

@test "state_archive: a symlink out of the folder, at any level, stops the backup" {
  need_gnu
  fill_state
  mkdir -p "$BATS_TEST_TMPDIR/outside/secrets"
  printf secret >"$BATS_TEST_TMPDIR/outside/secrets/key"
  ln -s "$BATS_TEST_TMPDIR/outside/secrets" "$state/leak"
  archive a.tar.gz backups leak
  [ "$status" -eq 1 ]
  [[ $stderr == *"leak leads outside $(cd "$state" && pwd -P), so nothing was backed up." ]]
  [ ! -s "$dir/a.tar.gz" ]
  ln -s "$BATS_TEST_TMPDIR/outside" "$state/via"
  archive b.tar.gz via/secrets
  [ "$status" -eq 1 ]
  [[ $stderr == *"via/secrets leads outside"* ]]
  ln -s "$state/nowhere" "$state/dangling"
  archive c.tar.gz dangling
  [ "$status" -eq 1 ]
  [[ $stderr == *"dangling is a broken symlink, so nothing was backed up." ]]
  # A symlink that stays inside the folder is archived as a link.
  ln -s backups "$state/snapshots"
  archive d.tar.gz snapshots
  [ "$status" -eq 0 ]
}

@test "restore script: removes the listed paths, extracts, and leaves the rest alone" {
  need_gnu
  fill_state
  state_archive st backups photos >"$dir/a.tar.gz"
  printf live2 >"$state/glance.db"
  printf snap2 >"$state/backups/glance-2.db"
  rm -rf "$state/photos/2026"
  printf new >"$state/photos/b.jpg"
  as_app st bash -c "$STATE_RESTORE_SCRIPT" restore "$state" backups photos <"$dir/a.tar.gz"
  [ "$(files "$state")" = $'./backups/glance-1.db=snap\n./glance.db=live2\n./photos/2026/a.jpg=jpg' ]
}

@test "restore script: with no paths, the whole folder is replaced" {
  need_gnu
  fill_state
  state_archive st >"$dir/a.tar.gz"
  printf extra >"$state/extra"
  printf live2 >"$state/glance.db"
  as_app st bash -c "$STATE_RESTORE_SCRIPT" restore "$state" <"$dir/a.tar.gz"
  [ "$(files "$state")" = $'./backups/glance-1.db=snap\n./glance.db=live\n./photos/2026/a.jpg=jpg' ]
}

# ---- libexec/state-backup ------------------------------------------------------------------------

# Sourcing libexec/state-backup sources lib/common.sh again, so the constants are set again after it.
load_libexec() {
  # shellcheck source=libexec/state-backup
  . "$REPO_ROOT/libexec/state-backup"
  SHIPIT_ETC=$BATS_TEST_TMPDIR/etc
  SHIPIT_OWNER_UID=$(id -u)
  BACKUP_ROOT=$BATS_TEST_TMPDIR/backups
  STATE_ROOT=$BATS_TEST_TMPDIR/state
}

@test "state_backup: archives BACKUP_PATHS to a temp file, renames it to <app>-<UTC>.tar.gz" {
  need_gnu
  load_libexec
  fill_state
  BACKUP_KEEP=3 run state_backup st
  [ "$status" -eq 0 ]
  local names
  names=$(ls -A "$dir")
  [[ $names =~ ^st-[0-9]{8}T[0-9]{6}Z\.tar\.gz$ ]]
  [ "$output" = "Wrote $dir/$names ($(wc -c <"$dir/$names" | tr -d ' ') bytes)." ]
  tar -tzf "$dir/$names" | grep -qx 'photos/2026/a.jpg'
  if tar -tzf "$dir/$names" | grep -qx 'glance.db'; then return 1; fi
}

@test "state_backup: keeps the newest BACKUP_KEEP archives, leaving dumps, temp files and others alone" {
  need_gnu
  load_libexec
  fill_state
  for n in st-20261010T030000Z.tar.gz st-20261011T030000Z.tar.gz st-20261009T030000Z.dump .tar-old; do
    : >"$dir/$n"
  done
  BACKUP_KEEP=2 run state_backup st
  [ "$status" -eq 0 ]
  [[ $output == *$'\nDeleted st-20261010T030000Z.tar.gz.' ]]
  [ "$(backup_files st tar.gz | wc -l | tr -d ' ')" = 2 ]
  [ -e "$dir/st-20261011T030000Z.tar.gz" ]
  [ -e "$dir/st-20261009T030000Z.dump" ]
  [ -e "$dir/.tar-old" ]
}

@test "state_backup: a failed archive leaves no file and no temp file, and exits non-zero" {
  load_libexec
  stub setpriv 'exit 1'
  BACKUP_KEEP=3 run state_backup st
  [ "$status" -eq 1 ]
  [ "$output" = "Archiving $state failed, so no backup was written." ]
  [ -z "$(ls -A "$dir")" ]
}

@test "state_backup: refuses a bad app, a bad BACKUP_KEEP, another mode and bad BACKUP_PATHS" {
  load_libexec
  stub setpriv 'touch "'"$BATS_TEST_TMPDIR"'/ran"'
  BACKUP_KEEP=3 run state_backup ../x
  [ "$status" -eq 1 ]
  BACKUP_KEEP=0 run state_backup st
  [ "$status" -eq 1 ]
  write_app_conf db_a REPO=x DATABASE=db_a
  BACKUP_KEEP=3 run state_backup db_a
  [ "$status" -eq 1 ]
  [ "$output" = "db_a doesn't have BACKUP=state in $SHIPIT_ETC/apps/db_a.conf, so there's no state folder to back up." ]
  write_app_conf st REPO=x BACKUP=state BACKUP_PATHS=../etc
  BACKUP_KEEP=3 run state_backup st
  [ "$status" -eq 1 ]
  [[ $output == "Invalid BACKUP_PATHS entry '../etc'"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/ran" ]
}

# ---- shipit backup and restore in state mode -----------------------------------------------------

load_restore() {
  # shellcheck source=lib/restore.sh
  . "$REPO_ROOT/lib/restore.sh"
  # shellcheck disable=SC2329 # called by the functions under test
  as_deployer() { (cd / && env -i HOME="$HOME" PATH="$PATH" "$@"); }
}

@test "shipit backup: BACKUP=state starts the state unit and prints the archive's name and size" {
  load_restore
  stub systemctl 'echo "$*" >>"'"$BATS_TEST_TMPDIR"'/systemctl.calls"
printf 1234 >"'"$dir"'/st-20261013T120000Z.tar.gz"'
  : >"$dir/st-20261014T000000Z.dump"
  run cmd_backup st
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/systemctl.calls")" = 'start shipit-state-backup@st.service' ]
  [ "$output" = "Backed up st to $dir/st-20261013T120000Z.tar.gz (4 bytes)." ]
}

@test "backup_load: the mode and its unit, and refusals for bad BACKUP settings" {
  load_restore
  backup_load st
  [ "$BACKUP" = state ]
  [ "$BACKUP_UNIT" = shipit-state-backup@st.service ]
  [ "$BACKUP_EXT" = tar.gz ]
  [ "$BACKUP_PATHS" = 'backups photos' ]
  mkdir -p "$BACKUP_ROOT/db_a"
  write_app_conf db_a REPO=x DOMAIN=db-a.localhost PORT=3002 DATABASE=db_a
  backup_load db_a
  [ "$BACKUP" = postgres ]
  [ "$BACKUP_UNIT" = shipit-backup@db_a.service ]
  [ "$BACKUP_EXT" = dump ]
  write_app_conf db_a REPO=x DOMAIN=db-a.localhost PORT=3002 DATABASE= BACKUP=postgres
  run backup_load db_a
  [ "$status" -eq 1 ]
  [ "$output" = "$SHIPIT_ETC/apps/db_a.conf sets BACKUP=postgres, but DATABASE is empty. Fix $SHIPIT_ETC/apps/db_a.conf first." ]
  write_app_conf db_a REPO=x DOMAIN=db-a.localhost PORT=3002 BACKUP=files
  run backup_load db_a
  [ "$status" -eq 1 ]
  [[ $output == "Invalid BACKUP 'files'"* ]]
  write_app_conf db_a REPO=x DOMAIN=db-a.localhost PORT=3002 BACKUP=state BACKUP_PATHS=/etc
  run backup_load db_a
  [ "$status" -eq 1 ]
  [[ $output == "Invalid BACKUP_PATHS entry '/etc'"* ]]
}

@test "restore_file: in state mode, archive names only" {
  load_restore
  BACKUP_EXT=tar.gz
  : >"$dir/st-20261011T030000Z.tar.gz"
  : >"$dir/st-20261012T030000Z.tar.gz"
  : >"$dir/st-20261013T030000Z.dump"
  [ "$(restore_file st latest)" = "$dir/st-20261012T030000Z.tar.gz" ]
  [ "$(restore_file st st-20261011T030000Z.tar.gz)" = "$dir/st-20261011T030000Z.tar.gz" ]
  run restore_file st st-20261013T030000Z.dump
  [ "$status" -eq 1 ]
  [ "$output" = "Invalid backup 'st-20261013T030000Z.dump': give latest, or a file name from $dir, like st-20261013T030000Z.tar.gz." ]
}

# state_restore_stubs [extract status] [health code]: systemctl logs its calls, and the state unit
# writes a fresh archive; setpriv logs its arguments and the bytes it gets; curl answers the code.
state_restore_stubs() {
  stub systemctl 'echo "$*" >>"'"$BATS_TEST_TMPDIR"'/systemctl.calls"
[ "$1 $2" != "start shipit-state-backup@st.service" ] || printf now >"'"$dir"'/st-20261013T120000Z.tar.gz"'
  stub setpriv 'echo "$*" >"'"$BATS_TEST_TMPDIR"'/setpriv.args"; cat >"'"$BATS_TEST_TMPDIR"'/extracted"; exit '"${1:-0}"
  stub curl 'printf '"${2:-200}"
  local release=$SHIPIT_OPT/st/releases/20261013T000000Z-abc1234
  mkdir -p "$release"
  printf '%s\n' 'PROCESS_web="node server.js"' 'HEALTH_PATH=/health' >"$release/deploy.conf"
  ln -s "$release" "$SHIPIT_OPT/st/current"
  backup_load st
  printf old-archive >"$dir/st-20261011T030000Z.tar.gz"
}

@test "restore_state_run: fresh backup, stop, extract as the app's user, start, health" {
  load_restore
  state_restore_stubs
  run restore_state_run "$dir/st-20261011T030000Z.tar.gz"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/systemctl.calls")" = $'start shipit-state-backup@st.service\nstop st.target\nstart st.target' ]
  [[ $(cat "$BATS_TEST_TMPDIR/setpriv.args") == "--reuid=st --regid=st --clear-groups -- env -i PATH=/usr/bin:/bin LANG=C.UTF-8 bash -c "*" restore $state backups photos" ]]
  [ "$(cat "$BATS_TEST_TMPDIR/extracted")" = old-archive ]
  [[ $output == *"Backed up st to $dir/st-20261013T120000Z.tar.gz (3 bytes)."* ]]
  [ "$(tail -n 1 <<<"$output")" = "Restored st-20261011T030000Z.tar.gz into $state, and started st again. /health answered 200." ]
}

@test "restore_state_run: a failed extract leaves the app stopped and says how to go on" {
  load_restore
  state_restore_stubs 1
  run restore_state_run "$dir/st-20261011T030000Z.tar.gz"
  [ "$status" -eq 1 ]
  [ "$(cat "$BATS_TEST_TMPDIR/systemctl.calls")" = $'start shipit-state-backup@st.service\nstop st.target' ]
  [[ $output == *$'Restoring st-20261011T030000Z.tar.gz failed partway, so '"$state"$' may be incomplete, and st is left stopped. Put back what was there with sudo shipit restore st st-20261013T120000Z.tar.gz, or start st as it is with sudo systemctl start st.target' ]]
}

@test "restore_state_run: unhealthy after the restore is reported, with the way back" {
  load_restore
  HEALTH_TIMEOUT=0
  state_restore_stubs 0 500
  run restore_state_run "$dir/st-20261011T030000Z.tar.gz"
  [ "$status" -eq 1 ]
  [[ $output == *$'Restored st-20261011T030000Z.tar.gz into '"$state"$' and started st, but /health answered 500. Check: sudo shipit logs st. Put back what was there with: sudo shipit restore st st-20261013T120000Z.tar.gz' ]]
}

@test "shipit restore: BACKUP=none is refused, naming the setting" {
  load_restore
  write_app_conf st REPO=x DOMAIN=st.localhost PORT=3001 BACKUP=none
  run cmd_restore st
  [ "$status" -eq 1 ]
  [ "$output" = "st has no backups, because $SHIPIT_ETC/apps/st.conf sets BACKUP=none." ]
}

# ---- Nothing deploy or rollback removes is in the state folder -----------------------------------

@test "pruning releases and switching back leave the state folder alone" {
  # shellcheck source=lib/deploy.sh
  . "$REPO_ROOT/lib/deploy.sh"
  # The switch uses GNU mv -T. Where mv has no -T (macOS), a stub does the same rename(2).
  if ! mv -T "$(mktemp -d)" "$BATS_TEST_TMPDIR/mvcheck" 2>/dev/null; then
    command -v perl >/dev/null || skip "mv has no -T and perl isn't installed"
    stub mv '[ "$1" = -T ] && shift; exec perl -e '\''rename($ARGV[0], $ARGV[1]) or die "mv: $!\n"'\'' "$@"'
    hash -r
  fi
  APP=st
  fill_state
  before=$(files "$state")
  mkdir -p "$SHIPIT_OPT/st/releases/a" "$SHIPIT_OPT/st/releases/b" "$SHIPIT_OPT/st/releases/c"
  ln -s "$SHIPIT_OPT/st/releases/b" "$SHIPIT_OPT/st/previous"
  RELEASE=$SHIPIT_OPT/st/releases/c
  deploy_prune
  [ ! -e "$SHIPIT_OPT/st/releases/a" ]
  switch_links "$SHIPIT_OPT/st/releases/b"
  [ "$(files "$state")" = "$before" ]
}
