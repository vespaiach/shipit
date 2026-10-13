#!/usr/bin/env bash
# status, logs and env (S6). status shows both fixture apps (releases, each process, health, deploy.log,
# backups, caddy validate), including a failed instance. logs follows the chosen files and refuses an
# unknown one. env refuses a bad edit, offers to edit again, installs a good one and restarts the app.
set -euo pipefail
# shellcheck source=test/e2e/helpers.sh
. "$(dirname "$0")/../helpers.sh"

for app in next_app node_app; do
  [ -e "/etc/shipit/apps/$app.conf" ] || fail "run the deploy scenarios first ($app is missing)"
done
env=/etc/node_app/env

# block <app>: the indented lines under the app's name in $out.
block() {
  awk -v a="$1" '$0 == a { on = 1; next } /^[^ ]/ { on = 0 } on && /^ /' <<<"$out"
}

# ---- status: every app ---------------------------------------------------------------------------
out=$(shipit status 2>&1) || {
  echo "$out"
  fail "shipit status failed"
}
echo "$out"
cur=$(readlink /opt/node_app/current)
block node_app | grep -qx "  current    ${cur##*-} (.* UTC)" || fail "node_app's current release"
block node_app | grep -qx '  web        active' || fail "node_app's web isn't shown active"
block node_app | grep -qx '  worker     active' || fail "node_app's worker isn't shown active"
block node_app | grep -qx '  health     /health answered 200 (healthy)' || fail "node_app's health"
block node_app | grep -qxF "  deploy.log $(tail -n 1 /var/log/shipit/node_app/deploy.log)" || fail "node_app's deploy.log line"
block node_app | grep -qx '  backup     none: node_app has no database' || fail "node_app's backup line"
cur=$(readlink /opt/next_app/current)
block next_app | grep -qx "  current    ${cur##*-} (.* UTC)" || fail "next_app's current release"
block next_app | grep -qx '  web        active' || fail "next_app's web isn't shown active"
block next_app | grep -Eqx '  health     / answered [1-4][0-9][0-9] \(healthy\)' || fail "next_app's health"
if [ -e /etc/shipit/apps/db_a.conf ]; then
  block db_a | grep -qx '  backup     none yet (last run: never run)' || fail "db_a's backup line"
fi
[ "$(grep -c '^Caddy: /etc/caddy/Caddyfile is valid.$' <<<"$out")" = 1 ] || fail "caddy validate wasn't reported once"
grep -q '^Backups are in /var/backups/shipit/<app>/' <<<"$out" || fail "status doesn't say where backups are"

# ---- status: a failed instance -------------------------------------------------------------------
# A runtime drop-in makes the worker exit 1 without restarting, so it ends up failed.
dropin=/run/systemd/system/node_app@worker.service.d
mkdir -p "$dropin"
printf '[Service]\nRestart=no\nExecStart=\nExecStart=/bin/false\n' >"$dropin/e2e-break.conf"
systemctl daemon-reload
systemctl restart node_app@worker.service || true
for _ in $(seq 20); do
  [ "$(systemctl is-active node_app@worker.service)" = failed ] && break
  sleep 0.5
done
out=$(shipit status node_app 2>&1) || {
  echo "$out"
  fail "shipit status node_app failed"
}
echo "$out"
block node_app | grep -qx '  worker     FAILED. See: sudo shipit logs node_app worker, or systemctl status node_app@worker' \
  || fail "the failed worker isn't shown as FAILED"
block node_app | grep -qx '  web        active' || fail "web isn't active next to the failed worker"
grep -q '^next_app$' <<<"$out" && fail "status node_app showed other apps"
rm -rf "$dropin"
systemctl daemon-reload

# ---- logs ----------------------------------------------------------------------------------------
# follow <args>: shipit logs for 3 seconds (tail -F never ends by itself); leaves the output in $out.
follow() {
  local status=0
  out=$(timeout 3 shipit logs "$@" 2>&1) || status=$?
  [ "$status" = 124 ] || {
    echo "$out"
    fail "shipit logs $* exited $status before the timeout"
  }
}
follow node_app worker
grep -q '^==> /var/log/shipit/node_app/worker.log <==$' <<<"$out" || fail "logs node_app worker doesn't follow worker.log"
grep -q '^==> /var/log/shipit/node_app/worker.error.log <==$' <<<"$out" || fail "logs node_app worker doesn't follow worker.error.log"
grep -q 'worker' <<<"$out" || fail "worker.log has no worker lines"
grep -q 'web.log' <<<"$out" && fail "logs node_app worker followed web.log"
follow next_app deploy
grep -q ' next_app [0-9a-f]\{7\} root deployed$' <<<"$out" || fail "logs next_app deploy doesn't show deploy.log"
follow next_app
for f in access deploy web web.error; do
  grep -q "^==> /var/log/shipit/next_app/$f.log <==\$" <<<"$out" || fail "logs next_app doesn't follow $f.log"
