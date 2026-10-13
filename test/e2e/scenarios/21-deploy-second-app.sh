#!/usr/bin/env bash
# Second app deployed after the first: it gets port 3002. The first app's site file and units are
# unchanged, and its MainPID is the same.
set -euo pipefail
# shellcheck source=test/e2e/helpers.sh
. "$(dirname "$0")/../helpers.sh"

[ -e /etc/shipit/apps/next_app.conf ] || fail "run 20-deploy-zero-config first"
first_files=(/etc/caddy/sites/next_app.caddy /etc/caddy/sites/next_app.extra
  /etc/systemd/system/next_app@.service /etc/systemd/system/next_app.target
  /etc/shipit/apps/next_app.conf /etc/next_app/env)
before=$(sha256sum "${first_files[@]}")
pid=$(systemctl show -p MainPID --value next_app@web.service)
[ "$pid" -gt 0 ] || fail "next_app@web isn't running"

url=$(make_repo second-app test/fixtures/next-app)
sha=$(short_sha second-app)
out=$(printf 'second-app.localhost\n\n' | shipit deploy "$url" 2>&1) || {
  echo "$out"
  fail "the second app's deploy failed"
}
echo "$out"
[ "$(tail -n 1 <<<"$out")" = "Deployed $sha. https://second-app.localhost" ] || fail "it didn't end with Deployed $sha"
grep -qx PORT=3002 /etc/shipit/apps/second_app.conf || fail "the second app didn't get port 3002"
grep -qx 'Environment=NODE_ENV=production PORT=3002' /etc/systemd/system/second_app@.service \
  || fail "the second app's unit doesn't set PORT=3002"

[ "$(sha256sum "${first_files[@]}")" = "$before" ] || fail "the first app's files changed"
[ "$(systemctl show -p MainPID --value next_app@web.service)" = "$pid" ] || fail "the first app was restarted"
served next-app.localhost | grep -q 'Hello from shipit' || fail "the first app isn't served any more"
served second-app.localhost | grep -q 'Hello from shipit' || fail "the second app isn't served"
runuser -u second_app -- ls /opt/next_app 2>/dev/null && fail "second_app can read /opt/next_app"
echo "second app OK"
