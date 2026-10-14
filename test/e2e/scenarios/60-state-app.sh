#!/usr/bin/env bash
# A stateful app without PostgreSQL. The state-app fixture keeps notes in DATA_DIR=/var/lib/state_app
# (its state folder, StateDirectory=). Its state survives a redeploy and a rollback; BACKUP=state with
# BACKUP_PATHS=notes backs up and restores only the notes, as the app's user; a symlink out of the
# folder stops the backup; another app's user can't read the folder or the backups, and the app's own
# user can't reach its backups; BACKUP=none refuses backup and restore by name; and an app named like a
# folder that's already in /var/lib is refused.
set -euo pipefail
# shellcheck source=test/e2e/helpers.sh
. "$(dirname "$0")/../helpers.sh"

[ -e /etc/shipit/apps/db_a.conf ] || fail "run 24-deploy-database-isolation first"
conf=/etc/shipit/apps/state_app.conf
state=/var/lib/state_app
dir=/var/backups/shipit/state_app
repo=/srv/git/state-app.git

health() {
  curl -fsS --max-time 5 -H 'Host: state-app.localhost' "http://127.0.0.1:$port/health"
}
note() {
  curl -fsS --max-time 5 -X POST -H 'Host: state-app.localhost' "http://127.0.0.1:$port/notes?text=$1" >/dev/null
}
# notes_are <list>: what /health reports.
notes_are() {
  local got
  got=$(health) || fail "/health didn't answer"
  [ "$got" = "notes: $1" ] || fail "expected notes: $1, got: $got"
}
archives() {
  find "$dir" -maxdepth 1 -name 'state_app-*.tar.gz' -printf '%f\n' | sort
}
# backup_ok: shipit backup state_app, leaving the archive's name in $name.
backup_ok() {
  out=$(shipit backup state_app 2>&1) || {
    echo "$out"
    fail "shipit backup state_app failed"
  }
  echo "$out"
  [[ $out =~ ^Backed\ up\ state_app\ to\ $dir/(state_app-[0-9]{8}T[0-9]{6}Z\.tar\.gz)\ \([0-9]+\ bytes\)\.$ ]] \
    || fail "the backup output: $out"
  name=${BASH_REMATCH[1]}
}
# restore_ok <file | latest>: restore, confirmed by typing the app name in a terminal.
restore_ok() {
  out=$(printf 'state_app\n' | in_terminal "shipit restore state_app $1" 2>&1) || {
    echo "$out"
    fail "shipit restore state_app $1 failed"
  }
  echo "$out"
}

# ---- First deploy: the state folder --------------------------------------------------------------
url=$(make_repo state-app test/fixtures/state-app)
sha=$(short_sha state-app)
# The domain, no database, then DATA_DIR from .env.example.
out=$(printf 'state-app.localhost\nn\n%s\n' "$state" | in_terminal "shipit deploy $url" 2>&1) || {
  echo "$out"
  fail "the first deploy of state_app failed"
}
echo "$out"
grep -q "Deployed $sha. https://state-app.localhost" <<<"$out" || fail "state_app didn't end with Deployed $sha"
port=$(sed -n 's/^PORT=//p' "$conf")
grep -qx 'StateDirectory=state_app' /etc/systemd/system/state_app@.service || fail "the unit has no StateDirectory="
[ "$(stat -c '%U %G %a' "$state")" = 'state_app state_app 750' ] || fail "$state perms: $(stat -c '%U %G %a' "$state")"
[ "$(systemctl is-enabled shipit-state-backup@state_app.timer 2>/dev/null)" != enabled ] \
  || fail "the state backup timer is enabled without BACKUP=state"
note one
notes_are one

# ---- State survives a redeploy and a rollback ----------------------------------------------------
sha2=$(add_line "$repo" server.js '// v2')
deploy_ok state_app
grep -q "Deployed $sha2." <<<"$out" || fail "it didn't deploy $sha2"
notes_are one
note two
out=$(shipit rollback state_app </dev/null 2>&1) || {
  echo "$out"
  fail "the rollback of state_app failed"
}
echo "$out"
[ "$(readlink /opt/state_app/current)" = "$(find /opt/state_app/releases -maxdepth 1 -name "*-$sha")" ] \
  || fail "the rollback didn't switch to $sha"
notes_are one,two
deploy_ok state_app
notes_are one,two

# ---- BACKUP=state with BACKUP_PATHS --------------------------------------------------------------
printf 'BACKUP=state\nBACKUP_PATHS=notes\n' >>"$conf"
deploy_ok state_app
grep -q 'Enabled shipit-state-backup@state_app.timer' <<<"$out" || fail "the state backup timer wasn't enabled"
[ "$(systemctl is-enabled shipit-state-backup@state_app.timer)" = enabled ] || fail "the timer isn't enabled"
[ "$(systemctl is-enabled shipit-backup@state_app.timer 2>/dev/null)" != enabled ] \
  || fail "the postgres backup timer is enabled for a state app"
[ "$(stat -c '%U %G %a' "$dir")" = 'root root 700' ] || fail "$dir perms: $(stat -c '%U %G %a' "$dir")"
before=$(etc_checksums)
deploy_ok state_app
[ "$(etc_checksums)" = "$before" ] || fail "a redeploy with BACKUP=state changed /etc"

