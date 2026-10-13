#!/usr/bin/env bash
# Runs inside the VM as root, from /root/shipit, after install.sh. Checks the install and the dispatcher.
set -euo pipefail

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ "$(readlink /usr/local/bin/shipit)" = /usr/local/lib/shipit/bin/shipit ] || fail "/usr/local/bin/shipit isn't linked"
[ -f /usr/local/lib/shipit/lib/common.sh ] || fail "lib/common.sh isn't installed"
[ -z "$(find /usr/local/lib/shipit ! -user root -o -perm /022)" ] || fail "installed files must be root-owned and not group/world-writable"

shipit help | grep -q 'Usage: sudo shipit' || fail "help doesn't print usage"

out=$(runuser -u nobody -- shipit status 2>&1) && fail "status ran as a non-root user"
[ "$out" = "Run this as root, or with sudo: sudo shipit status" ] || fail "unexpected root message: $out"

out=$(shipit nope 2>&1) && fail "an unknown command succeeded"
[ "$out" = "Unknown command: nope. Run 'shipit help' for the list." ] || fail "unexpected message: $out"

# A re-install replaces the copy and leaves no temp folders behind.
/root/shipit/install.sh >/dev/null
[ ! -e /usr/local/lib/shipit.new ] && [ ! -e /usr/local/lib/shipit.old ] || fail "install.sh left a temp folder"
echo "install and dispatcher OK"
