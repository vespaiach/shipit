#!/usr/bin/env bash
# Failing migration: exit 1, the new release is deleted, current is unchanged and still served
# (OPS-002.2). The node-app fixture's migration fails when the repo has a file named FAIL_MIGRATION.
set -euo pipefail
# shellcheck source=test/e2e/helpers.sh
. "$(dirname "$0")/../helpers.sh"

[ -e /etc/shipit/apps/db_a.conf ] || fail "run 24-deploy-database-isolation first"
repo=/srv/git/db-a.git
releases=/opt/db_a/releases
current=$(readlink /opt/db_a/current)
before=$(ls "$releases")
pid=$(systemctl show -p MainPID --value db_a@web.service)

sha=$(add_line "$repo" FAIL_MIGRATION yes)
out=$(shipit deploy db_a </dev/null 2>&1) && {
  echo "$out"
  fail "the deploy succeeded with a failing migration"
}
echo "$out"
grep -q 'FAIL_MIGRATION is present, so this migration fails.' <<<"$out" || fail "the migration's error isn't shown"
grep -q "Migrations failed, so nothing was switched. Still serving ${current##*/}." <<<"$out" \
  || fail "the failure message doesn't name the release still served"
[ "$(readlink /opt/db_a/current)" = "$current" ] || fail "current changed"
[ "$(ls "$releases")" = "$before" ] || fail "the failed release wasn't deleted"
compgen -G "$releases/*-$sha" >/dev/null && fail "a release of $sha is left"
tail -n 1 /var/log/shipit/db_a/deploy.log | grep -Eq "^[0-9TZ:-]+ db_a $sha root failed$" || fail "deploy.log line"
[ "$(systemctl show -p MainPID --value db_a@web.service)" = "$pid" ] || fail "db_a was restarted"
served db-a.localhost | grep -q 'Hello from node-app' || fail "db_a isn't served any more"

# Without the flag, the next deploy migrates and switches.
work=$(mktemp -d)
git -c safe.directory='*' clone -q "$repo" "$work"
git -C "$work" rm -q FAIL_MIGRATION
git -C "$work" -c user.name=e2e -c user.email=e2e@localhost commit -q -m 'migrations pass again'
git -c safe.directory='*' -C "$work" push -q origin main
sha=$(git -C "$work" rev-parse --short=7 HEAD)
rm -rf "$work"
chown -R deployer: "$repo"
out=$(shipit deploy db_a </dev/null 2>&1) || {
  echo "$out"
  fail "the deploy after removing FAIL_MIGRATION failed"
}
grep -q "Deployed $sha." <<<"$out" || fail "it didn't deploy $sha"
echo "failing migration OK"
