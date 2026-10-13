#!/usr/bin/env bash
# Private repo: deploy prints a key and waits. When the key is authorized (by the test), it continues
# without being re-run. The repo is ssh://git@localhost/…, served by the VM's own sshd to a `git` user.
# Uses the node-app fixture without .env.example, so it also covers deploy.conf with two processes.
set -euo pipefail
# shellcheck source=test/e2e/helpers.sh
. "$(dirname "$0")/../helpers.sh"

[ -e /etc/shipit/host.conf ] || fail "run the setup scenarios first"
e2e_ssh_ready
# The git user's repo, reachable only with a key that's in its authorized_keys.
id git >/dev/null 2>&1 || useradd --create-home --shell /bin/sh git
install -d -m 700 -o git -g git /home/git/.ssh
install -m 600 -o git -g git /dev/null /home/git/.ssh/authorized_keys
work=$(mktemp -d)
cp -R test/fixtures/node-app/. "$work/"
rm -f "$work/.env.example"
git -C "$work" init -q -b main
git -C "$work" add -A
git -C "$work" -c user.name=e2e -c user.email=e2e@localhost commit -q -m fixture
rm -rf /home/git/private-app.git
git clone -q --bare "$work" /home/git/private-app.git
rm -rf "$work"
chown -R git: /home/git/private-app.git
sha=$(git -c safe.directory='*' -C /home/git/private-app.git rev-parse --short=7 main)
url=ssh://git@localhost/home/git/private-app.git
# deploy trusts only /etc/ssh/ssh_known_hosts, so pin localhost's host key there (setup pinned GitHub's).
grep -q '^localhost ' /etc/ssh/ssh_known_hosts || ssh-keyscan -t ed25519 localhost 2>/dev/null >>/etc/ssh/ssh_known_hosts

log=$(mktemp)
printf 'private-app.localhost\n' | shipit deploy "$url" >"$log" 2>&1 &
deploy_pid=$!
key=''
for _ in $(seq 60); do
  key=$(grep -m 1 -o 'ssh-ed25519 [A-Za-z0-9+/=]* shipit-private_app@[^ ]*' "$log" || true)
  [ -n "$key" ] && break
  kill -0 "$deploy_pid" 2>/dev/null || break
  sleep 1
done
[ -n "$key" ] || {
  cat "$log"
  fail "deploy didn't print a deploy key"
}
grep -q 'Waiting for the repo to accept it' "$log" || fail "deploy didn't say it's waiting"
sleep 6
kill -0 "$deploy_pid" 2>/dev/null || {
  cat "$log"
  fail "deploy stopped instead of waiting for the key"
}
# Authorize the key, the way you'd add it on GitHub. deploy carries on by itself.
printf '%s\n' "$key" >>/home/git/.ssh/authorized_keys
wait "$deploy_pid" || {
  cat "$log"
  fail "the private deploy failed"
}
out=$(cat "$log")
echo "$out"
[ "$(grep -c 'ssh-ed25519 ' <<<"$out")" = 1 ] || fail "the key was printed more than once"
grep -q 'The deploy key works.' <<<"$out" || fail "no word that the key works"
[ "$(tail -n 1 <<<"$out")" = "Deployed $sha. https://private-app.localhost" ] || fail "it didn't end with Deployed $sha"

conf=/etc/shipit/apps/private_app.conf
grep -qxF "REPO=$url" "$conf" || fail "$conf doesn't use the SSH URL"
grep -qx BRANCH=main "$conf" || fail "$conf has no BRANCH=main"
[ "$(stat -c '%U %a' /home/deployer/.ssh/shipit_private_app)" = 'deployer 600' ] || fail "deploy key perms"
[ ! -e /home/deployer/.ssh/known_hosts ] || fail "deployer trusted a host key on first use"

# deploy.conf: both processes run, and health used HEALTH_PATH.
grep -qx 'Wants=private_app@web.service private_app@worker.service' /etc/systemd/system/private_app.target \
  || fail "the target doesn't want web and worker"
systemctl is-active --quiet private_app@web.service || fail "web isn't running"
systemctl is-active --quiet private_app@worker.service || fail "worker isn't running"
grep -q "Checking http://127.0.0.1:[0-9]*/health" <<<"$out" || fail "health didn't use HEALTH_PATH"
sleep 6
grep -q 'worker tick' /var/log/shipit/private_app/worker.log || fail "worker.log has no ticks"
served private-app.localhost | grep -q 'Hello from node-app (built)' || fail "/ isn't served through Caddy"

# A redeploy with a working key asks nothing and prints no key.
out=$(shipit deploy private_app </dev/null 2>&1) || {
  echo "$out"
  fail "the redeploy failed"
}
grep -q 'ssh-ed25519' <<<"$out" && fail "the redeploy printed the key again"
[ "$(tail -n 1 <<<"$out")" = "Deployed $sha. https://private-app.localhost" ] || fail "the redeploy didn't end with Deployed"
echo "private repo OK"
