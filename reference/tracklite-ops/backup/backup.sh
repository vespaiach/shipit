#!/usr/bin/env bash
# Daily database backup (OPS-003), run by tracklite-backup.service as the postgres user.
# Dumps the database, encrypts it to AGE_RECIPIENT, uploads it to R2 and keeps the newest 14.
set -euo pipefail

keep=14
name="tracklite-$(date -u +%Y%m%dT%H%M%SZ).dump.age"
dump="$(mktemp)"
trap 'rm -f "$dump"' EXIT

pg_dump --format=custom tracklite | age --encrypt --recipient "$AGE_RECIPIENT" > "$dump"
rclone copyto "$dump" "r2:$R2_BUCKET/$name"
echo "Uploaded $name ($(stat -c %s "$dump") bytes)"

rclone lsf "r2:$R2_BUCKET" --files-only --include 'tracklite-*.dump.age' \
  | sort -r | tail -n +$((keep + 1)) \
  | while read -r old; do
      rclone deletefile "r2:$R2_BUCKET/$old"
      echo "Deleted $old"
    done
