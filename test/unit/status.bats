#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031,SC2034 # single-quoted stub bodies; tests set lib variables
# lib/status.sh: release names, the line formatting, and whole blocks with systemctl, curl and caddy
# stubbed.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  load_common
  # shellcheck source=lib/status.sh
  . "$REPO_ROOT/lib/status.sh"
  # shellcheck disable=SC2329 # called by the functions under test
  as_deployer() { (cd / && env -i HOME="$HOME" PATH="$PATH" "$@"); }
  SHIPIT_OPT=$BATS_TEST_TMPDIR/opt
  LOG_ROOT=$BATS_TEST_TMPDIR/log
  BACKUP_ROOT=$BATS_TEST_TMPDIR/backups
  CADDYFILE=$BATS_TEST_TMPDIR/Caddyfile
  mkdir -p "$LOG_ROOT" "$BACKUP_ROOT"
  # systemctl: is-active answers from $BATS_TEST_TMPDIR/states (lines "<unit> <state>", inactive when
  # missing); show prints $BATS_TEST_TMPDIR/show.
  : >"$BATS_TEST_TMPDIR/states"
  printf 'Result=success\nExecMainExitTimestamp=\n' >"$BATS_TEST_TMPDIR/show"
  stub systemctl 'echo "$*" >>"'"$BATS_TEST_TMPDIR"'/systemctl.calls"
case $1 in
  is-active)
    s=$(awk -v u="$2" '\''$1 == u { print $2 }'\'' "'"$BATS_TEST_TMPDIR"'/states")
    echo "${s:-inactive}"
    [ "${s:-inactive}" = active ] ;;
  show) cat "'"$BATS_TEST_TMPDIR"'/show" ;;
  *) exit 1 ;;
esac'
  stub curl 'echo "$*" >>"'"$BATS_TEST_TMPDIR"'/curl.calls"; printf 200'
  stub caddy 'exit 0'
}

# app <name> <domain> <port> [database]: an app config.
app() {
  write_app_conf "$1" "REPO=file:///srv/git/$1.git" BRANCH=main "DOMAIN=$2" "PORT=$3" "DATABASE=${4-}"
}

# release <app> <name> [deploy.conf lines...]: a release folder; prints its path.
release() {
  local dir=$SHIPIT_OPT/$1/releases/$2
  shift 2
  mkdir -p "$dir"
  [ "$#" -eq 0 ] || printf '%s\n' "$@" >"$dir/deploy.conf"
  printf '%s\n' "$dir"
}

state() { printf '%s %s\n' "$1" "$2" >>"$BATS_TEST_TMPDIR/states"; }

# ---- Formatting ----------------------------------------------------------------------------------

@test "release_label: time and sha from the release name" {
  [ "$(release_label /opt/a/releases/20261013T093005Z-abc1234)" = 'abc1234 (2026-10-13 09:30:05 UTC)' ]
  [ "$(release_label 20250101T000000Z-0123456789abcdef)" = '0123456789abcdef (2025-01-01 00:00:00 UTC)' ]
}

@test "release_label: a name that isn't <UTC>-<sha> is shown as it is" {
  [ "$(release_label /opt/a/releases/hand-made)" = hand-made ]
  [ "$(release_label /opt/a/releases/20261013T093005Z-XYZ)" = 20261013T093005Z-XYZ ]
}

@test "status_line: label padded to one column" {
  [ "$(status_line web active)" = '  web        active' ]
  [ "$(status_line deploy.log 'a b')" = '  deploy.log a b' ]
}

@test "instance_text: active is plain; anything else is shouted, with where to look" {
  [ "$(instance_text app web active)" = active ]
  [ "$(instance_text app worker failed)" = 'FAILED. See: sudo shipit logs app worker, or systemctl status app@worker' ]
  [ "$(instance_text app web activating)" = 'ACTIVATING. See: sudo shipit logs app web, or systemctl status app@web' ]
  [[ $(instance_text app web '') == UNKNOWN.* ]]
}

@test "health_text: judged the way deploy judges it" {
  [ "$(health_text / 302)" = '/ answered 302 (healthy)' ]
  [ "$(health_text / 502)" = '/ answered 502 (UNHEALTHY)' ]
  [ "$(health_text /health 308 1)" = '/health answered 308 (UNHEALTHY)' ]
  [ "$(health_text /health 200 1)" = '/health answered 200 (healthy)' ]
  [ "$(health_text / 000)" = '/ got no answer (UNHEALTHY)' ]
}

