#!/bin/sh
# The migration step (npm run db:migrate): applies migrations/*.sql in order with psql. Committing a file
# named FAIL_MIGRATION makes it fail, for the failing-migration test. Without a database (no
# DATABASE_URL) there's nothing to migrate.
set -eu
if [ -e FAIL_MIGRATION ]; then
  echo "FAIL_MIGRATION is present, so this migration fails." >&2
  exit 1
fi
if [ -z "${DATABASE_URL-}" ]; then
  echo "No DATABASE_URL, so there's nothing to migrate."
  exit 0
fi
for f in migrations/*.sql; do
  echo "applying $f"
  psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 -f "$f"
done
