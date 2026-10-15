#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2034,SC2030,SC2031,SC2153,SC2154 # single-quoted stub bodies; tests set lib variables, each in its own @test subshell; deploy_helpers.bash sets calls, remote, golden...
# lib/rollback.sh (plan §5.3): arguments and refusals, then whole rollbacks of static, node and Next.js
# sites in deploy.bats's temp root (deploy_helpers.bash): two real deploys, then a rollback.

bats_require_minimum_version 1.5.0

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

# static_releases: rel1 serves out/ without aliases; rel2 (current) serves dist/ with an alias.
static_releases() {
  host
  commit shipit.ini "$(ini blog.example.com | sed 's/root = dist/root = out/')" out/index.html v1 >/dev/null
  deploy_ok https://github.com/me/blog blog
  rel1=$(current)
  commit shipit.ini "$(ini blog.example.com 'alias = www.blog.example.com')" dist/index.html v2 >/dev/null
  deploy_ok blog
  rel2=$(current)
}

# node_releases: rel1 runs node v1.js without data; rel2 (current) runs node v2.js with data.dir uploads.
node_releases() {
  host
  commit shipit.ini "$(node_ini 'node v1.js')" >/dev/null
  deploy_ok https://github.com/me/blog blog
  rel1=$(current)
  commit shipit.ini "$(node_ini 'node v2.js')"$'\n[data]\n\tdir = uploads' >/dev/null
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

@test "rollback of a static site: links swapped, Caddy file and conf from previous's shipit.ini, no restart" {
  static_releases
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
  caddy=$(caddy_file)
  grep -qxF $'\troot * /srv/blog/current/out' <<<"$caddy"
  run ! grep -q 'redir https' <<<"$caddy"
  diff "$SHIPIT_ETC/sites/blog.conf" - <<'EOF'
# managed by shipit (shipit deploy and rollback write this file)
REPO=https://github.com/me/blog
TYPE=static
DOMAIN=blog.example.com
EOF
  # shipit.ini was read from rel1's commit, and the Caddy file validated before it went in.
  grep -qx 'runuser -u caddy' "$calls"
  diff <(grep '^systemctl' "$calls") - <<<'systemctl reload caddy'
  run ! grep -q '^curl' "$calls"
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

@test "rollback of a node site: unit from previous's shipit.ini, daemon-reload, restart, health check" {
  node_releases
  grep -qx 'StateDirectory=shipit-blog shipit-blog/uploads' <(unit)
  : >"$calls"
  run cmd_rollback blog
  [ "$status" -eq 0 ] || {
    echo "$output"
    return 1
  }
  [ "$(current)" = "$rel1" ]
  [ "$(previous)" = "$rel2" ]
  # The data folder added by rel2 is gone from the unit (the folder itself is systemd's, untouched).
  diff <(unit | sed "s|node v1.js|node server.js|") "$golden/site-node.service"
  diff <(grep -E '^(systemctl|curl)' "$calls") - <<'EOF'
systemctl daemon-reload
systemctl enable --quiet shipit-blog
systemctl restart shipit-blog
curl -s -o /dev/null -w %{http_code} --max-time 5 -H Host: blog.example.com http://127.0.0.1:3000/
EOF
  run ! grep -q '/var/lib\|shipit-blog/' "$calls"
  grep -qx PORT=3000 "$SHIPIT_ETC/sites/blog.conf"
}

@test "rollback of a nextjs site: stop, empty the cache, start" {
  host
  commit shipit.ini $'[site]\n\tdomain = blog.example.com\n\ttype = nextjs' >/dev/null
  deploy_ok https://github.com/me/blog blog
  rel1=$(current)
  commit shipit.ini $'[site]\n\tdomain = blog.example.com\n\ttype = nextjs\n\thealth = /api/health' >/dev/null
  deploy_ok blog
  : >"$calls"
  run cmd_rollback blog
  [ "$status" -eq 0 ] || {
    echo "$output"
    return 1
  }
  [ "$(current)" = "$rel1" ]
  diff <(grep -E '^(systemctl (stop|clean|start|restart) |curl)' "$calls") - <<'EOF'
systemctl stop shipit-blog
systemctl clean --what=cache shipit-blog
systemctl start shipit-blog
curl -s -o /dev/null -w %{http_code} --max-time 5 -H Host: blog.example.com http://127.0.0.1:3000/
EOF
}

@test "a failed health check swaps back, re-renders and restarts the original current; both releases kept" {
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
  [ "$(grep -c 'systemctl daemon-reload' "$calls")" -eq 2 ]
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

@test "rollback to a release whose domain now clashes with another site is refused and swapped back" {
  host
  commit shipit.ini "$(ini blog.example.com 'alias = shared.example.com')" >/dev/null
  deploy_ok https://github.com/me/blog blog
  rel1=$(current)
  commit shipit.ini "$(ini blog.example.com)" >/dev/null
  deploy_ok blog
  rel2=$(current)
  caddy_before=$(caddy_file)
  # Since rel1, another site took shared.example.com.
  printf 'REPO=https://github.com/me/other\nTYPE=static\nDOMAIN=shared.example.com\n' >"$SHIPIT_ETC/sites/other.conf"
  : >"$calls"
  run cmd_rollback blog
  [ "$status" -eq 1 ]
  [[ $output == *"The hostname shared.example.com is already used by the site other. Remove it from shipit.ini or from other."* ]]
  [ "${lines[-1]}" = "Rollback failed: the previous release's config couldn't be installed; still serving ${rel2#releases/}." ]
  [ "$(current)" = "$rel2" ]
  [ "$(previous)" = "$rel1" ]
  [ "$(caddy_file)" = "$caddy_before" ]
  run ! grep -q ALIASES "$SHIPIT_ETC/sites/blog.conf"
  run ! grep -q '^systemctl' "$calls"
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

@test "rollback still works after a force-push and git gc: the commit is pinned by refs/shipit/<sha>" {
  static_releases
  repo=$SRV_ROOT/blog/repo.git
  sha1=$(release_sha "${rel1#releases/}")
  # A commit fetched but never deployed: nothing pins it.
  unpinned=$(commit dist/index.html v3)
  git -C "$repo" fetch -q "$remote" '+refs/heads/*:refs/heads/*'
  git -C "$repo" cat-file -e "$unpinned^{commit}"
  # Force-push: main now holds only an unrelated commit; fetch --prune as deploy does, then gc.
  git -C "$remote" checkout -q --orphan rewritten
  commit shipit.ini "$(ini blog.example.com)" >/dev/null
  git -C "$remote" branch -q -D main
  git -C "$remote" branch -q -m main
  git -C "$repo" fetch -q --prune "$remote" '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*'
  # Only the pins (rel1's, and rel2's, whose parent it is) still reach rel1's commit.
  others=$(git -C "$repo" for-each-ref --contains "$sha1" --format='%(refname)' | grep -v '^refs/shipit/' || true)
  [ -z "$others" ]
  git -C "$repo" gc -q --prune=now
  run ! git -C "$repo" cat-file -e "$unpinned^{commit}"
  git -C "$repo" show "$sha1:shipit.ini" | grep -q 'root = out'

  run cmd_rollback blog
  [ "$status" -eq 0 ] || {
    echo "$output"
    return 1
  }
  [ "$(current)" = "$rel1" ]
  grep -qxF $'\troot * /srv/blog/current/out' <(caddy_file)
}
