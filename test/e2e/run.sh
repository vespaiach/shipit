#!/usr/bin/env bash
# End-to-end scenarios in a throwaway Debian 13 Incus VM (plan §7). Run by hand, never in CI's gate:
#   test/e2e/run.sh                 every scenario in test/e2e/scenarios/, in name order
#   test/e2e/run.sh 00-install      only the named scenarios
# Set KEEP_VM=1 to keep the VM afterwards for debugging. Needs incus with VM support (KVM).
set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
vm=shipit-e2e-$$

cleanup() {
  if [ "${KEEP_VM-}" = 1 ]; then
    echo "Kept VM $vm. Delete it with: incus delete --force $vm"
  else
    incus delete --force "$vm" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "== Launching $vm"
# 4 GiB of RAM, like a KVM 1: the default 1 GiB is too little for a next build.
incus launch images:debian/13 "$vm" --vm -c limits.cpu=2 -c limits.memory=4GiB
for _ in $(seq 60); do
  incus exec "$vm" -- true 2>/dev/null && break
  sleep 2
done
incus exec "$vm" -- systemctl is-system-running --wait >/dev/null || true

echo "== Copying the checkout and installing"
tar -C "$repo" --exclude=.git -czf - . | incus exec "$vm" -- bash -c 'mkdir -p /root/shipit && tar -C /root/shipit -xzf -'
incus exec "$vm" -- /root/shipit/install.sh

if [ "$#" -eq 0 ]; then
  for f in "$repo"/test/e2e/scenarios/*.sh; do
    f=${f##*/}
    set -- "$@" "${f%.sh}"
  done
fi

failed=()
for scenario in "$@"; do
  echo "== Scenario $scenario"
  if incus exec "$vm" --cwd /root/shipit -- bash "test/e2e/scenarios/$scenario.sh"; then
    echo "-- passed: $scenario"
  else
    echo "-- FAILED: $scenario"
    failed+=("$scenario")
  fi
done

if [ "${#failed[@]}" -gt 0 ]; then
  echo "Failed: ${failed[*]}"
  exit 1
fi
echo "All scenarios passed."
