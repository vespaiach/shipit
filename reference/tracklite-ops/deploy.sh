#!/usr/bin/env bash
# Deploys the latest main (M10.2, OPS-002). Usage on the VPS, as deployer: /opt/tracklite/current/ops/deploy.sh
# Builds a new release beside the live one and migrates the database. It switches to the new release only if
# the migrations succeed. The previous release stays, so ops/rollback.sh can switch back (OPS-004).
set -euo pipefail

root="${TRACKLITE_ROOT:-/opt/tracklite}"
env_file="${TRACKLITE_ENV_FILE:-/etc/tracklite/env}"
repo="${TRACKLITE_REPO:-https://github.com/vespaiach/tracklite.git}"

if [ "$(id -u)" -eq 0 ]; then
  echo "Run this as deployer, not root: the releases must not be owned by root (see ops/README.md)." >&2
  exit 1
fi

# Builds and migrations need the settings too: src/server/db.ts reads them on import.
# shellcheck source=/dev/null
in_release() { (cd "$release" && set -a && . "$env_file" && set +a && "$@"); }

echo "== Fetching main from $repo"
[ -d "$root/repo" ] || git init --quiet --bare "$root/repo"
git -C "$root/repo" fetch --quiet "$repo" main
sha="$(git -C "$root/repo" rev-parse --short FETCH_HEAD)"
release="$root/releases/$(date -u +%Y%m%d%H%M%S)-$sha"
trap 'rm -rf "$release"' EXIT
mkdir "$release"
git -C "$root/repo" archive FETCH_HEAD | tar -x -C "$release"

echo "== Installing and building $sha"
in_release npm ci --no-audit --no-fund
in_release npm run build

echo "== Migrating the database"
old="$(readlink "$root/current" || true)"
if ! in_release npm run db:migrate; then
  echo "Migrations failed, so nothing was switched. Still serving ${old:-no release}." >&2
  exit 1
fi

echo "== Switching to $sha"
ln -sfn "$release" "$root/current"
trap - EXIT
[ -z "$old" ] || ln -sfn "$old" "$root/previous"
sudo systemctl restart tracklite-web tracklite-worker

echo "== Removing releases older than the previous one"
previous="$(readlink "$root/previous" || true)"
for dir in "$root"/releases/*; do
  [ "$dir" = "$release" ] || [ "$dir" = "$previous" ] || rm -rf "$dir"
done

echo "== Checking /health"
if ! curl -fsS --retry 15 --retry-connrefused --retry-delay 2 -o /dev/null http://127.0.0.1:3000/health; then
  echo "Deployed $sha, but /health doesn't answer 200. Switch back with: $root/current/ops/rollback.sh" >&2
  exit 1
fi
echo "Deployed $sha."
