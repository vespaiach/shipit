#!/usr/bin/env bash
# Health answers 308 with HEALTH_PATH set: counted as unhealthy. With HEALTH_FAIL=report the deploy
# says how to switch back; with HEALTH_FAIL=rollback it switches back by itself. The node-app fixture's
# /health answers 308 when the repo has a file named HEALTH_308.
set -euo pipefail
# shellcheck source=test/e2e/helpers.sh
. "$(dirname "$0")/../helpers.sh"

[ -e /etc/shipit/apps/node_app.conf ] || fail "run 23-deploy-env-prompts first"
repo=/srv/git/node-app.git
conf=/etc/shipit/apps/node_app.conf
log=/var/log/shipit/node_app/deploy.log
deploy_ok node_app
good=$(readlink /opt/node_app/current)
sha=$(add_line "$repo" HEALTH_308 yes)

# HEALTH_FAIL=report (the default): exit 1, the new release stays, and it says how to switch back.
grep -qx HEALTH_FAIL=report "$conf" || fail "node_app isn't on HEALTH_FAIL=report"
out=$(shipit deploy node_app </dev/null 2>&1) && fail "a 308 from /health counted as healthy"
echo "$out"
grep -q "Deployed $sha, but /health answered 308. Switch back with: sudo shipit rollback node_app" <<<"$out" \
  || fail "the report message"
[[ $(readlink /opt/node_app/current) == *-"$sha" ]] || fail "report switched back"
tail -n 1 "$log" | grep -q " node_app $sha root unhealthy$" || fail "deploy.log line for report"
shipit rollback node_app </dev/null || fail "the rollback by hand failed"
[ "$(readlink /opt/node_app/current)" = "$good" ] || fail "the rollback by hand didn't go back"

# HEALTH_FAIL=rollback: the same deploy switches back by itself and exits 1.
sed -i 's/^HEALTH_FAIL=.*/HEALTH_FAIL=rollback/' "$conf"
out=$(shipit deploy node_app </dev/null 2>&1) && fail "the unhealthy deploy exited 0"
echo "$out"
grep -q "Deployed $sha, but /health answered 308. Rolling back" <<<"$out" || fail "it didn't say it's rolling back"
[ "$(tail -n 1 <<<"$out")" = "Rolled back to ${good##*/}; the database keeps $sha's migrations." ] \
  || fail "it didn't end with the rolled-back message"
[ "$(readlink /opt/node_app/current)" = "$good" ] || fail "current isn't the good release"
[ ! -e /opt/node_app/previous ] || fail "previous is still there"
served node-app.localhost | grep -q 'Hello from node-app' || fail "node_app isn't served"
[ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: node-app.localhost' "http://127.0.0.1:$(sed -n 's/^PORT=//p' "$conf")/health")" = 200 ] \
  || fail "the good release's /health doesn't answer 200"
tail -n 1 "$log" | grep -q " node_app $sha root rolled-back$" || fail "deploy.log line for rollback"

# Back to a healthy tip, and the default HEALTH_FAIL.
sed -i 's/^HEALTH_FAIL=.*/HEALTH_FAIL=report/' "$conf"
sha=$(remove_file "$repo" HEALTH_308)
deploy_ok node_app
grep -q "Deployed $sha." <<<"$out" || fail "it didn't deploy $sha"
echo "308 health and HEALTH_FAIL OK"
