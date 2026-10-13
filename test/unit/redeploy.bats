#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031,SC2034 # single-quoted stub bodies; tests set lib variables
# Redeploys and rollback (S5): --ref, idempotent rendering and config changes, stale instances, the
# app lock, HEALTH_FAIL and lib/rollback.sh.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  load_common
  # shellcheck source=lib/rollback.sh
  . "$REPO_ROOT/lib/rollback.sh"
  # shellcheck disable=SC2329 # called by the functions under test
  as_deployer() { (cd / && env -i HOME="$HOME" PATH="$PATH" "$@"); }
  APP=tracklite
  DOMAIN=tracklite.example.com
  PORT=3001
  LOG_REDACT_QUERY=''
  SHIPIT_OPT=$BATS_TEST_TMPDIR/opt
  SYSTEMD_DIR=$BATS_TEST_TMPDIR/systemd
  LOG_ROOT=$BATS_TEST_TMPDIR/log
  DEPLOY_TMP=$BATS_TEST_TMPDIR/tmp
  opt=$SHIPIT_OPT/$APP
  mkdir -p "$DEPLOY_TMP" "$SYSTEMD_DIR" "$LOG_ROOT/$APP" "$opt/releases"
}

teardown() {
  touch "$BATS_TEST_TMPDIR/release"
  wait || true
}

need_envsubst() { command -v envsubst >/dev/null || skip "envsubst (gettext-base) isn't installed"; }
need_flock() { command -v flock >/dev/null || skip "flock (util-linux) isn't installed"; }

# atomic_mv: the switch uses GNU mv -T. Where mv has no -T (macOS), a stub does the same rename(2).
atomic_mv() {
  local d=$BATS_TEST_TMPDIR/mvcheck
  mkdir -p "$d"
  ln -s / "$d/a"
  mv -T "$d/a" "$d/b" 2>/dev/null && return 0
  command -v perl >/dev/null || skip "mv has no -T and perl isn't installed"
  stub mv '[ "$1" = -T ] && shift; exec perl -e '\''rename($ARGV[0], $ARGV[1]) or die "mv: $!\n"'\'' "$@"'
  hash -r
}

# release <name> [deploy.conf lines...]: a release folder, with a deploy.conf when lines are given.
release() {
  local dir=$opt/releases/$1
  shift
  mkdir -p "$dir"
  [ "$#" -eq 0 ] || printf '%s\n' "$@" >"$dir/deploy.conf"
  printf '%s\n' "$dir"
}

# hold_lock <path>: holds the lock in a background process until the test ends.
hold_lock() {
  flock "$1" bash -c "touch '$BATS_TEST_TMPDIR/held'; while [ ! -e '$BATS_TEST_TMPDIR/release' ]; do sleep 0.1; done" &
  while [ ! -e "$BATS_TEST_TMPDIR/held" ]; do sleep 0.1; done
}

# fake_systemd: systemctl and systemd-analyze stubs. systemctl logs its calls to systemctl.calls and
# lists the instances in $BATS_TEST_TMPDIR/units.
fake_systemd() {
  : >"$BATS_TEST_TMPDIR/units"
  stub systemctl 'echo "$*" >>"'"$BATS_TEST_TMPDIR"'/systemctl.calls"
[ "$1" != list-units ] || cat "'"$BATS_TEST_TMPDIR"'/units"'
  stub systemd-analyze 'exit 0'
}

# ---- --ref (D1) ----------------------------------------------------------------------------------

# git_repo: a work repo with three commits on main and one on a side branch. Sets first, second, tip
# and side.
git_repo() {
  work=$BATS_TEST_TMPDIR/work
  git init -q -b main "$work"
  commit() { git -C "$work" -c user.name=t -c user.email=t@localhost commit -q --allow-empty -m "$1"; }
  commit one
  first=$(git -C "$work" rev-parse HEAD)
  commit two
  second=$(git -C "$work" rev-parse HEAD)
  git -C "$work" checkout -q -b side
  commit side
  side=$(git -C "$work" rev-parse HEAD)
  git -C "$work" checkout -q main
  commit three
  tip=$(git -C "$work" rev-parse HEAD)
}

fetch_ref() {
  bash -c "$FETCH_SCRIPT" fetch "$BATS_TEST_TMPDIR/bare" "file://$work" main "$1"
}

@test "--ref: without one, the branch's tip" {
  command -v git >/dev/null || skip "git isn't installed"
  git_repo
  run fetch_ref ''
  [ "$status" -eq 0 ]
  [ "$output" = "$tip" ]
}