@test "backup_result: success, failed or never run" {
  [ "$(printf 'Result=success\nExecMainExitTimestamp=\n' | backup_result)" = 'never run' ]
  [ "$(printf 'Result=success\nExecMainExitTimestamp=Tue 2026-10-13 03:12:00 UTC\n' | backup_result)" = success ]
  [ "$(printf 'ExecMainExitTimestamp=Tue 2026-10-13 03:12:00 UTC\nResult=exit-code\n' | backup_result)" = 'failed (exit-code)' ]
}

# ---- Whole blocks --------------------------------------------------------------------------------

@test "status: an app with two processes, one failed, a strict health path and a backup" {
  local cur prev
  app node_app node-app.localhost 3002 node_app
  prev=$(release node_app 20261012T080000Z-1111111 'PROCESS_web="node server.js"')
  cur=$(release node_app 20261013T093005Z-abc1234 'PROCESS_web="node server.js"' \
    'PROCESS_worker="node worker.js"' 'HEALTH_PATH=/health')
  ln -s "$cur" "$SHIPIT_OPT/node_app/current"
  ln -s "$prev" "$SHIPIT_OPT/node_app/previous"
  state node_app@web.service active
  state node_app@worker.service failed
  mkdir -p "$LOG_ROOT/node_app" "$BACKUP_ROOT/node_app"
  printf 'old line\n2026-10-13T09:30:40Z node_app abc1234 root deployed\n' >"$LOG_ROOT/node_app/deploy.log"
  touch "$BACKUP_ROOT/node_app/node_app-20261012T030000Z.dump" "$BACKUP_ROOT/node_app/node_app-20261013T030000Z.dump"
  printf 'Result=exit-code\nExecMainExitTimestamp=Tue 2026-10-13 03:12:00 UTC\n' >"$BATS_TEST_TMPDIR/show"

  run cmd_status node_app
  [ "$status" -eq 0 ]
  [ "$(sed -n 1,9p <<<"$output")" = 'node_app
  site       https://node-app.localhost (port 3002)
  current    abc1234 (2026-10-13 09:30:05 UTC)
  previous   1111111 (2026-10-12 08:00:00 UTC)
  web        active
  worker     FAILED. See: sudo shipit logs node_app worker, or systemctl status node_app@worker
  health     /health answered 200 (healthy)
  deploy.log 2026-10-13T09:30:40Z node_app abc1234 root deployed
  backup     node_app-20261013T030000Z.dump (last run: failed (exit-code))' ]
  grep -q -- "-H Host: node-app.localhost http://127.0.0.1:3002/health" "$BATS_TEST_TMPDIR/curl.calls"
  grep -qx 'show -p Result -p ExecMainExitTimestamp shipit-backup@node_app.service' "$BATS_TEST_TMPDIR/systemctl.calls"
  [[ $output == *"Caddy: $CADDYFILE is valid."* ]]
  [[ $output == *"Backups are in $BACKUP_ROOT/<app>/, on this VPS's own disk"* ]]
}

@test "status: a zero-config app with no deploy yet, no previous, no database" {
  app next_app next-app.localhost 3001
  run cmd_status next_app
  [ "$status" -eq 0 ]
  [ "$(sed -n 1,6p <<<"$output")" = 'next_app
  site       https://next-app.localhost (port 3001)
  current    none yet. Deploy it with: sudo shipit deploy next_app
  previous   none
  deploy.log none yet
  backup     none (BACKUP=none: next_app has no backups)' ]
  [ ! -e "$BATS_TEST_TMPDIR/curl.calls" ]
}

@test "status: a zero-config release runs web and checks / leniently; no backup yet" {
  local cur
  app next_app next-app.localhost 3001 next_app
  cur=$(release next_app 20261013T093005Z-abc1234)
  ln -s "$cur" "$SHIPIT_OPT/next_app/current"
  stub curl 'printf 000'
  run cmd_status
  [ "$status" -eq 0 ]
  [[ $output == *'  web        INACTIVE. See: sudo shipit logs next_app web'* ]]
  [[ $output == *'  health     / got no answer (UNHEALTHY)'* ]]
  [[ $output == *'  backup     none yet (last run: never run)'* ]]
}

@test "status: BACKUP=state reports the newest archive and the state unit's last run" {
  write_app_conf st REPO=x BRANCH=main DOMAIN=st.localhost PORT=3004 DATABASE= BACKUP=state
  mkdir -p "$BACKUP_ROOT/st"
  touch "$BACKUP_ROOT/st/st-20261012T030000Z.tar.gz" "$BACKUP_ROOT/st/st-20261013T030000Z.tar.gz" \
    "$BACKUP_ROOT/st/st-20261014T030000Z.dump"
  printf 'Result=success\nExecMainExitTimestamp=Tue 2026-10-13 03:12:00 UTC\n' >"$BATS_TEST_TMPDIR/show"
  run cmd_status st
  [ "$status" -eq 0 ]
  [[ $output == *$'\n  backup     st-20261013T030000Z.tar.gz (last run: success)\n'* ]]
  grep -qx 'show -p Result -p ExecMainExitTimestamp shipit-state-backup@st.service' "$BATS_TEST_TMPDIR/systemctl.calls"
}

@test "status: BACKUP=none says so plainly, even with a DATABASE; a bad BACKUP is a config problem" {
  app db_a db-a.localhost 3005 db_a
  printf 'BACKUP=none\n' >>"$SHIPIT_ETC/apps/db_a.conf"
  run cmd_status db_a
  [ "$status" -eq 0 ]
  [[ $output == *$'\n  backup     none (BACKUP=none: db_a has no backups)\n'* ]]
  if grep -qs 'shipit-backup@db_a' "$BATS_TEST_TMPDIR/systemctl.calls"; then return 1; fi
  printf 'BACKUP=sqlite\n' >>"$SHIPIT_ETC/apps/db_a.conf"
  run cmd_status db_a
  [ "$status" -eq 0 ]
  [[ $output == *"  config     $SHIPIT_ETC/apps/db_a.conf has a problem"* ]]
}

@test "status: without an app, every app in name order; a bad config doesn't stop the others" {
  app b_app b.localhost 3002
  app a_app a.localhost 3001
  write_app_conf c_app DOMAIN=a.localhost PORT=3003
  run --separate-stderr cmd_status
  [ "$status" -eq 0 ]
  [ "$(grep -E '^[a-z]' <<<"$output" | head -n 3)" = $'a_app\nb_app\nc_app' ]
  [[ $output == *"  config     $SHIPIT_ETC/apps/c_app.conf has a problem"* ]]
  [[ $stderr == *"already used by the app a_app"* ]]
  [ "$(grep -c '^Caddy:' <<<"$output")" = 1 ]
}

@test "status: a deploy.conf root can't read is reported, not fatal" {
  local cur
  app a_app a.localhost 3001
  cur=$(release a_app 20261013T093005Z-abc1234 'HEALTH_PATH=$(id)' 'PROCESS_web="x"')
  ln -s "$cur" "$SHIPIT_OPT/a_app/current"
  run cmd_status a_app
  [ "$status" -eq 0 ]
  [[ $output == *"  processes  unknown: the current release's deploy.conf can't be read"* ]]
  [[ $output == *'  deploy.log none yet'* ]]
}

@test "status: an invalid Caddyfile is reported with caddy's last line" {
  stub caddy 'echo "some log line" >&2; echo "Error: adapting config: bad thing" >&2; exit 1'
  run cmd_status
  [ "$status" -eq 0 ]
  [[ $output == *"No apps yet."* ]]
  [[ $output == *"Caddy: $CADDYFILE is INVALID: Error: adapting config: bad thing"* ]]
}

@test "status: refuses a bad or unknown app name, and extra arguments" {
  run cmd_status Bad-Name
  [ "$status" -eq 1 ]
  run cmd_status nope
  [ "$status" -eq 1 ]
  [ "$output" = "There's no app named nope." ]
  run cmd_status a b
  [ "$status" -eq 1 ]
  [[ $output == Usage:* ]]
}

@test "status: takes no lock and writes nothing" {
  app a_app a.localhost 3001
  run cmd_status a_app
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$SHIPIT_VAR")" ]
  [ ! -e "$LOG_ROOT/a_app" ]
}
