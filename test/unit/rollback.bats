#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2034,SC2030,SC2031,SC2153,SC2154 # single-quoted stub bodies; tests set lib variables, each in its own @test subshell; deploy_helpers.bash sets calls, remote, golden...
# lib/rollback.sh (plan §5.3): arguments and refusals, then whole rollbacks of static, node and Next.js
# sites in deploy.bats's temp root (deploy_helpers.bash): two real deploys, then a rollback.

bats_require_minimum_version 1.5.0

setup_file() {
  load deploy_helpers
  deploy_setup_file
}

setup() {
  load helpers
  load deploy_helpers
  deploy_setup
  # shellcheck source=lib/rollback.sh
  . "$REPO_ROOT/lib/rollback.sh"
}

teardown() {
  touch "$BATS_TEST_TMPDIR/release"
  wait || true
}

# deploy_ok <deploy args>: runs a deploy that must succeed.
deploy_ok() {
  run cmd_deploy "$@"
  [ "$status" -eq 0 ] || {
    echo "$output"
    return 1
  }
}

# static_releases: rel1 was deployed serving out/ without aliases; rel2 (current) serves dist/ with an
# alias. The server's shipit.ini is what rel2's deploy used, and it is all rollback has: it doesn't read it.
static_releases() {
  host
  put_ini "$(ini blog.example.com | sed 's/root = dist/root = out/')"
  commit out/index.html v1 >/dev/null
  deploy_ok https://github.com/me/blog blog
  rel1=$(current)
  put_ini "$(ini blog.example.com 'alias = www.blog.example.com')"
  commit dist/index.html v2 >/dev/null
  deploy_ok blog
  rel2=$(current)
}

# node_releases: rel1 was deployed running node v1.js without data; rel2 (current) runs node v2.js with
# data.dir uploads, which is what the unit now holds.
node_releases() {
  host
  put_ini "$(node_ini 'node v1.js')"
  deploy_ok https://github.com/me/blog blog
  rel1=$(current)
  put_ini "$(node_ini 'node v2.js')"$'\n[data]\n\tdir = uploads'
  deploy_ok blog
  rel2=$(current)
}

# ---- Arguments and refusals ----------------------------------------------------------------------

@test "rollback_args takes exactly one valid site name" {
  rollback_args blog
  [ "$SITE" = blog ]
  run --separate-stderr rollback_args
  [ "$status" -eq 1 ]
  [ "$stderr" = "$ROLLBACK_USAGE" ]
  run --separate-stderr rollback_args blog extra
  [ "$stderr" = "$ROLLBACK_USAGE" ]
  run --separate-stderr rollback_args Blog
  [ "$status" -eq 1 ]
  [[ $stderr == "Invalid site name 'Blog'"* ]]
  run ! rollback_args ../x
}

@test "rollback of an unknown site is refused" {
  host
  run cmd_rollback blog
  [ "$status" -eq 1 ]
  [ "$output" = "There's no site named blog. Deploy it first with: shipit deploy <repo-url> blog" ]
  [ ! -e "$SHIPIT_VAR/blog.lock" ]
  [ ! -s "$calls" ]
}

@test "rollback of a site whose first deploy never succeeded is refused" {
  host
  printf 'REPO=https://github.com/me/blog\nPORT=3000\n' >"$SHIPIT_ETC/sites/blog.conf"
  run cmd_rollback blog
  [ "$status" -eq 1 ]
  [ "$output" = "blog has never been deployed successfully, so there's nothing to roll back to." ]
}

@test "rollback without a previous release is refused, and changes nothing" {
  host
  deploy_ok https://github.com/me/blog blog
  rel=$(current)
  : >"$calls"
  run cmd_rollback blog
  [ "$status" -eq 1 ]
  [ "$output" = "blog has no previous release to roll back to." ]
  [ "$(current)" = "$rel" ]
  [ ! -e "$SRV_ROOT/blog/previous" ]
  [ ! -s "$calls" ]
  # previous pointing at current (a crash between the two link switches) counts as none.
  ln -s "$rel" "$SRV_ROOT/blog/previous"
  run cmd_rollback blog
  [ "$output" = "blog has no previous release to roll back to." ]
}