done
out=$(shipit logs node_app nope 2>&1) && fail "logs accepted an unknown target"
grep -q "^There's no nope log in /var/log/shipit/node_app. Choose one of: access deploy .*worker" <<<"$out" \
  || fail "the unknown-target message: $out"
out=$(shipit logs node_app ../../../etc/shadow 2>&1) && fail "logs accepted a path"
grep -q '^Invalid process name' <<<"$out" || fail "the bad-target message: $out"

# ---- env -----------------------------------------------------------------------------------------
before=$(sha256sum "$env")
web_pid=$(systemctl show -p MainPID --value node_app@web.service)

# Nothing changed: nothing is written or restarted.
out=$(EDITOR=true shipit env node_app </dev/null 2>&1) || {
  echo "$out"
  fail "an unchanged env edit failed"
}
[ "$out" = "No changes, so $env and node_app are as they were." ] || fail "unchanged edit said: $out"
[ "$(systemctl show -p MainPID --value node_app@web.service)" = "$web_pid" ] || fail "an unchanged edit restarted web"

# A bad line, then no to editing again (the "Edit it again?" prompt itself only shows in a terminal): refused, naming the line, and the file is untouched.
editor=$(mktemp)
# shellcheck disable=SC2016 # the editor script's own $1
printf '#!/bin/sh\necho "BAD LINE" >>"$1"\n' >"$editor"
chmod 755 "$editor"
out=$(printf 'n\n' | EDITOR=$editor shipit env node_app 2>&1) && fail "a bad env edit was accepted"
echo "$out"
grep -q "^$env line [0-9]* isn't KEY=value.$" <<<"$out" || fail "the bad line wasn't named"
grep -q "^$env wasn't changed.$" <<<"$out" || fail "it didn't say $env wasn't changed"
[ "$(sha256sum "$env")" = "$before" ] || fail "a refused edit changed $env"

# While a deploy or rollback holds the app lock, env refuses.
flock /var/lib/shipit/node_app.lock sleep 10 &
holder=$!
sleep 1
out=$(EDITOR=true shipit env node_app </dev/null 2>&1) && fail "env ran while the app lock was held"
[ "$out" = "Another deploy or rollback of node_app is running." ] || fail "the lock message: $out"
kill "$holder"
wait "$holder" 2>/dev/null || true

# A bad line, yes to editing again, then a good edit: installed, and the app restarted (which also
# brings the failed worker back).
# shellcheck disable=SC2016 # the editor script's own $1
printf '#!/bin/sh\nif grep -q "^BAD LINE" "$1"; then sed -i -e "/^BAD LINE/d" -e "s/^GREETING=.*/GREETING=edited by env/" "$1"; else echo "BAD LINE" >>"$1"; fi\n' >"$editor"
out=$(printf 'y\n' | EDITOR=$editor shipit env node_app 2>&1) || {
  echo "$out"
  fail "the re-edited env failed"
}
echo "$out"
rm -f "$editor"
grep -q "^Wrote $env.$" <<<"$out" || fail "it didn't write $env"
grep -qx 'GREETING=edited by env' "$env" || fail "$env has no edited GREETING"
grep -q '^BAD LINE' "$env" && fail "$env kept the bad line"
[ "$(stat -c '%U %G %a' "$env")" = 'root root 600' ] || fail "$env perms"
[ "$(systemctl show -p MainPID --value node_app@web.service)" != "$web_pid" ] || fail "web wasn't restarted"
for _ in $(seq 30); do
  served node-app.localhost 2>/dev/null | grep -q 'edited by env' && break
  sleep 1
done
served node-app.localhost | grep -q 'edited by env' || fail "the app doesn't serve the new GREETING"

out=$(shipit status node_app 2>&1)
echo "$out"
block node_app | grep -qx '  worker     active' || fail "the worker isn't active after the env restart"
echo "status, logs and env OK"
