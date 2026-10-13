#!/usr/bin/env bash
# Switches back to the previous release (M10.2, OPS-004). Usage on the VPS, as deployer: /opt/tracklite/current/ops/rollback.sh
# Leaves the database alone: each release's migrations work with the previous release's code.
set -euo pipefail

root="${TRACKLITE_ROOT:-/opt/tracklite}"

if [ "$(id -u)" -eq 0 ]; then
  echo "Run this as deployer, not root: the release links must stay owned by deployer (see ops/README.md)." >&2
  exit 1
fi

previous="$(readlink "$root/previous" || true)"
if [ -z "$previous" ] || [ ! -d "$previous" ]; then
  echo "No previous release to roll back to." >&2
  exit 1
fi

ln -sfn "$previous" "$root/current"
rm "$root/previous"
sudo systemctl restart tracklite-web tracklite-worker
echo "Rolled back to $(basename "$previous")."