# ---- Whole rollbacks -----------------------------------------------------------------------------

@test "rollback of a static site swaps the links and nothing else: no rendering, no reload, config untouched" {
  static_releases
  caddy_before=$(caddy_file) conf_before=$(cat "$SHIPIT_ETC/sites/blog.conf") ini_before=$(cat "$SRV_ROOT/blog/config/shipit.ini")
  : >"$calls"
  run cmd_rollback blog
  [ "$status" -eq 0 ] || {
    echo "$output"
    return 1
  }
  [ "${lines[-1]}" = "Rolled back blog: now serving ${rel1#releases/}." ]
  [ "$(current)" = "$rel1" ]
  [ "$(previous)" = "$rel2" ]
  [ "$(cat "$SRV_ROOT/blog/current/out/index.html")" = v1 ]
  # The Caddy file and the conf are what rel2's deploy wrote (root dist, the alias), not rel1's.
  [ "$(caddy_file)" = "$caddy_before" ]
  grep -qxF $'\troot * /srv/blog/current/dist' <(caddy_file)
  grep -q 'redir https' <(caddy_file)
  [ "$(cat "$SHIPIT_ETC/sites/blog.conf")" = "$conf_before" ]
  grep -qx 'ALIASES=www.blog.example.com' "$SHIPIT_ETC/sites/blog.conf"
  [ "$(cat "$SRV_ROOT/blog/config/shipit.ini")" = "$ini_before" ]
  # Nothing was validated, installed or reloaded, and a static site has no health check.
  [ ! -s "$calls" ]
  [ "$(releases | sort)" = "$(printf '%s\n' "${rel1#releases/}" "${rel2#releases/}" | sort)" ]
}

@test "rolling back twice returns to the original links and config" {
  static_releases
  caddy=$(caddy_file) conf=$(cat "$SHIPIT_ETC/sites/blog.conf")
  run cmd_rollback blog
  [ "$status" -eq 0 ]
  run cmd_rollback blog
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "Rolled back blog: now serving ${rel2#releases/}." ]
  [ "$(current)" = "$rel2" ]
  [ "$(previous)" = "$rel1" ]
  [ "$(caddy_file)" = "$caddy" ]
  [ "$(cat "$SHIPIT_ETC/sites/blog.conf")" = "$conf" ]
  grep -qx 'ALIASES=www.blog.example.com' "$SHIPIT_ETC/sites/blog.conf"
}

@test "rollback to a release with the same config doesn't reload Caddy" {
  host
  deploy_ok https://github.com/me/blog blog
  commit dist/index.html v2 >/dev/null
  deploy_ok blog
  : >"$calls"
  run cmd_rollback blog
  [ "$status" -eq 0 ]
  [ "$(cat "$SRV_ROOT/blog/current/dist/index.html")" = hello ]
  run ! grep -q '^systemctl' "$calls"
}

@test "rollback of a node site: restart and health check only; the unit keeps what the last deploy wrote" {
  node_releases
  unit_before=$(unit) caddy_before=$(caddy_file) conf_before=$(cat "$SHIPIT_ETC/sites/blog.conf")
  grep -qx 'StateDirectory=shipit-blog shipit-blog/uploads' <(unit)
  : >"$calls"
  run cmd_rollback blog
  [ "$status" -eq 0 ] || {
    echo "$output"
    return 1
  }
  [ "$(current)" = "$rel1" ]
  [ "$(previous)" = "$rel2" ]
  [ "$(unit)" = "$unit_before" ]
  [ "$(caddy_file)" = "$caddy_before" ]
  [ "$(cat "$SHIPIT_ETC/sites/blog.conf")" = "$conf_before" ]
  # No daemon-reload, no enable, no Caddy reload.
  diff <(grep -E '^(systemctl|curl)' "$calls") - <<'EOF'
systemctl restart shipit-blog
curl -s -o /dev/null -w %{http_code} --max-time 5 -H Host: blog.example.com http://127.0.0.1:3000/
EOF
  run ! grep -q 'systemd-analyze\|runuser\|/var/lib\|shipit-blog/' "$calls"
}

@test "rollback works when shipit.ini is invalid or deleted, and doesn't touch it" {
  node_releases
  printf 'this is [not an ini\n' >"$SRV_ROOT/blog/config/shipit.ini"
  run cmd_rollback blog
  [ "$status" -eq 0 ] || {
    echo "$output"
    return 1
  }
  [ "$(current)" = "$rel1" ]
  [ "$(cat "$SRV_ROOT/blog/config/shipit.ini")" = 'this is [not an ini' ]
  rm "$SRV_ROOT/blog/config/shipit.ini"
  run cmd_rollback blog
  [ "$status" -eq 0 ] || {
    echo "$output"
    return 1
  }
  [ "$(current)" = "$rel2" ]
  [ ! -e "$SRV_ROOT/blog/config/shipit.ini" ]
}

@test "rollback's health check polls / on the conf's port with the conf's domain as Host" {
  node_releases
  # What the check uses is the conf, not shipit.ini.
  sed -i.bak 's/^PORT=.*/PORT=3007/; s/^DOMAIN=.*/DOMAIN=conf.example.com/' "$SHIPIT_ETC/sites/blog.conf"
  rm "$SHIPIT_ETC/sites/blog.conf.bak"
  : >"$calls"
  run cmd_rollback blog
  [ "$status" -eq 0 ] || {
    echo "$output"
    return 1
  }
  [ "$(grep '^curl' "$calls")" = 'curl -s -o /dev/null -w %{http_code} --max-time 5 -H Host: conf.example.com http://127.0.0.1:3007/' ]
  [ "${lines[-2]}" = 'http://127.0.0.1:3007/ answered 200.' ]
}

@test "a failed health check swaps back and restarts the original current; both releases kept, config untouched" {
  node_releases
  unit_before=$(unit) caddy_before=$(caddy_file) conf_before=$(cat "$SHIPIT_ETC/sites/blog.conf")
  # rel1 answers 500; once swapped back, rel2 answers 200.
  curl_codes 500 200
  : >"$calls"
  run cmd_rollback blog
  [ "$status" -eq 1 ]
  [ "${lines[-1]}" = "Rollback failed health check; still serving ${rel2#releases/}." ]
  [[ $output == *"answered 500 within 0 s;"* ]]
  [ "$(current)" = "$rel2" ]
  [ "$(previous)" = "$rel1" ]
  [ "$(unit)" = "$unit_before" ]
  [ "$(caddy_file)" = "$caddy_before" ]
  [ "$(cat "$SHIPIT_ETC/sites/blog.conf")" = "$conf_before" ]
  [ "$(releases | sort)" = "$(printf '%s\n' "${rel1#releases/}" "${rel2#releases/}" | sort)" ]
  [ "$(grep -c 'systemctl daemon-reload' "$calls")" -eq 0 ]
  [ "$(grep -c 'systemctl restart shipit-blog' "$calls")" -eq 2 ]
  [ "$(grep -c '^curl' "$calls")" -eq 2 ]
}

@test "if the original current fails to come back too, that's reported and the rollback still fails" {
  node_releases
  curl_codes 500
  run cmd_rollback blog
  [ "$status" -eq 1 ]
  [ "${lines[-2]}" = "${rel2#releases/} didn't come back up either; fix the error above." ]
  [ "${lines[-1]}" = "Rollback failed health check; still serving ${rel2#releases/}." ]
  [ "$(current)" = "$rel2" ]
}

@test "rollback waits for a deploy or rollback holding the site lock" {
  static_releases
  flock "$SHIPIT_VAR/blog.lock" bash -c "touch '$BATS_TEST_TMPDIR/held'; while [ ! -e '$BATS_TEST_TMPDIR/release' ]; do sleep 0.1; done" &
  while [ ! -e "$BATS_TEST_TMPDIR/held" ]; do sleep 0.1; done
  cmd_rollback blog >"$BATS_TEST_TMPDIR/out" 2>&1 &
  rollback=$!
  sleep 0.5
  # Still waiting: nothing switched yet.
  [ "$(current)" = "$rel2" ]
  touch "$BATS_TEST_TMPDIR/release"
  wait "$rollback"
  [ "$(head -n 1 "$BATS_TEST_TMPDIR/out")" = 'Another deploy or rollback of blog is running; waiting.' ]
  [ "$(current)" = "$rel1" ]
}
