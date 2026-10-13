#!/usr/bin/env bash
# A second setup asks nothing and changes no file in /etc.
set -euo pipefail
# shellcheck source=test/e2e/helpers.sh
. "$(dirname "$0")/../helpers.sh"

[ -e /etc/shipit/host.conf ] || fail "run 10-setup-password-session first"
before=$(etc_checksums)
out=$(shipit setup </dev/null 2>&1) || {
  echo "$out"
  fail "the second setup failed"
}
echo "$out"
after=$(etc_checksums)
if [ "$before" != "$after" ]; then
  diff <(echo "$before") <(echo "$after") || true
  fail "the second setup changed files in /etc"
fi
grep -qF 'Nothing to change: this VPS is already set up.' <<<"$out" || fail "expected no changes"
echo "setup twice OK"
