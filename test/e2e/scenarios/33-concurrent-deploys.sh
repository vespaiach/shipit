#!/usr/bin/env bash
# Deploy one app twice at once: the second exits with the lock message (so does a rollback). Deploy two
# apps at once: the builds run one after the other (the times each build log records for the build
# lock), and both succeed.
set -euo pipefail
# shellcheck source=test/e2e/helpers.sh
. "$(dirname "$0")/../helpers.sh"

for app in next_app second_app; do
  [ -e "/etc/shipit/apps/$app.conf" ] || fail "run the deploy scenarios first ($app is missing)"
done

# The same app twice (next_app: its build is slow enough to overlap).
first=$(mktemp)
shipit deploy next_app </dev/null >"$first" 2>&1 &
pid=$!
for _ in $(seq 120); do
  grep -q '== Setting up next_app' "$first" && break
  sleep 0.5
done
grep -q '== Setting up next_app' "$first" || fail "the first deploy didn't start"
out=$(shipit deploy next_app </dev/null 2>&1) && fail "a second deploy of next_app ran at the same time"
[ "$out" = "Another deploy or rollback of next_app is running." ] || fail "the second deploy said: $out"
out=$(shipit rollback next_app </dev/null 2>&1) && fail "a rollback ran during the deploy"
[ "$out" = "Another deploy or rollback of next_app is running." ] || fail "the rollback said: $out"
wait "$pid" || {
  cat "$first"
  fail "the first deploy failed"
}
grep -q 'Deployed ' "$first" || fail "the first deploy didn't finish"

# Two apps at once.
la=$(mktemp)
lb=$(mktemp)
shipit deploy next_app </dev/null >"$la" 2>&1 &
pa=$!
shipit deploy second_app </dev/null >"$lb" 2>&1 &
pb=$!
wait "$pa" || {
  cat "$la"
  fail "next_app's deploy failed"
}
wait "$pb" || {
  cat "$lb"
  fail "second_app's deploy failed"
}
grep -q 'Deployed ' "$la" || fail "next_app's deploy didn't finish"
grep -q 'Deployed ' "$lb" || fail "second_app's deploy didn't finish"
[ "$(cat "$la" "$lb" | grep -c "Waiting for another app's build…")" = 1 ] || fail "one deploy should have waited for the build lock"

# build_window <app>: the epoch seconds its newest build log says the build lock was taken and released.
build_window() {
  local f
  f=$(find "/var/log/shipit/$1/builds" -name 'deploy-*.log' | sort | tail -n 1)
  printf '%s %s\n' "$(date -d "$(sed -n 's/^== Build lock taken at //p' "$f")" +%s)" \
    "$(date -d "$(sed -n 's/^== Build lock released at //p' "$f")" +%s)"
}
read -r a_start a_end < <(build_window next_app)
read -r b_start b_end < <(build_window second_app)
echo "next_app built $a_start-$a_end, second_app built $b_start-$b_end"
[ "$a_end" -le "$b_start" ] || [ "$b_end" -le "$a_start" ] || fail "the two builds overlapped"
echo "locks OK"
