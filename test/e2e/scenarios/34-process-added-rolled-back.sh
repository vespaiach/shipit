#!/usr/bin/env bash
# Process added, then rolled back past: the new instance runs after deploy. After rollback it's stopped
# and not restarted.
set -euo pipefail
# shellcheck source=test/e2e/helpers.sh
. "$(dirname "$0")/../helpers.sh"

[ -e /etc/shipit/apps/node_app.conf ] || fail "run 23-deploy-env-prompts first"
repo=/srv/git/node-app.git
target=/etc/systemd/system/node_app.target
deploy_ok node_app
before=$(readlink /opt/node_app/current)

sha=$(add_line "$repo" deploy.conf 'PROCESS_extra="node worker.js"')
deploy_ok node_app
grep -q "Deployed $sha." <<<"$out" || fail "it didn't deploy $sha"
grep -qx 'Wants=node_app@web.service node_app@worker.service node_app@extra.service' "$target" \
  || fail "the target doesn't want extra"
systemctl is-active --quiet node_app@extra.service || fail "extra isn't running"

out=$(shipit rollback node_app </dev/null 2>&1) || {
  echo "$out"
  fail "the rollback failed"
}
echo "$out"
[ "$(readlink /opt/node_app/current)" = "$before" ] || fail "current isn't the release before extra"
grep -q 'Stopped node_app@extra.service' <<<"$out" || fail "it didn't say it stopped extra"
grep -qx 'Wants=node_app@web.service node_app@worker.service' "$target" || fail "the target still wants extra"
for _ in 1 2 3; do
  sleep 3
  state=$(systemctl show -p ActiveState --value node_app@extra.service)
  [ "$state" = inactive ] || fail "extra is $state after the rollback"
done
systemctl is-active --quiet node_app@web.service || fail "web isn't running"
systemctl is-active --quiet node_app@worker.service || fail "worker isn't running"
echo "process added, then rolled back past OK"
