#!/usr/bin/env bash
# .env.example prompts: missing keys are asked once. A key added in a later release is asked on that
# deploy. With no terminal, deploy fails and names `shipit env`.
set -euo pipefail
# shellcheck source=test/e2e/helpers.sh
. "$(dirname "$0")/../helpers.sh"

[ -e /etc/shipit/host.conf ] || fail "run the setup scenarios first"
url=$(make_repo node-app test/fixtures/node-app)
sha=$(short_sha node-app)
env=/etc/node_app/env

# First deploy, in a terminal: the domain, no database, then GREETING and API_TOKEN (hidden input).
out=$(printf 'node-app.localhost\n\nhello there\ns3cret-token\n' | in_terminal "shipit deploy $url" 2>&1) || {
  echo "$out"
  fail "the first deploy failed"
}
echo "$out"
grep -q "Deployed $sha. https://node-app.localhost" <<<"$out" || fail "it didn't end with Deployed $sha"
[ "$(grep -c 'GREETING: ' <<<"$out")" = 1 ] || fail "GREETING wasn't asked exactly once"
[ "$(grep -c 'API_TOKEN: ' <<<"$out")" = 1 ] || fail "API_TOKEN wasn't asked exactly once"
# (Whether the answers were echoed can't be checked here: the terminal echoes piped-in answers as soon
# as they arrive, before deploy turns echo off.)
grep -qx 'GREETING=hello there' "$env" || fail "$env has no GREETING"
grep -qx 'API_TOKEN=s3cret-token' "$env" || fail "$env has no API_TOKEN"
[ "$(stat -c '%U %G %a' "$env")" = 'root root 600' ] || fail "$env perms"
served node-app.localhost | grep -q 'hello there' || fail "the app didn't get GREETING"

# A redeploy of the same keys asks nothing, even without a terminal.
out=$(shipit deploy node_app </dev/null 2>&1) || {
  echo "$out"
  fail "a redeploy without new keys failed"
}

# A key added in a later release is asked on that deploy, and only that key.
repo=/srv/git/node-app.git
sha=$(add_line "$repo" .env.example 'NEW_KEY=')
before=$(grep -v '^NEW_KEY=' "$env")
out=$(printf 'new value\n' | in_terminal 'shipit deploy node_app' 2>&1) || {
  echo "$out"
  fail "the deploy with a new key failed"
}
echo "$out"
grep -q 'NEW_KEY: ' <<<"$out" || fail "NEW_KEY wasn't asked"
grep -Eq '(GREETING|API_TOKEN): ' <<<"$out" && fail "a key the env file has was asked again"
grep -qx 'NEW_KEY=new value' "$env" || fail "$env has no NEW_KEY"
[ "$(grep -v '^NEW_KEY=' "$env")" = "$before" ] || fail "existing env values changed"
grep -q "Deployed $sha." <<<"$out" || fail "it didn't deploy $sha"

# With no terminal, a new key makes deploy fail before building, naming shipit env.
current=$(readlink /opt/node_app/current)
add_line "$repo" .env.example 'THIRD_KEY=' >/dev/null
out=$(shipit deploy node_app </dev/null 2>&1) && fail "deploy succeeded without a terminal to ask THIRD_KEY"
echo "$out"
grep -q 'THIRD_KEY' <<<"$out" || fail "the error doesn't name THIRD_KEY"
grep -q 'sudo shipit env node_app' <<<"$out" || fail "the error doesn't name shipit env"
[ "$(readlink /opt/node_app/current)" = "$current" ] || fail "current changed"
[ "$(find /opt/node_app/releases -mindepth 1 -maxdepth 1 | wc -l)" = 2 ] || fail "the failed release was kept"
grep -q '^THIRD_KEY=' "$env" && fail "THIRD_KEY was written"

# Once the env file has the key (as shipit env would add it), the deploy goes through unattended.
printf 'THIRD_KEY=\n' >>"$env"
out=$(shipit deploy node_app </dev/null 2>&1) || {
  echo "$out"
  fail "the deploy failed after THIRD_KEY was added"
}
grep -q "Deployed $(short_sha node-app)." <<<"$out" || fail "it didn't deploy the THIRD_KEY release"
echo ".env.example prompts OK"
