#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2034,SC2030,SC2031,SC2153,SC2154 # single-quoted stub bodies; tests set lib variables, each in its own @test subshell; deploy_helpers.bash sets calls, remote...
# lib/delete.sh (plan §5.6): arguments, the confirmation and its refusals, then whole deletes of static
# and node sites in deploy.bats's temp root (deploy_helpers.bash): a real deploy, then a delete.

bats_require_minimum_version 1.5.0

setup_file() {
  load deploy_helpers
  deploy_setup_file
}

setup() {
  load helpers
  load deploy_helpers
  deploy_setup
  # shellcheck source=lib/delete.sh
  . "$REPO_ROOT/lib/delete.sh"
  STATE_ROOT=$BATS_TEST_TMPDIR/state CACHE_ROOT=$BATS_TEST_TMPDIR/cache
  mkdir -p "$STATE_ROOT" "$CACHE_ROOT"
}

teardown() {
  touch "$BATS_TEST_TMPDIR/release"
  wait || true
}

# deployed [shipit.ini]: a host with blog deployed (static by default), the calls log emptied, and
# userdel and pkill stubbed: userdel drops the user from the fake passwd.
deployed() {
  host
  [ -z "${1-}" ] || put_ini "$1"
  run cmd_deploy https://github.com/me/blog blog
  [ "$status" -eq 0 ] || {
    echo "$output"
    return 1
  }
  stub pkill 'echo "pkill $*" >>"$STUB_CALLS"'
  stub userdel 'echo "userdel $*" >>"$STUB_CALLS"; grep -v "^$1:" "$STUB_PASSWD" >"$STUB_PASSWD.t"; cat "$STUB_PASSWD.t" >"$STUB_PASSWD"'
  : >"$calls"
}

# untouched: the site is all still there.
untouched() {
  [ -e "$SHIPIT_ETC/sites/blog.conf" ]
  [ -d "$SRV_ROOT/blog/releases" ]
  [ -e "$CADDY_ETC/sites/blog.caddy" ]
  [ ! -s "$calls" ]
}

# ---- Arguments and refusals ----------------------------------------------------------------------

@test "delete_args takes exactly one valid site name" {
  delete_args blog
  [ "$SITE" = blog ]
  run --separate-stderr delete_args
  [ "$status" -eq 1 ]
  [ "$stderr" = "$DELETE_USAGE" ]
  run --separate-stderr delete_args blog extra
  [ "$stderr" = "$DELETE_USAGE" ]
  run --separate-stderr delete_args Blog
  [ "$status" -eq 1 ]
  [[ $stderr == "Invalid site name 'Blog'"* ]]
  run ! delete_args ../x
}

@test "delete of an unknown site is refused without asking" {
  host
  run --separate-stderr cmd_delete blog <<<blog
  [ "$status" -eq 1 ]
  [ "$stderr" = "There's no site named blog. Deploy it first with: shipit deploy <repo-url> blog" ]
  [ ! -e "$SHIPIT_VAR/blog.lock" ]
  [ ! -s "$calls" ]
}

@test "with no answer (no terminal), nothing is deleted" {
  deployed
  run --separate-stderr cmd_delete blog </dev/null
  [ "$status" -eq 1 ]
  [ "${stderr_lines[0]}" = "This deletes the site blog (blog.example.com): its releases, repo, shipit.ini, env file, Caddy file, unit, cache and logs, and the users blog and blog-build. It can't be undone." ]
  [ "${stderr_lines[-1]}" = "Nothing was deleted: there was no answer. Run it in a terminal (ssh -t), or pipe the name: echo blog | shipit delete blog" ]
  untouched
}

@test "an answer other than the site's name deletes nothing" {
  deployed
  for answer in yes y Blog '' ' blog' 'blog '; do
    run --separate-stderr cmd_delete blog <<<"$answer"
    [ "$status" -eq 1 ]
    [ "${stderr_lines[-1]}" = "Type blog to delete it: Nothing was deleted: the answer wasn't blog." ] || {
      echo "$answer: $stderr"
      return 1
    }
  done
  untouched
}

# ---- Whole deletes -------------------------------------------------------------------------------

@test "delete of a static site removes everything shipit made for it, conf last; the lock file stays" {
  deployed
  printf 'TOKEN=x\n' >"$SHIPIT_ETC/sites/blog.env"
  other=$CADDY_ETC/sites/other.caddy
  echo '# managed by shipit' >"$other"
  run --separate-stderr cmd_delete blog <<<blog
  [ "$status" -eq 0 ] || {
    echo "$stderr"
    return 1
  }
  [ "${lines[-1]}" = "Deleted blog." ]
  for path in "$SRV_ROOT/blog" "$CADDY_ETC/sites/blog.caddy" "$LOG_ROOT/blog" \
    "$SHIPIT_ETC/sites/blog.conf" "$SHIPIT_ETC/sites/blog.env"; do
    [ ! -e "$path" ] || {
      echo "still there: $path"
      return 1
    }
  done
  [ -e "$other" ]
  [ -e "$SHIPIT_VAR/blog.lock" ]
  [ ! -s "$passwd" ]
  # The Caddy reload, the processes, then the build user before the site user (its group).
  diff "$calls" - <<'EOF'
systemctl reload caddy
pkill -KILL -u blog-build
pkill -KILL -u blog
userdel blog-build
userdel blog
EOF
}

