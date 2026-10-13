#!/usr/bin/env bash
# Redeploy is idempotent: a second deploy of the same sha changes no file in /etc. Also: a URL redeploys
# the app whose REPO it is, --ref deploys an older commit of the branch and refuses one the branch
# doesn't contain, and an edited app config (port, domain, LOG_REDACT_QUERY) is applied by the next
# deploy, with the port rules (a port in use or another app's port is refused).
set -euo pipefail
# shellcheck source=test/e2e/helpers.sh
. "$(dirname "$0")/../helpers.sh"

[ -e /etc/shipit/apps/node_app.conf ] || fail "run 23-deploy-env-prompts first"
repo=/srv/git/node-app.git
conf=/etc/shipit/apps/node_app.conf
sha=$(short_sha node-app)

# deploy <url> redeploys the app whose REPO matches.
deploy_ok file:///srv/git/node-app.git
grep -q 'file:///srv/git/node-app.git is the app node_app.' <<<"$out" || fail "the URL wasn't matched to node_app"
grep -q 'Domain for' <<<"$out" && fail "the URL was treated as a new app"
grep -q "Deployed $sha." <<<"$out" || fail "it didn't deploy $sha"

# The same sha again changes no file in /etc.
before=$(etc_checksums)
deploy_ok node_app
diff <(echo "$before") <(etc_checksums) || fail "the second deploy of $sha changed files in /etc"
grep -q '^Wrote ' <<<"$out" && fail "the second deploy wrote a file"
grep -q "Deployed $sha." <<<"$out" || fail "it didn't deploy $sha"

# --ref: an older commit of main deploys; a commit only another branch has is refused.
first=$(git -c safe.directory='*' -C "$repo" rev-list --max-parents=0 main | cut -c1-7)
deploy_ok node_app --ref "$first"
grep -q "Deployed $first." <<<"$out" || fail "--ref $first didn't deploy it"
[[ $(readlink /opt/node_app/current) == *-"$first" ]] || fail "current isn't $first"
work=$(mktemp -d)
git -c safe.directory='*' clone -q "$repo" "$work"
git -C "$work" checkout -q -b other
git -C "$work" -c user.name=e2e -c user.email=e2e@localhost commit -q --allow-empty -m 'not on main'
git -c safe.directory='*' -C "$work" push -q origin other
other=$(git -C "$work" rev-parse --short=7 HEAD)
rm -rf "$work"
chown -R deployer: "$repo"
current=$(readlink /opt/node_app/current)
out=$(shipit deploy node_app --ref "$other" </dev/null 2>&1) && fail "--ref $other (not on main) was deployed"
echo "$out"
grep -q "$other isn't a commit on main" <<<"$out" || fail "the refusal doesn't say $other isn't on main"
[ "$(readlink /opt/node_app/current)" = "$current" ] || fail "current changed"
deploy_ok node_app
grep -q "Deployed $sha." <<<"$out" || fail "it didn't go back to $sha"

# Config changes: a new port, domain and LOG_REDACT_QUERY are applied by the next deploy.
cp "$conf" /root/node_app.conf.orig
old_port=$(sed -n 's/^PORT=//p' "$conf")
sed -i -e 's/^PORT=.*/PORT=3050/' -e 's/^DOMAIN=.*/DOMAIN=node-app2.localhost/' "$conf"
echo 'LOG_REDACT_QUERY="token code"' >>"$conf"
deploy_ok node_app
grep -q 'sets an APP_URL other than https://node-app2.localhost' <<<"$out" || fail "no word about APP_URL"
grep -qx 'Environment=NODE_ENV=production PORT=3050' /etc/systemd/system/node_app@.service || fail "the unit's PORT"
site=/etc/caddy/sites/node_app.caddy
grep -q 'reverse_proxy 127.0.0.1:3050' "$site" || fail "the site's port"
grep -q '^node-app2.localhost {' "$site" || fail "the site's domain"
grep -q 'delete token' "$site" || fail "the site doesn't redact token"
grep -q 'delete code' "$site" || fail "the site doesn't redact code"
[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:3050/health")" = 200 ] || fail "nothing answers on 3050"
served node-app2.localhost | grep -q 'Hello from node-app' || fail "node-app2.localhost isn't served"
ss -ltnH | awk '{ print $4 }' | grep -q ":$old_port\$" && fail "something still listens on $old_port"

# A port something listens on (Caddy's admin API) or another app's port is refused, changing nothing.
sed -i 's/^PORT=.*/PORT=2019/' "$conf"
out=$(shipit deploy node_app </dev/null 2>&1) && fail "a port in use was accepted"
grep -q 'Something is already listening on port 2019.' <<<"$out" || fail "the in-use refusal: $out"
sed -i 's/^PORT=.*/PORT=3001/' "$conf"
out=$(shipit deploy node_app </dev/null 2>&1) && fail "another app's port was accepted"
grep -q 'Port 3001 is already used by the app next_app.' <<<"$out" || fail "the other-app refusal: $out"
grep -qx 'Environment=NODE_ENV=production PORT=3050' /etc/systemd/system/node_app@.service || fail "a refused deploy changed the unit"

# Back to the original config.
install -m 644 /root/node_app.conf.orig "$conf"
rm /root/node_app.conf.orig
deploy_ok node_app
grep -qx "Environment=NODE_ENV=production PORT=$old_port" /etc/systemd/system/node_app@.service || fail "the port didn't go back"
served node-app.localhost | grep -q 'Hello from node-app' || fail "node-app.localhost isn't served"
echo "idempotent redeploy, --ref and config changes OK"