@test "--ref: a commit the branch contains resolves to its full sha, short or long" {
  command -v git >/dev/null || skip "git isn't installed"
  git_repo
  run fetch_ref "${second:0:7}"
  [ "$status" -eq 0 ]
  [ "$output" = "$second" ]
  run fetch_ref "$first"
  [ "$output" = "$first" ]
  run fetch_ref "${tip:0:7}"
  [ "$output" = "$tip" ]
}

@test "--ref: a commit only another branch has, or an unknown one, exits 3" {
  command -v git >/dev/null || skip "git isn't installed"
  git_repo
  # Fetch side once, so its commit is in the bare repo's objects; it's still not on main.
  bash -c "$FETCH_SCRIPT" fetch "$BATS_TEST_TMPDIR/bare" "file://$work" side ''
  run fetch_ref "${side:0:7}"
  [ "$status" -eq 3 ]
  run fetch_ref deadbeef
  [ "$status" -eq 3 ]
}

@test "--ref: a failed fetch is told apart from a ref that isn't on the branch" {
  run bash -c "$FETCH_SCRIPT" fetch "$BATS_TEST_TMPDIR/bare" "file://$BATS_TEST_TMPDIR/missing" main abc1234
  [ "$status" -ne 0 ]
  [ "$status" -ne 3 ]
}

# fetch_with <exit status> <output>: runs deploy_fetch with deployer's git stubbed.
fetch_with() {
  REF=abc1234
  BRANCH=main
  REPO=file:///srv/git/a.git
  BUILD_LOG=$BATS_TEST_TMPDIR/build.log
  eval "as_deployer() { echo $2; return $1; }"
  deploy_fetch
}

@test "--ref: deploy refuses a ref the branch doesn't contain, and names it" {
  run --separate-stderr fetch_with 3 ''
  [ "$status" -eq 1 ]
  [ "$stderr" = "abc1234 isn't a commit on main, so it can't be deployed. Only commits the branch contains ship." ]
  run --separate-stderr fetch_with 128 ''
  [ "$status" -eq 1 ]
  [[ $stderr == "Fetching main from file:///srv/git/a.git failed."* ]]
}

# ---- Idempotent rendering and config changes (D7) ------------------------------------------------

# install_all: renders the unit, target and site and installs each through install_if_changed,
# printing the files that changed.
install_all() {
  local t=$BATS_TEST_TMPDIR/rendered f
  mkdir -p "$t"
  render_service >"$t/$APP@.service"
  render_target web worker >"$t/$APP.target"
  render_site >"$t/$APP.caddy"
  for f in "$APP@.service" "$APP.target" "$APP.caddy"; do
    if install_if_changed "$t/$f" "$SYSTEMD_DIR/$f" 644; then echo "$f"; fi
  done
}

