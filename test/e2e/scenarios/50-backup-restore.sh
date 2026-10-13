#!/usr/bin/env bash
# Backup and restore (S7). deploy gave db_a (24-deploy-database-isolation) its backup folder and an
# enabled timer. A backup file appears with the right name, restore brings back the matching row counts
# (after a fresh backup, with the app stopped and started again), only BACKUP_KEEP files are kept, and a
# failed backup leaves no file and shows in status.
set -euo pipefail
# shellcheck source=test/e2e/helpers.sh
. "$(dirname "$0")/../helpers.sh"

[ -e /etc/shipit/apps/db_a.conf ] || fail "run 24-deploy-database-isolation first"
dir=/var/backups/shipit/db_a
host_conf=/etc/shipit/host.conf
dropin=/run/systemd/system/shipit-backup@db_a.service.d

rows() {
  (cd / && runuser -u postgres -- psql -X -q -t -A -d db_a -c 'SELECT count(*) FROM greetings' </dev/null)
}
insert() {
  (cd / && runuser -u postgres -- psql -X -q -d db_a -c "INSERT INTO greetings (id, text) SELECT g, 'row ' || g FROM generate_series($1, $2) g" </dev/null)
}
dumps() {
  find "$dir" -maxdepth 1 -name 'db_a-*.dump' -printf '%f\n' | sort
}
# backup_ok: shipit backup db_a, leaving the dump's name in $name.
backup_ok() {
  out=$(shipit backup db_a 2>&1) || {
    echo "$out"
    fail "shipit backup db_a failed"
  }
  echo "$out"
  [[ $out =~ ^Backed\ up\ db_a\ to\ $dir/(db_a-[0-9]{8}T[0-9]{6}Z\.dump)\ \(([0-9]+)\ bytes\)\.$ ]] \
    || fail "the backup output: $out"
  name=${BASH_REMATCH[1]}
  [ "$(stat -c %s "$dir/$name")" = "${BASH_REMATCH[2]}" ] || fail "the size printed isn't $name's"
}
# restore_ok <file | latest>: restore, confirmed by typing the app name in a terminal.
restore_ok() {
  out=$(printf 'db_a\n' | in_terminal "shipit restore db_a $1" 2>&1) || {
    echo "$out"
    fail "shipit restore db_a $1 failed"
  }
  echo "$out"
}

# ---- What deploy set up --------------------------------------------------------------------------
[ "$(stat -c '%U %G %a' "$dir")" = 'postgres postgres 700' ] || fail "$dir perms"
[ "$(systemctl is-enabled shipit-backup@db_a.timer)" = enabled ] || fail "db_a's backup timer isn't enabled"
systemctl is-active --quiet shipit-backup@db_a.timer || fail "db_a's backup timer isn't active"
[ "$(systemctl is-enabled shipit-backup@node_app.timer 2>/dev/null)" != enabled ] \
  || fail "node_app has no database but its backup timer is enabled"
before=$(etc_checksums)
deploy_ok db_a
[ "$(etc_checksums)" = "$before" ] || fail "a redeploy changed /etc"
grep -q 'Enabled shipit-backup' <<<"$out" && fail "a redeploy enabled the timer again"

# ---- A backup file appears with the right name ---------------------------------------------------
rm -f "$dir"/db_a-*.dump
insert 2 10
[ "$(rows)" = 10 ] || fail "db_a should have 10 rows"
backup_ok
first=$name
[ "$(dumps)" = "$first" ] || fail "the backup folder holds: $(dumps)"
[ "$(stat -c '%U %a' "$dir/$first")" = 'postgres 600' ] || fail "$first perms"
[ -z "$(find "$dir" -name '.dump-*')" ] || fail "a temp file was left behind"
out=$(shipit status db_a 2>&1)
grep -qx "  backup     $first (last run: success)" <<<"$out" || fail "status doesn't show $first: $out"

# ---- Restore brings back the matching row counts -------------------------------------------------
sleep 1
insert 11 25
[ "$(rows)" = 25 ] || fail "db_a should have 25 rows"

