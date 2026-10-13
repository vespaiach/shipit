#!/usr/bin/env bash
# Restores a backup into a database (OPS-003.1). Runs on any machine with rclone, age and
# pg_restore, with the R2 settings from backup.env exported and the private age key at hand.
# Usage: ops/backup/restore.sh <age-key-file> <target-database-url> [backup-name | latest]
set -euo pipefail

key="${1:?Usage: restore.sh <age-key-file> <target-database-url> [backup-name | latest]}"
target="${2:?Usage: restore.sh <age-key-file> <target-database-url> [backup-name | latest]}"
name="${3:-latest}"

if [ "$name" = latest ]; then
  name="$(rclone lsf "r2:$R2_BUCKET" --files-only --include 'tracklite-*.dump.age' | sort | tail -n 1)"
  [ -n "$name" ] || { echo "No backups in r2:$R2_BUCKET" >&2; exit 1; }
fi

echo "Restoring $name into $target"
rclone cat "r2:$R2_BUCKET/$name" \
  | age --decrypt --identity "$key" \
  | pg_restore --no-owner --no-privileges --exit-on-error --dbname "$target"
echo "Done"