@test "rendering twice changes nothing the second time" {
  need_envsubst
  run install_all
  [ "${#lines[@]}" = 3 ]
  run install_all
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "config changes: each edited value changes only the files that use it" {
  need_envsubst
  install_all >/dev/null
  DOMAIN=new.example.com
  run install_all
  [ "$output" = tracklite.caddy ]
  PORT=3050
  run install_all
  [ "$output" = $'tracklite@.service\ntracklite.caddy' ]
  grep -qx 'Environment=NODE_ENV=production PORT=3050' "$SYSTEMD_DIR/tracklite@.service"
  LOG_REDACT_QUERY=token
  run install_all
  [ "$output" = tracklite.caddy ]
  grep -q 'delete token' "$SYSTEMD_DIR/tracklite.caddy"
  run install_all
  [ -z "$output" ]
}

# ---- Stale instances (D9) ------------------------------------------------------------------------

@test "stale instances: the app's instances the release doesn't list" {
  run stale_instances tracklite web worker <<'EOF'
tracklite@web.service loaded active running tracklite web
tracklite@worker.service loaded active running tracklite worker
tracklite@extra.service loaded active running tracklite extra
tracklite@old.service loaded failed failed tracklite old
tracklite2@web.service loaded active running other app
tracklite@web.socket loaded active running not a service
EOF
  [ "$status" -eq 0 ]
  [ "$output" = $'tracklite@extra.service\ntracklite@old.service' ]
  run stale_instances tracklite web worker extra old </dev/null
  [ -z "$output" ]
}

@test "restart: stops the instances the release doesn't list, then restarts the target" {
  fake_systemd
  printf '%s\n' 'tracklite@web.service loaded active running x' 'tracklite@extra.service loaded active running x' \
    >"$BATS_TEST_TMPDIR/units"
  PROCESSES=(web)
  run deploy_restart
  [ "$status" -eq 0 ]
  [ "$output" = "Stopped tracklite@extra.service: this release doesn't run it." ]
  [ "$(grep -v '^list-units' "$BATS_TEST_TMPDIR/systemctl.calls")" = $'stop tracklite@extra.service\nrestart tracklite.target' ]
}

# ---- The app lock (B) ----------------------------------------------------------------------------

@test "lock: a second deploy of the app exits with the lock message" {
  need_flock
  printf 'MIN_FREE_DISK_GB=1\n' >"$SHIPIT_ETC/host.conf"
  hold_lock "$SHIPIT_VAR/$APP.lock"
  run --separate-stderr deploy_guards
  [ "$status" -eq 1 ]
  [ "$stderr" = "Another deploy or rollback of tracklite is running." ]
}

@test "lock: a rollback while a deploy runs exits with the lock message" {
  need_flock
  write_app_conf "$APP" "DOMAIN=$DOMAIN" "PORT=$PORT"
  hold_lock "$SHIPIT_VAR/$APP.lock"
  run --separate-stderr cmd_rollback "$APP"
  [ "$status" -eq 1 ]
  [ "$stderr" = "Another deploy or rollback of tracklite is running." ]
}

# ---- HEALTH_FAIL (D11) ---------------------------------------------------------------------------

# unhealthy_deploy <HEALTH_FAIL>: runs D11 with the health check answering 308 until switch_back runs.
unhealthy_deploy() {
  HEALTH_FAIL=$1
  DEPLOY_SHA=bbbbbbb
  HEALTH_PATH=/health
  # shellcheck disable=SC2329 # called by deploy_health
  health_wait() {
    HEALTH_CODE=308
    [ -n "${back-}" ]
  }
  # shellcheck disable=SC2329 # called by deploy_health
  switch_back() {
    back=$1
    echo "switch_back ${1##*/}"
  }
  deploy_health
}

@test "HEALTH_FAIL=report: says how to switch back, and doesn't" {
  ln -s "$(release 20260101T000000Z-aaaaaaa)" "$opt/previous"
  run --separate-stderr unhealthy_deploy report
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "Deployed bbbbbbb, but /health answered 308. Switch back with: sudo shipit rollback tracklite" ]
}

@test "HEALTH_FAIL=rollback: switches back to previous and says the database keeps the migrations" {
  ln -s "$(release 20260101T000000Z-aaaaaaa)" "$opt/previous"
  run --separate-stderr unhealthy_deploy rollback
  [ "$status" -eq 1 ]
  [ "$output" = "switch_back 20260101T000000Z-aaaaaaa" ]
  [ "$stderr" = $'Deployed bbbbbbb, but /health answered 308. Rolling back to 20260101T000000Z-aaaaaaa, because HEALTH_FAIL=rollback.\nRolled back to 20260101T000000Z-aaaaaaa; the database keeps bbbbbbb\'s migrations.' ]
}

@test "HEALTH_FAIL=rollback: with no previous release, it reports" {
  run --separate-stderr unhealthy_deploy rollback
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = $'There\'s no previous release to roll back to.\nDeployed bbbbbbb, but /health answered 308. Switch back with: sudo shipit rollback tracklite' ]
}

@test "health: a healthy deploy says Deployed" {
  health_wait() { HEALTH_CODE=200; }
  run deploy_health
  [ "$status" -eq 0 ]
  [ "$output" = "Deployed $DEPLOY_SHA. https://tracklite.example.com" ]
}

# ---- Rollback ------------------------------------------------------------------------------------

@test "rollback: usage, and an unknown app" {
  run --separate-stderr cmd_rollback
  [ "$stderr" = "Usage: sudo shipit rollback <app>" ]
  run --separate-stderr cmd_rollback a b
  [ "$stderr" = "Usage: sudo shipit rollback <app>" ]
  run --separate-stderr cmd_rollback Bad.Name
  [ "$status" -eq 1 ]
  [[ $stderr == "Invalid app name"* ]]
  run --separate-stderr cmd_rollback nope
  [ "$stderr" = "There's no app named nope." ]
}

@test "rollback: refuses without a previous release, and logs it" {
  need_flock
  write_app_conf "$APP" "DOMAIN=$DOMAIN" "PORT=$PORT"
  ln -s "$(release 20260102T000000Z-bbbbbbb)" "$opt/current"
  run --separate-stderr cmd_rollback "$APP"
  [ "$status" -eq 1 ]
  [ "$stderr" = "No previous release to roll back to." ]
  # previous pointing at a deleted release is refused too.
  ln -s "$opt/releases/gone" "$opt/previous"
  run --separate-stderr cmd_rollback "$APP"
  [ "$stderr" = "No previous release to roll back to." ]
  [ "$(readlink "$opt/current")" = "$opt/releases/20260102T000000Z-bbbbbbb" ]
  grep -Eq "^[0-9TZ:-]+ tracklite - [a-z]+ failed$" "$LOG_ROOT/$APP/deploy.log"
}