# Refusals first: no terminal, the wrong name typed, and a path instead of a dump name.
out=$(shipit restore db_a "$first" </dev/null 2>&1) && fail "restore ran without a terminal"
grep -q "there's no terminal to ask in" <<<"$out" || fail "the no-terminal message: $out"
out=$(printf 'db_b\n' | in_terminal "shipit restore db_a $first" 2>&1) && fail "restore accepted the wrong name"
grep -q "That isn't db_a, so nothing was restored." <<<"$out" || fail "the wrong-name message: $out"
out=$(printf 'db_a\n' | in_terminal "shipit restore db_a ../db_b/$first" 2>&1) && fail "restore accepted a path"
grep -q "Invalid backup '../db_b/$first'" <<<"$out" || fail "the path message: $out"
[ "$(rows)" = 25 ] || fail "a refused restore changed db_a"
[ "$(dumps)" = "$first" ] || fail "a refused restore took a backup"

web_pid=$(systemctl show -p MainPID --value db_a@web.service)
restore_ok "$first"
grep -q "Restored $first into db_a, and started db_a again." <<<"$out" || fail "restore didn't report success"
[ "$(rows)" = 10 ] || fail "after restoring $first, db_a has $(rows) rows, not 10"
[ "$(dumps | wc -l)" = 2 ] || fail "restore didn't take a fresh backup first"
fresh=$(dumps | tail -n 1)
[ "$fresh" != "$first" ] || fail "the fresh backup has the same name"
grep -q "Backed up db_a to $dir/$fresh" <<<"$out" || fail "restore didn't say where the fresh backup is"
[ "$(systemctl show -p MainPID --value db_a@web.service)" != "$web_pid" ] || fail "db_a wasn't stopped and started"
systemctl is-active --quiet db_a.target || fail "db_a.target isn't active after the restore"
[ "$(cd / && runuser -u postgres -- psql -X -t -A -d db_a -c "SELECT tableowner FROM pg_tables WHERE tablename = 'greetings'")" = db_a ] \
  || fail "the restored table isn't owned by db_a"
url=$(sed -n 's/^DATABASE_URL=//p' /etc/db_a/env)
[ "$(cd / && runuser -u db_a -- psql -X -w -q -t -A "$url" -c 'SELECT count(*) FROM greetings' </dev/null)" = 10 ] \
  || fail "db_a can't read its restored table"

# latest is the fresh backup taken before that restore: it brings the 25 rows back.
restore_ok latest
grep -q "Restored $fresh into db_a" <<<"$out" || fail "latest wasn't $fresh"
[ "$(rows)" = 25 ] || fail "after restoring latest, db_a has $(rows) rows, not 25"

# ---- Only BACKUP_KEEP files are kept -------------------------------------------------------------
cp -p "$host_conf" /root/host.conf.e2e
sed -i 's/^BACKUP_KEEP=.*/BACKUP_KEEP=2/' "$host_conf"
for _ in 1 2 3; do
  sleep 1
  backup_ok
done
[ "$(dumps | wc -l)" = 2 ] || fail "BACKUP_KEEP=2 kept: $(dumps)"
[ "$(dumps | tail -n 1)" = "$name" ] || fail "the newest dump was pruned"
dumps | grep -qx "$first" && fail "the oldest dump wasn't pruned"
cp -p /root/host.conf.e2e "$host_conf"
rm -f /root/host.conf.e2e

# ---- A failed backup leaves no file and shows in status ------------------------------------------
kept=$(dumps)
mkdir -p "$dropin"
printf '[Service]\nEnvironment=PGHOST=/nonexistent\n' >"$dropin/e2e-break.conf"
systemctl daemon-reload
out=$(shipit backup db_a 2>&1) && fail "a failing backup succeeded"
grep -q 'The backup of db_a failed. Check: journalctl -u shipit-backup@db_a.service' <<<"$out" \
  || fail "the failed backup message: $out"
[ "$(dumps)" = "$kept" ] || fail "a failed backup changed the dumps"
[ -z "$(find "$dir" -name '.dump-*')" ] || fail "a failed backup left a temp file"
out=$(shipit status db_a 2>&1)
grep -qx "  backup     $(dumps | tail -n 1) (last run: failed (exit-code))" <<<"$out" \
  || fail "status doesn't show the failed run: $out"
rm -rf "$dropin"
systemctl daemon-reload
backup_ok
echo "backup and restore OK"