@test "delete of a node site stops and removes the unit, and deletes its data and cache" {
  deployed "$(node_ini 'node server.js')"$'\n[data]\n\tdir = uploads'
  # systemd makes these when the unit starts.
  mkdir -p "$STATE_ROOT/shipit-blog/uploads" "$CACHE_ROOT/shipit-blog"
  run --separate-stderr cmd_delete blog <<<blog
  [ "$status" -eq 0 ] || {
    echo "$stderr"
    return 1
  }
  [ "${stderr_lines[0]}" = "This deletes the site blog (blog.example.com): its releases, repo, shipit.ini, env file, Caddy file, unit, cache and logs, and the users blog and blog-build, and its data in $STATE_ROOT/shipit-blog. It can't be undone, and shipit keeps no backup: copy the data first if you may need it." ]
  [ ! -e "$SYSTEMD_DIR/shipit-blog.service" ]
  [ ! -e "$STATE_ROOT/shipit-blog" ]
  [ ! -e "$CACHE_ROOT/shipit-blog" ]
  diff <(grep '^systemctl' "$calls") - <<'EOF'
systemctl reload caddy
systemctl stop shipit-blog
systemctl disable --quiet shipit-blog
systemctl daemon-reload
EOF
}

@test "files and users shipit didn't make are left alone, and said so" {
  deployed "$(node_ini 'node server.js')"
  echo '[Service]' >"$SYSTEMD_DIR/shipit-blog.service"
  echo 'blog.example.com' >"$CADDY_ETC/sites/blog.caddy"
  sed -i.bak 's/^blog:\(.*\):shipit site blog:/blog:\1:someone:/' "$passwd"
  run --separate-stderr cmd_delete blog <<<blog
  [ "$status" -eq 0 ]
  [[ $stderr == *"$CADDY_ETC/sites/blog.caddy wasn't written by shipit, so it was left alone."* ]]
  [[ $stderr == *"$SYSTEMD_DIR/shipit-blog.service wasn't written by shipit, so it was left alone."* ]]
  [[ $stderr == *"The user blog wasn't created by shipit, so it was left alone."* ]]
  [ -e "$SYSTEMD_DIR/shipit-blog.service" ]
  [ -e "$CADDY_ETC/sites/blog.caddy" ]
  [ "$(grep -c '^userdel' "$calls")" -eq 1 ]
  run ! grep -q '^systemctl' "$calls"
}

@test "a site with a deploy key is reminded to remove it from GitHub" {
  deployed
  mkdir -p "$SRV_ROOT/blog/.ssh"
  : >"$SRV_ROOT/blog/.ssh/id_ed25519"
  run cmd_delete blog <<<blog
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "Remove its deploy key from GitHub too: https://github.com/me/blog/settings/keys" ]
}

@test "a delete that stopped half-way finishes when run again" {
  deployed
  # As if a delete had stopped after removing the folders: the conf and the users are still there.
  rm -rf "${SRV_ROOT:?}/blog" "$CADDY_ETC/sites/blog.caddy"
  run cmd_delete blog <<<blog
  [ "$status" -eq 0 ]
  [ ! -e "$SHIPIT_ETC/sites/blog.conf" ]
  [ ! -s "$passwd" ]
  run ! grep -q '^systemctl' "$calls"
}

@test "delete waits for a deploy or rollback holding the site lock" {
  deployed
  flock "$SHIPIT_VAR/blog.lock" bash -c "touch '$BATS_TEST_TMPDIR/held'; while [ ! -e '$BATS_TEST_TMPDIR/release' ]; do sleep 0.1; done" &
  while [ ! -e "$BATS_TEST_TMPDIR/held" ]; do sleep 0.1; done
  cmd_delete blog <<<blog >"$BATS_TEST_TMPDIR/out" 2>&1 &
  pid=$!
  sleep 0.5
  # Still waiting: nothing deleted yet.
  [ -d "$SRV_ROOT/blog/releases" ]
  touch "$BATS_TEST_TMPDIR/release"
  wait "$pid"
  grep -q 'Another deploy or rollback of blog is running; waiting.' "$BATS_TEST_TMPDIR/out"
  [ ! -e "$SRV_ROOT/blog" ]
}