@test "switch: current points at the release, previous is removed" {
  atomic_mv
  local old new
  old=$(release 20260101T000000Z-aaaaaaa)
  new=$(release 20260102T000000Z-bbbbbbb)
  ln -s "$new" "$opt/current"
  ln -s "$old" "$opt/previous"
  switch_links "$old"
  [ "$(readlink "$opt/current")" = "$old" ]
  [ ! -e "$opt/previous" ] && [ ! -L "$opt/previous" ]
  [ ! -e "$opt/current.new" ] && [ ! -L "$opt/current.new" ]
  [ -d "$new" ]
}

# rollback_setup <health status>: two releases, the installed units and stubs for cmd_rollback. The
# previous release has only web; the current one also has worker.
rollback_setup() {
  need_envsubst
  need_flock
  atomic_mv
  fake_systemd
  write_app_conf "$APP" "DOMAIN=$DOMAIN" "PORT=$PORT"
  local old new
  old=$(release 20260101T000000Z-aaaaaaa 'PROCESS_web="node server.js"' 'HEALTH_PATH=/health')
  new=$(release 20260102T000000Z-bbbbbbb 'PROCESS_web="node server.js"' 'PROCESS_worker="node worker.js"')
  ln -s "$new" "$opt/current"
  ln -s "$old" "$opt/previous"
  render_service >"$SYSTEMD_DIR/$APP@.service"
  render_target web worker >"$SYSTEMD_DIR/$APP.target"
  printf '%s\n' 'tracklite@web.service loaded active running x' 'tracklite@worker.service loaded active running x' \
    >"$BATS_TEST_TMPDIR/units"
  stub curl 'echo "$*" >>"'"$BATS_TEST_TMPDIR"'/curl.calls"; printf '"$1"
  HEALTH_TIMEOUT=0
}

@test "rollback: switches back, re-renders the target, stops what the release doesn't run" {
  rollback_setup 200
  run cmd_rollback "$APP"
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]} - 1]}" = "Rolled back to 20260101T000000Z-aaaaaaa; the database keeps bbbbbbb's migrations." ]
  [ "$(readlink "$opt/current")" = "$opt/releases/20260101T000000Z-aaaaaaa" ]
  [ ! -L "$opt/previous" ]
  [ -d "$opt/releases/20260102T000000Z-bbbbbbb" ]
  grep -qx 'Wants=tracklite@web.service' "$SYSTEMD_DIR/$APP.target"
  [ "$(grep -v '^list-units' "$BATS_TEST_TMPDIR/systemctl.calls")" \
    = $'daemon-reload\nstop tracklite@worker.service\nrestart tracklite.target' ]
  # The previous release's HEALTH_PATH, with the app's domain.
  grep -q -- "-H Host: tracklite.example.com http://127.0.0.1:3001/health" "$BATS_TEST_TMPDIR/curl.calls"
  grep -Eq "^[0-9TZ:-]+ tracklite aaaaaaa [a-z]+ rolled-back$" "$LOG_ROOT/$APP/deploy.log"
  # A second rollback has nothing to go back to.
  run --separate-stderr cmd_rollback "$APP"
  [ "$status" -eq 1 ]
  [ "$stderr" = "No previous release to roll back to." ]
}

@test "rollback: an unhealthy previous release is still switched to, and reported" {
  rollback_setup 308
  run --separate-stderr cmd_rollback "$APP"
  [ "$status" -eq 1 ]
  [ "$(readlink "$opt/current")" = "$opt/releases/20260101T000000Z-aaaaaaa" ]
  [[ $stderr == *"But /health answered 308."* ]]
  grep -Eq " rolled-back-unhealthy$" "$LOG_ROOT/$APP/deploy.log"
}

@test "rollback: a release without deploy.conf gets the zero-config web process" {
  need_envsubst
  fake_systemd
  release 20260101T000000Z-aaaaaaa >/dev/null
  render_service >"$SYSTEMD_DIR/$APP@.service"
  render_target web worker >"$SYSTEMD_DIR/$APP.target"
  atomic_mv
  run switch_back "$opt/releases/20260101T000000Z-aaaaaaa"
  [ "$status" -eq 0 ]
  grep -qx 'Wants=tracklite@web.service' "$SYSTEMD_DIR/$APP.target"
}
