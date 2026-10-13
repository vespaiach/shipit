#!/usr/bin/env bash
# Zero-config Next app, first deploy: one domain answer is enough. It ends `Deployed <sha>`, `current`
# is that sha, / is served through Caddy, and web.log has lines in it.
set -euo pipefail
# shellcheck source=test/e2e/helpers.sh
. "$(dirname "$0")/../helpers.sh"

[ -e /etc/shipit/host.conf ] || fail "run the setup scenarios first"
url=$(make_repo next-app test/fixtures/next-app)
sha=$(short_sha next-app)

out=$(printf 'next-app.localhost\n' | shipit deploy "$url" 2>&1) || {
  echo "$out"
  fail "the first deploy failed"
}
echo "$out"
[ "$(tail -n 1 <<<"$out")" = "Deployed $sha. https://next-app.localhost" ] || fail "it didn't end with Deployed $sha"

conf=/etc/shipit/apps/next_app.conf
[ "$(stat -c '%U %a' "$conf")" = 'root 644' ] || fail "$conf perms"
for line in "REPO=$url" BRANCH=main DOMAIN=next-app.localhost PORT=3001 HEALTH_FAIL=report; do
  grep -qxF "$line" "$conf" || fail "$conf has no $line"
done
[ "$(stat -c '%U %G %a' /etc/next_app/env)" = 'root root 600' ] || fail "env file perms"
grep -qx 'APP_URL=https://next-app.localhost' /etc/next_app/env || fail "env file has no APP_URL"
grep -q DATABASE_URL /etc/next_app/env && fail "env file has a DATABASE_URL without a database"

[ "$(getent passwd next_app | cut -d: -f5,7)" = 'shipit app:/usr/sbin/nologin' ] || fail "the next_app user"
[ "$(stat -c '%U %G %a' /opt/next_app)" = 'deployer next_app 750' ] || fail "/opt/next_app perms"
[ "$(stat -c '%U' /opt/next_app/releases)" = deployer ] || fail "releases/ isn't deployer's"
current=$(readlink /opt/next_app/current)
[[ $current == /opt/next_app/releases/*-"$sha" ]] || fail "current is $current, not $sha"
[ ! -e /opt/next_app/previous ] || fail "a first deploy has no previous release"
[ "$(stat -c '%U' "$current/.next")" = deployer ] || fail "the build isn't deployer's"

systemctl is-enabled --quiet next_app.target || fail "next_app.target isn't enabled"
systemctl is-active --quiet next_app@web.service || fail "next_app@web isn't running"
[ "$(systemctl show -p User --value next_app@web.service)" = next_app ] || fail "web doesn't run as next_app"
head -n 1 /etc/caddy/sites/next_app.caddy | grep -q '^# managed by shipit' || fail "site file"
[ -e /etc/caddy/sites/next_app.extra ] || fail "no .extra file"

served next-app.localhost | grep -q 'Hello from shipit' || fail "/ isn't served through Caddy"
logs=/var/log/shipit/next_app
[ -s "$logs/web.log" ] || fail "web.log is empty"
[ "$(stat -c '%U %G %a' "$logs/access.log")" = 'caddy adm 640' ] || fail "access.log perms"
sleep 1
[ -s "$logs/access.log" ] || fail "Caddy didn't write access.log"
tail -n 1 "$logs/deploy.log" | grep -Eq "^[0-9TZ:-]+ next_app $sha root deployed$" || fail "deploy.log line"
compgen -G "$logs/builds/deploy-*.log" >/dev/null || fail "no build log"
runuser -u next_app -- cat /etc/next_app/env 2>/dev/null && fail "next_app can read its env file"
runuser -u deployer -- cat /etc/next_app/env 2>/dev/null && fail "deployer can read the env file"
echo "zero-config first deploy OK"
