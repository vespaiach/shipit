#!/usr/bin/env bash
# Rollback: finishes in under 2 minutes and serves the previous sha (OPS-004.1). A second rollback
# refuses.
set -euo pipefail
# shellcheck source=test/e2e/helpers.sh
. "$(dirname "$0")/../helpers.sh"

[ -e /etc/shipit/apps/node_app.conf ] || fail "run 23-deploy-env-prompts first"
repo=/srv/git/node-app.git
old=$(readlink /opt/node_app/current)
old_sha=${old##*-}
served node-app.localhost | grep -q 'Hello from node-app (built):' || fail "node_app isn't serving the first build"

# A release whose build writes something else, so the page tells the releases apart.
sha=$(add_line "$repo" build.js 'fs.writeFileSync("dist/built.txt", "built v2\n");')
deploy_ok node_app
grep -q "Deployed $sha." <<<"$out" || fail "it didn't deploy $sha"
served node-app.localhost | grep -q 'Hello from node-app (built v2):' || fail "the new release isn't served"
[ "$(readlink /opt/node_app/previous)" = "$old" ] || fail "previous isn't the old release"

start=$SECONDS
out=$(shipit rollback node_app </dev/null 2>&1) || {
  echo "$out"
  fail "the rollback failed"
}
echo "$out"
[ $((SECONDS - start)) -lt 120 ] || fail "the rollback took $((SECONDS - start)) seconds"
[ "$(tail -n 1 <<<"$out")" = "Rolled back to ${old##*/}; the database keeps $sha's migrations." ] \
  || fail "it didn't end with the rolled-back message"
[ "$(readlink /opt/node_app/current)" = "$old" ] || fail "current isn't the old release"
[ ! -e /opt/node_app/previous ] || fail "previous is still there"
served node-app.localhost | grep -q 'Hello from node-app (built):' || fail "the old release isn't served"
tail -n 1 /var/log/shipit/node_app/deploy.log | grep -Eq "^[0-9TZ:-]+ node_app $old_sha root rolled-back$" \
  || fail "deploy.log line"

out=$(shipit rollback node_app </dev/null 2>&1) && fail "a second rollback didn't refuse"
[ "$out" = "No previous release to roll back to." ] || fail "the second rollback said: $out"
[ "$(readlink /opt/node_app/current)" = "$old" ] || fail "the refused rollback changed current"
echo "rollback OK"
