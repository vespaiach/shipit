#!/usr/bin/env bash
# Isolation: two apps with a database each. The db_a user can't read /opt/db_b or connect to db_b's
# database, and deployer can't read /etc/db_a/env or connect to Postgres as a superuser. Also checks the
# database question, the role, the migration and that DATABASE_URL is written once.
set -euo pipefail
# shellcheck source=test/e2e/helpers.sh
. "$(dirname "$0")/../helpers.sh"

[ -e /etc/shipit/host.conf ] || fail "run the setup scenarios first"

# psql_as <user> <psql args...>: psql as a Linux user, from /, never asking for a password.
psql_as() {
  local user=$1
  shift
  (cd / && runuser -u "$user" -- psql -X -w -q -t -A "$@" </dev/null)
}

for name in db-a db-b; do
  app=${name/-/_}
  url=$(make_repo "$name" test/fixtures/node-app)
  sha=$(short_sha "$name")
  # The node-app fixture lists no PostgreSQL package, so the default is no: answer y.
  out=$(printf '%s.localhost\ny\nhello %s\ntoken-%s\n' "$name" "$app" "$app" | in_terminal "shipit deploy $url" 2>&1) || {
    echo "$out"
    fail "the first deploy of $app failed"
  }
  echo "$out"
  grep -q 'Create a PostgreSQL database? \[y/N\]' <<<"$out" || fail "the database question wasn't asked with default no"
  grep -q "Deployed $sha. https://$name.localhost" <<<"$out" || fail "$app didn't end with Deployed $sha"
  grep -qx "DATABASE=$app" "/etc/shipit/apps/$app.conf" || fail "$app.conf has no DATABASE=$app"
  grep -Eqx "DATABASE_URL=postgresql://$app:[0-9a-f]{48}@127\.0\.0\.1:5432/$app" "/etc/$app/env" \
    || fail "/etc/$app/env has no DATABASE_URL"
  [ "$(stat -c '%U %G %a' "/etc/$app/env")" = 'root root 600' ] || fail "/etc/$app/env perms"
  grep -q "applying migrations/001_greetings.sql" <<<"$out" || fail "$app's migration didn't run"
  [ "$(psql_as postgres -d "$app" -c 'SELECT text FROM greetings WHERE id = 1')" = hello ] \
    || fail "$app's migration didn't create its table"
  [ "$(psql_as postgres -c "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = '$app'")" = "$app" ] \
    || fail "the $app database isn't owned by the $app role"
  [ "$(psql_as postgres -c "SELECT rolsuper OR rolcreatedb OR rolcreaterole FROM pg_roles WHERE rolname = '$app'")" = f ] \
    || fail "the $app role has more than LOGIN"
done

# Each app reaches its own database: as its own user over the socket (peer), and with its URL.
[ "$(psql_as db_a -d db_a -c 'SELECT 1')" = 1 ] || fail "db_a can't connect to its own database"
url_a=$(sed -n 's/^DATABASE_URL=//p' /etc/db_a/env)
[ "$(psql_as db_a "$url_a" -c 'SELECT count(*) FROM greetings')" = 1 ] || fail "db_a's DATABASE_URL doesn't work"

# ...but not the other app's code or database, in any way it could try.
runuser -u db_a -- ls /opt/db_b >/dev/null 2>&1 && fail "db_a can read /opt/db_b"
psql_as db_a -d db_b -c 'SELECT 1' 2>/dev/null && fail "db_a can connect to db_b's database over the socket"
psql_as db_a "${url_a%/db_a}/db_b" -c 'SELECT 1' 2>/dev/null && fail "db_a's role can connect to db_b's database"
psql_as db_a -h 127.0.0.1 -U db_b -d db_b -c 'SELECT 1' 2>/dev/null && fail "db_a can connect as db_b without its password"
psql_as db_a -U postgres -d postgres -c 'SELECT 1' 2>/dev/null && fail "db_a can connect as postgres"

# deployer builds and migrates, but can't read env files at rest or reach Postgres on its own.
runuser -u deployer -- cat /etc/db_a/env >/dev/null 2>&1 && fail "deployer can read /etc/db_a/env"
psql_as deployer -d db_a -c 'SELECT 1' 2>/dev/null && fail "deployer can connect to db_a over the socket"
psql_as deployer -U postgres -d postgres -c 'SELECT 1' 2>/dev/null && fail "deployer can connect as postgres"
psql_as deployer -h 127.0.0.1 -U postgres -d postgres -c 'SELECT 1' 2>/dev/null && fail "deployer can connect as postgres over TCP"

# A redeploy keeps the password: DATABASE_URL is written once, and the role isn't touched.
before=$(sha256sum /etc/db_a/env)
out=$(shipit deploy db_a </dev/null 2>&1) || {
  echo "$out"
  fail "the redeploy of db_a failed"
}
[ "$(sha256sum /etc/db_a/env)" = "$before" ] || fail "the redeploy changed /etc/db_a/env"
grep -q 'Created the PostgreSQL role' <<<"$out" && fail "the redeploy created the role again"
[ "$(psql_as db_a "$url_a" -c 'SELECT 1')" = 1 ] || fail "db_a's DATABASE_URL stopped working after a redeploy"
echo "database isolation OK"