backup_ok
first=$name
[ "$(archives)" = "$first" ] || fail "the backup folder holds: $(archives)"
[ "$(stat -c '%U %a' "$dir/$first")" = 'root 600' ] || fail "$first perms"
[ -z "$(find "$dir" -name '.tar-*')" ] || fail "a temp file was left behind"
list=$(tar -tzf "$dir/$first")
grep -q '^notes/.' <<<"$list" || fail "$first has no notes"
grep -q 'live.txt' <<<"$list" && fail "$first has live.txt, which BACKUP_PATHS doesn't list"
out=$(shipit status state_app 2>&1)
grep -qx "  backup     $first (last run: success)" <<<"$out" || fail "status doesn't show $first: $out"

# ---- Restore puts back the notes only, as the app's user -----------------------------------------
sleep 1
note three
notes_are one,two,three
runuser -u state_app -- bash -c "echo kept >$state/keep.txt"
out=$(shipit restore state_app "$first" </dev/null 2>&1) && fail "restore ran without a terminal"
grep -q "there's no terminal to ask in" <<<"$out" || fail "the no-terminal message: $out"

restore_ok "$first"
grep -q "This replaces notes in $state with $first" <<<"$out" || fail "restore didn't say what it replaces"
grep -q "Restored $first into $state, and started state_app again. /health answered 200." <<<"$out" \
  || fail "restore didn't report success"
notes_are one,two
[ "$(cat "$state/keep.txt")" = kept ] || fail "restore touched a file BACKUP_PATHS doesn't list"
[ -z "$(find "$state" ! -user state_app)" ] || fail "restore left files not owned by state_app: $(find "$state" ! -user state_app)"
[ "$(archives | wc -l)" = 2 ] || fail "restore didn't take a fresh backup first"
restore_ok latest
notes_are one,two,three

# ---- A symlink out of the folder stops the backup ------------------------------------------------
kept=$(archives)
runuser -u state_app -- bash -c "mv $state/notes $state/notes.real && ln -s /etc/shipit $state/notes"
out=$(shipit backup state_app 2>&1) && fail "a backup followed a symlink out of the folder"
grep -q 'The backup of state_app failed' <<<"$out" || fail "the failed backup message: $out"
journal=$(journalctl -u shipit-state-backup@state_app.service -n 20 --no-pager)
grep -q 'notes leads outside' <<<"$journal" || fail "the journal doesn't say why"
[ "$(archives)" = "$kept" ] || fail "a failed backup changed the archives"
[ -z "$(find "$dir" -name '.tar-*')" ] || fail "a failed backup left a temp file"
grep -q 'last run: failed' <<<"$(shipit status state_app 2>&1)" || fail "status doesn't show the failed run"
runuser -u state_app -- bash -c "rm $state/notes && mv $state/notes.real $state/notes"
backup_ok

# ---- Isolation -----------------------------------------------------------------------------------
runuser -u db_a -- ls "$state" >/dev/null 2>&1 && fail "db_a can list $state"
runuser -u db_a -- cat "$state/keep.txt" >/dev/null 2>&1 && fail "db_a can read $state/keep.txt"
runuser -u db_a -- ls "$dir" >/dev/null 2>&1 && fail "db_a can list $dir"
runuser -u db_a -- cat "$dir/$name" >/dev/null 2>&1 && fail "db_a can read state_app's backups"
runuser -u deployer -- ls "$state" >/dev/null 2>&1 && fail "deployer can list $state"
runuser -u state_app -- ls /var/backups/shipit >/dev/null 2>&1 && fail "state_app can list /var/backups/shipit"
runuser -u state_app -- ls "$dir" >/dev/null 2>&1 && fail "state_app can list its own backups"
runuser -u state_app -- rm -f "$dir/$name" 2>/dev/null || true
[ -e "$dir/$name" ] || fail "state_app deleted its own backup"
runuser -u state_app -- ls /var/backups/shipit/db_a >/dev/null 2>&1 && fail "state_app can list db_a's dumps"
runuser -u state_app -- ls /var/lib/db_a >/dev/null 2>&1 && fail "state_app can list /var/lib/db_a"

# ---- BACKUP=none ---------------------------------------------------------------------------------
sed -i 's/^BACKUP=state$/BACKUP=none/' "$conf"
deploy_ok state_app
grep -q 'Disabled shipit-state-backup@state_app.timer, because state_app has BACKUP=none now.' <<<"$out" \
  || fail "the state backup timer wasn't disabled"
out=$(shipit backup state_app 2>&1) && fail "a backup ran with BACKUP=none"
[ "$out" = "state_app has no backups, because $conf sets BACKUP=none." ] || fail "the BACKUP=none message: $out"
out=$(printf 'state_app\n' | in_terminal "shipit restore state_app" 2>&1) && fail "a restore ran with BACKUP=none"
grep -q "state_app has no backups, because $conf sets BACKUP=none." <<<"$out" || fail "the restore message: $out"
grep -qx '  backup     none (BACKUP=none: state_app has no backups)' <<<"$(shipit status state_app 2>&1)" \
  || fail "status doesn't say BACKUP=none"
[ -n "$(archives)" ] || fail "BACKUP=none deleted the archives"
notes_are one,two,three

# ---- An app named like a folder already in /var/lib is refused -----------------------------------
install -d -m 755 /var/lib/squat
url=$(make_repo squat test/fixtures/state-app)
out=$(in_terminal "shipit deploy $url" </dev/null 2>&1) && fail "an app named squat was deployed"
grep -q "/var/lib/squat already exists and isn't the squat app's own folder" <<<"$out" \
  || fail "the squat refusal: $out"
[ ! -e /etc/shipit/apps/squat.conf ] || fail "squat got a config"
[ "$(stat -c '%U' /var/lib/squat)" = root ] || fail "/var/lib/squat changed owner"
rm -rf /var/lib/squat "/srv/git/squat.git"
echo "state app OK"
