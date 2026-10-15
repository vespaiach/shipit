#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2034,SC2030,SC2031,SC2153,SC2154 # single-quoted stub bodies; tests set lib variables, each in its own @test subshell; deploy_helpers.bash sets calls, remote, golden...
# lib/deploy.sh (plan §5.2): the site Caddy file and unit against golden files, the small parsers and
# checks deploy uses, the health check and restart, and whole deploys of static, node and Next.js
# sites in a temp root: git runs for real against a local repo (the build user's ~/.gitconfig points
# the GitHub URL at it), the host commands are stubs.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  load deploy_helpers
  deploy_setup
}

# ---- The site Caddy file -------------------------------------------------------------------------

# static_ini_values: what render_site_caddy reads, as ini_load would set it.
static_ini_values() {
  SITE=blog SRV_ROOT=/srv LOG_ROOT=/var/log/shipit
  INI_DOMAIN=blog.example.com INI_ROOT=dist INI_ALIASES=()
}

@test "site-static.caddy: log snippet, site block, no alias blocks" {
  need_envsubst
  static_ini_values
  run render_site_caddy site-static.caddy ROOT
  [ "$status" -eq 0 ]
  diff <(printf '%s\n' "$output") "$golden/site-static.caddy"
  [[ $output == *'output file /var/log/shipit/blog/access.log {'* ]]
  [[ $output == *'request>uri regexp \?.*$ ""'* ]]
  [[ $output != *'redir https'* ]]
}

@test "site-static.caddy with two aliases: one 308 redirect block each, logged to the same file" {
  need_envsubst
  static_ini_values
  INI_ALIASES=(www.blog.example.com blog.example.org)
  run render_site_caddy site-static.caddy ROOT
  [ "$status" -eq 0 ]
  diff <(printf '%s\n' "$output") "$golden/site-static-aliases.caddy"
  [ "$(grep -c 'import shipit-blog-log' <<<"$output")" -eq 3 ]
}

@test "the site Caddy file starts with the managed marker" {
  is_shipit_file "$tpl/site-log.caddy"
  is_shipit_file "$golden/site-static.caddy"
  is_shipit_file "$tpl/github_known_hosts"
}

@test "rendering fails, printing nothing, without static.root" {
  need_envsubst
  static_ini_values
  INI_ROOT=''
  run --separate-stderr render_site_caddy site-static.caddy ROOT
  [ "$status" -eq 1 ]
}

# proxy_ini_values: what render_site_caddy and render_site_unit read for a node site on port 3000.
proxy_ini_values() {
  SITE=blog SRV_ROOT=/srv LOG_ROOT=/var/log/shipit SHIPIT_ETC=/etc/shipit
  INI_DOMAIN=blog.example.com INI_ALIASES=() INI_TYPE=node INI_START='node server.js' INI_DIRS=()
  CONF_PORT=3000 PORT=3000
}

@test "site-proxy.caddy: log snippet, a reverse proxy to the site's port, no alias blocks" {
  need_envsubst
  proxy_ini_values
  run render_site_caddy site-proxy.caddy PORT
  [ "$status" -eq 0 ]
  diff <(printf '%s\n' "$output") "$golden/site-proxy.caddy"
  [[ $output == *$'\treverse_proxy 127.0.0.1:3000\n'* ]]
  [[ $output != *'redir https'* ]]
}

@test "site-proxy.caddy with two aliases" {
  need_envsubst
  proxy_ini_values
  INI_ALIASES=(www.blog.example.com blog.example.org)
  run render_site_caddy site-proxy.caddy PORT
  [ "$status" -eq 0 ]
  diff <(printf '%s\n' "$output") "$golden/site-proxy-aliases.caddy"
  [ "$(grep -c 'import shipit-blog-log' <<<"$output")" -eq 3 ]
}

@test "site.service for a node site without data" {
  need_envsubst
  proxy_ini_values
  run render_site_unit
  [ "$status" -eq 0 ]
  diff <(printf '%s\n' "$output") "$golden/site-node.service"
  is_shipit_file "$golden/site-node.service"
  [[ $output != *StateDirectory* && $output != *CacheDirectory* ]]
}

@test "site.service for a node site with two data.dir entries" {
  need_envsubst
  proxy_ini_values
  INI_DIRS=(uploads db)
  run render_site_unit
  [ "$status" -eq 0 ]
  diff <(printf '%s\n' "$output") "$golden/site-node-data.service"
  grep -qx 'StateDirectory=shipit-blog shipit-blog/uploads shipit-blog/db' "$golden/site-node-data.service"
}

@test "site.service for a nextjs site: the default start and a cache folder" {
  need_envsubst
  proxy_ini_values
  INI_TYPE=nextjs INI_START=$INI_NEXTJS_START
  run render_site_unit
  [ "$status" -eq 0 ]
  diff <(printf '%s\n' "$output") "$golden/site-nextjs.service"
  grep -qxF "ExecStart=/bin/sh -c './node_modules/.bin/next start -p \$PORT'" "$golden/site-nextjs.service"
}

@test "rendering the unit fails, printing nothing, without a port" {
  need_envsubst
  proxy_ini_values
  CONF_PORT=''
  run --separate-stderr render_site_unit
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "the golden units pass systemd-analyze verify" {
  command -v systemd-analyze >/dev/null || skip "systemd-analyze isn't installed"
  local d=$BATS_TEST_TMPDIR/units f
  mkdir -p "$d"
  for f in site-node.service site-node-data.service site-nextjs.service; do
    # verify needs the file named like a unit; site_apply_config names its temp copy the same way.
    cp "$golden/$f" "$d/shipit-blog.service"
    run systemd-analyze verify "$d/shipit-blog.service"
    [ "$status" -eq 0 ] || {
      echo "$f: $output"
      return 1
    }
  done
}

@test "the golden site files pass caddy validate" {
  command -v caddy >/dev/null || skip "caddy isn't installed"
  local d=$BATS_TEST_TMPDIR/v f
  mkdir -p "$d/log/blog"
  for f in site-static.caddy site-static-aliases.caddy site-proxy.caddy site-proxy-aliases.caddy; do
    # caddy validate opens the log file, so point it at the temp dir.
    sed "s|/var/log/shipit|$d/log|" "$golden/$f" >"$d/$f"
    run caddy validate --config "$d/$f" --adapter caddyfile
    [ "$status" -eq 0 ] || {
      echo "$f: $output"
      return 1
    }
  done
}

@test "github_known_hosts holds GitHub's published host key fingerprints" {
  command -v ssh-keygen >/dev/null || skip "ssh-keygen isn't installed"
  run ssh-keygen -lf "$tpl/github_known_hosts"
  [ "$status" -eq 0 ]
  diff <(awk '{ print $2, $3, $4 }' <<<"$output") - <<'EOF'
SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU github.com (ED25519)
SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM github.com (ECDSA)
SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s github.com (RSA)
EOF
}

# ---- Arguments -----------------------------------------------------------------------------------

@test "deploy_args: the name form and the URL form, with and without a ref" {
  deploy_args blog
  [ "$SITE $URL $REF" = 'blog  ' ]
  deploy_args blog main
  [ "$SITE|$URL|$REF" = 'blog||main' ]
  deploy_args https://github.com/me/blog blog
  [ "$SITE|$URL|$REF" = 'blog|https://github.com/me/blog|' ]
  sha=0123456789abcdef0123456789abcdef01234567
  deploy_args https://github.com/me/blog.git blog "$sha"
  [ "$SITE|$URL|$REF" = "blog|https://github.com/me/blog.git|$sha" ]
}

@test "deploy_args refuses a bad name, URL or ref, and the wrong number of arguments" {
  run --separate-stderr deploy_args
  [ "$status" -eq 1 ]
  [ "$stderr" = "$DEPLOY_USAGE" ]
  run ! deploy_args blog main extra
  run ! deploy_args https://github.com/me/blog
  run ! deploy_args https://github.com/me/blog blog main extra
  run --separate-stderr deploy_args Blog
  [[ $stderr == "Invalid site name 'Blog'"* ]]
  run --separate-stderr deploy_args https://gitlab.com/me/blog blog
  [[ $stderr == "Invalid repo URL"* ]]
  run --separate-stderr deploy_args blog --upload-pack=x
  [[ $stderr == "Invalid ref '--upload-pack=x'"* ]]
  run ! deploy_args blog ''
  run ! deploy_args git@github.com:me/blog.git blog
}

@test "same_repo ignores .git and letter case" {
  same_repo https://github.com/me/blog https://github.com/Me/Blog.git
  run ! same_repo https://github.com/me/blog https://github.com/me/blog2
  run ! same_repo https://github.com/me/blog https://github.com/you/blog
}

@test "default_branch reads ls-remote --symref" {
  run default_branch <<<$'ref: refs/heads/trunk\tHEAD\n0123456789abcdef0123456789abcdef01234567\tHEAD'
  [ "$output" = trunk ]
  run default_branch <<<$'0123456789abcdef0123456789abcdef01234567\tHEAD'
  [ "$status" -ne 0 ]
}

# ---- Install and build defaults ------------------------------------------------------------------

@test "install_default picks the command by lockfile" {
  [ "$(printf 'package.json\npackage-lock.json\n' | install_default)" = 'npm ci' ]
  [ "$(printf 'package.json\npnpm-lock.yaml\n' | install_default)" = 'pnpm install --frozen-lockfile' ]
  [ "$(printf 'package.json\nyarn.lock\n' | install_default)" = 'yarn install --immutable' ]
  [ "$(printf 'yarn.lock\npackage-lock.json\n' | install_default)" = 'npm ci' ]
  [ "$(printf 'package.json\nsrc\n' | install_default)" = 'npm install' ]
  [ -z "$(printf 'shipit.ini\ndist\n' | install_default)" ]
  [ -z "$(printf 'package.json.bak\nmy-package-lock.json\n' | install_default)" ]
}

@test "build_default runs npm run build only when package.json has a build script" {
  command -v jq >/dev/null || skip "jq isn't installed"
  [ "$(build_default <<<'{"scripts": {"build": "vite build"}}')" = 'npm run build' ]
  [ -z "$(build_default <<<'{"scripts": {"test": "x"}}')" ]
  [ -z "$(build_default <<<'{"scripts": {"build": 1}}')" ]
  [ -z "$(build_default <<<'{}')" ]
  [ -z "$(build_default <<<'not json')" ]
}

# ---- The env file --------------------------------------------------------------------------------

@test "missing_env_keys names the keys without a KEY= line" {
  f=$BATS_TEST_TMPDIR/blog.env
  printf 'A=1\n#B=2\n B=3\nC=\nAB=4\n' >"$f"
  run missing_env_keys "$f" A B C D
  [ "$output" = $'B\nD' ]
  run missing_env_keys "$BATS_TEST_TMPDIR/missing.env" A
  [ "$output" = A ]
  run missing_env_keys "$f"
  [ -z "$output" ]
}

@test "ENV_EXEC exports KEY=value lines and runs the command with stdin closed" {
  run sh -c "$ENV_EXEC" blog.env sh -c 'printf "%s|" "$A" "$B" "$C" "$D" "$E" "$F"; cat' <<'EOF'
A=1
# a comment
; another

B="two words"
C='single'
D=a=b "c"
E="
F=  spaced
EOF
  [ "$status" -eq 0 ]
  [ "$output" = '1|two words|single|a=b "c"|"|spaced|' ]
  # Blanks around a value go (quotes keep inner ones), and a last line without a newline counts.
  run sh -c "$ENV_EXEC" blog.env sh -c 'printf "[%s]" "$S" "$Q" "$T"' < <(printf 'S= a b \t\nQ= " a " \nT=end')
  [ "$output" = '[a b][ a ][end]' ]
}

@test "ENV_EXEC looks the command up before exporting, so a PATH in the file can't change it" {
  fake=$BATS_TEST_TMPDIR/fake
  mkdir -p "$fake"
  printf '#!/bin/sh\necho fake\n' >"$fake/sh"
  chmod +x "$fake/sh"
  run sh -c "$ENV_EXEC" blog.env sh -c 'printf "%s|%s" "$PATH" "$A"' <<<"PATH=$fake"$'\nA=1'
  [ "$status" -eq 0 ]
  [ "$output" = "$fake|1" ]
}

@test "ENV_EXEC and env_file_check refuse a line that isn't KEY=value, naming it" {
  f=$BATS_TEST_TMPDIR/blog.env
  for line in ' A=1' '1A=x' 'A-B=x' 'no equals' '=x' 'export A=1'; do
    run sh -c "$ENV_EXEC" /etc/shipit/sites/blog.env true <<<$'OK=1\n'"$line"
    [ "$status" -eq 1 ] || {
      echo "accepted: $line"
      return 1
    }
    [[ $output == "Line 2 of /etc/shipit/sites/blog.env isn't KEY=value"* ]]
    printf 'OK=1\n%s\n' "$line" >"$f"
    run --separate-stderr env_file_check "$f"
    [ "$status" -eq 1 ] || {
      echo "env_file_check accepted: $line"
      return 1
    }
    [ "$stderr" = "Line 2 of $f isn't KEY=value (KEY: letters, digits and _, not starting with a digit)." ]
  done
}

@test "env_file_check accepts what ENV_EXEC reads, and exports and runs nothing" {
  f=$BATS_TEST_TMPDIR/blog.env
  printf '# c\n; c\n\nPATH=/nonexistent\nLD_PRELOAD=x\nA_1="q"\nB=a=b\nT=end' >"$f"
  path=$PATH
  run env_file_check "$f"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  env_file_check "$f"
  [ "$PATH" = "$path" ]
  [ -z "${LD_PRELOAD-}" ]
  [ -z "${A_1-}" ]
}

# ---- Releases and symlinks -----------------------------------------------------------------------

@test "release names: UTC time then the full SHA, and the SHA comes back out" {
  sha=0123456789abcdef0123456789abcdef01234567
  name=$(release_name 20261014T101500Z "$sha")
  [ "$name" = "20261014T101500Z-$sha" ]
  [ "$(release_sha "$name")" = "$sha" ]
  [[ $(release_name "$(date -u +%Y%m%dT%H%M%SZ)" "$sha") =~ $RELEASE_RE ]]
  for bad in "$sha" "20261014T101500Z-${sha:0:39}" "20261014T101500-$sha" "x20261014T101500Z-$sha" \
    "20261014T101500Z-${sha}0" "20261014T101500Z-${sha^^}"; do
    run ! release_sha "$bad"
  done
}

@test "path_resolve follows relative, absolute and chained links, and refuses loops" {
  d=$(path_resolve "$BATS_TEST_TMPDIR")
  mkdir -p "$d/a/b"
  ln -s b "$d/a/rel"
  ln -s "$d/a" "$d/abs"
  ln -s ../../abs/rel "$d/a/b/chain"
  ln -s loop2 "$d/loop1"
  ln -s loop1 "$d/loop2"
  [ "$(path_resolve "$d/a/rel")" = "$d/a/b" ]
  [ "$(path_resolve "$d/abs/rel/x")" = "$d/a/b/x" ]
  [ "$(path_resolve "$d/a/b/chain")" = "$d/a/b" ]
  [ "$(path_resolve "$d/a/./b/../missing/y")" = "$d/a/missing/y" ]
  [ "$(path_resolve /../..)" = / ]
  run ! path_resolve "$d/loop1"
  run ! path_resolve relative/path
}

# release_tree: a release with dist/index.html and a shipit.ini next to dist.
release_tree() {
  rel=$(path_resolve "$BATS_TEST_TMPDIR")/rel
  mkdir -p "$rel/dist/sub"
  echo hi >"$rel/dist/index.html"
  echo '[site]' >"$rel/shipit.ini"
}

@test "static_root_check accepts symlinks that stay inside the root" {
  release_tree
  ln -s index.html "$rel/dist/home.html"
  ln -s ../index.html "$rel/dist/sub/up.html"
  ln -s "$rel/dist/sub" "$rel/dist/abs-inside"
  ln -s missing.html "$rel/dist/dangling.html"
  ln -s . "$rel/dist/self"
  static_root_check "$rel" dist
}

@test "static_root_check refuses symlinks out of the root: relative, absolute, chained" {
  local link target
  while read -r link target; do
    rm -rf "$BATS_TEST_TMPDIR/rel"
    release_tree
    ln -s inner "$rel/dist/chain" # dist/chain -> dist/inner -> (the case's target)
    ln -s "${target//@REL@/$rel}" "$rel/dist/$link"
    run --separate-stderr static_root_check "$rel" dist
    [ "$status" -eq 1 ] || {
      echo "accepted dist/$link -> $target"
      return 1
    }
    [[ $stderr == *"is a symlink to somewhere outside dist"* ]]
  done <<'EOF'
sub/link ../../shipit.ini
link ..
link /etc/passwd
link @REL@
link @REL@/dist/../shipit.ini
inner ../shipit.ini
inner sub/../../../other-site
EOF
}

@test "static_root_check refuses a missing root, a root that's a symlink, or reached through one" {
  release_tree
  run --separate-stderr static_root_check "$rel" out
  [ "$status" -eq 1 ]
  [[ $stderr == "The release has no folder out (static.root in shipit.ini)"* ]]
  ln -s dist "$rel/public"
  run ! static_root_check "$rel" public
  ln -s /etc "$rel/build"
  run ! static_root_check "$rel" build/ssh
  echo x >"$rel/file"
  run ! static_root_check "$rel" file
}

# ---- Prune ---------------------------------------------------------------------------------------

@test "prune_releases keeps current and previous and deletes every other release" {
  a=20261001T000000Z-1111111111111111111111111111111111111111
  b=20261002T000000Z-2222222222222222222222222222222222222222
  c=20261003T000000Z-3333333333333333333333333333333333333333
  d=20261004T000000Z-1111111111111111111111111111111111111111
  run prune_releases "$c" "$b" <<<"$a"$'\n'"$b"$'\n'"$c"$'\n'"$d"$'\nnot-a-release'
  [ "$output" = "$a"$'\n'"$d" ]
  run prune_releases "$c" '' <<<"$c"
  [ -z "$output" ]
}

@test "prune_refs unpins SHAs no kept release has, and keeps a SHA shared with one" {
  b=20261002T000000Z-2222222222222222222222222222222222222222
  d=20261004T000000Z-1111111111111111111111111111111111111111
  pinned=$'refs/shipit/1111111111111111111111111111111111111111\nrefs/shipit/2222222222222222222222222222222222222222\nrefs/shipit/3333333333333333333333333333333333333333\nrefs/shipit/bad'
  run prune_refs "$d" "$b" <<<"$pinned"
  [ "$output" = refs/shipit/3333333333333333333333333333333333333333 ]
  run prune_refs "$d" <<<"$pinned"
  [ "$output" = $'refs/shipit/2222222222222222222222222222222222222222\nrefs/shipit/3333333333333333333333333333333333333333' ]
}

# ---- Health check and restart --------------------------------------------------------------------

# health_values: what site_health_check reads; it polls without waiting, for up to 5 s.
health_values() {
  SITE=blog CONF_PORT=3000 INI_DOMAIN=blog.example.com INI_HEALTH=/ INI_HEALTH_STRICT=''
  HEALTH_TIMEOUT=5 HEALTH_INTERVAL=0
  calls=$BATS_TEST_TMPDIR/calls
  : >"$calls"
}

@test "site_health_check polls until the site answers, with the site's Host header" {
  health_values
  curl_codes 000 000 200
  run site_health_check
  [ "$status" -eq 0 ]
  [ "$output" = 'http://127.0.0.1:3000/ answered 200.' ]
  [ "$(grep -c . "$calls")" -eq 3 ]
  [ "$(head -n 1 "$calls")" = 'curl -s -o /dev/null -w %{http_code} --max-time 5 -H Host: blog.example.com http://127.0.0.1:3000/' ]
}

@test "site_health_check fails when the site answers 500 until the timeout" {
  health_values
  # SECONDS counts whole seconds, so a 1 s timeout can end after one try; 2 s always allows several.
  HEALTH_TIMEOUT=2 HEALTH_INTERVAL=0.2
  curl_codes 500
  run --separate-stderr site_health_check
  [ "$status" -eq 1 ]
  [ "$stderr" = 'http://127.0.0.1:3000/ (Host: blog.example.com) answered 500 within 2 s; it needs a status below 500. Check: journalctl -u shipit-blog' ]
  [ "$(grep -c . "$calls")" -gt 1 ]
}

@test "site_health_check: a redirect passes by default, but site.health needs exactly 200" {
  health_values
  HEALTH_TIMEOUT=0
  curl_codes 302
  run site_health_check
  [ "$status" -eq 0 ]
  INI_HEALTH=/api/health INI_HEALTH_STRICT=1
  run --separate-stderr site_health_check
  [ "$status" -eq 1 ]
  [ "$stderr" = 'http://127.0.0.1:3000/api/health (Host: blog.example.com) answered 302 within 0 s; it needs 200. Check: journalctl -u shipit-blog' ]
  curl_codes 000
  run --separate-stderr site_health_check
  [[ $stderr == 'http://127.0.0.1:3000/api/health (Host: blog.example.com) gave no answer within 0 s;'* ]]
}

@test "site_restart_and_check: node restarts; nextjs stops, empties its cache and starts; static does nothing" {
  health_values
  curl_codes 200
  stub systemctl 'echo "systemctl $*" >>"'"$calls"'"'
  INI_TYPE=node
  run site_restart_and_check
  [ "$status" -eq 0 ]
  diff <(grep -v '^curl' "$calls") - <<<'systemctl restart shipit-blog'
  : >"$calls"
  INI_TYPE=nextjs
  run site_restart_and_check
  [ "$status" -eq 0 ]
  diff <(grep -v '^curl' "$calls") - <<<$'systemctl stop shipit-blog\nsystemctl clean --what=cache shipit-blog\nsystemctl start shipit-blog'
  : >"$calls"
  INI_TYPE=static
  run site_restart_and_check
  [ "$status" -eq 0 ]
  [ ! -s "$calls" ]
}

@test "site_restart_and_check fails if the restart fails, without a health check" {
  health_values
  curl_codes 200
  stub systemctl 'echo "systemctl $*" >>"'"$calls"'"; [ "$1" != clean ]'
  INI_TYPE=nextjs
  run --separate-stderr site_restart_and_check
  [ "$status" -eq 1 ]
  [ "$stderr" = 'Restarting shipit-blog failed. Check: journalctl -u shipit-blog' ]
  run ! grep -q '^curl\|start' "$calls"
}

# ---- Whole deploys in a temp root ----------------------------------------------------------------
# The harness (host, commit, ini, node_ini, unit, caddy_file, current, previous, ...) is in
# deploy_helpers.bash.

@test "first deploy of a static site: users, folders, release, links, Caddy file, conf" {
  host
  sha=$(git -C "$remote" rev-parse HEAD)
  run cmd_deploy https://github.com/me/blog blog
  [ "$status" -eq 0 ] || {
    echo "$output"
    return 1
  }
  rel=$(releases)
  [[ $rel =~ ^[0-9]{8}T[0-9]{6}Z-$sha$ ]]
  [ "${lines[-1]}" = "Deployed blog: now serving $rel." ]
  [ "$(current)" = "releases/$rel" ]
  [ ! -e "$SRV_ROOT/blog/previous" ]
  [ "$(cat "$SRV_ROOT/blog/current/dist/index.html")" = hello ]
  [ "$(pins)" = "refs/shipit/$sha" ]

  diff "$SHIPIT_ETC/sites/blog.conf" - <<'EOF'
# managed by shipit (shipit deploy and rollback write this file)
REPO=https://github.com/me/blog
TYPE=static
DOMAIN=blog.example.com
EOF
  caddy=$(<"$CADDY_ETC/sites/blog.caddy")
  caddy=${caddy//$SRV_ROOT//srv}
  diff <(printf '%s\n' "${caddy//$LOG_ROOT//var/log/shipit}") "$golden/site-static.caddy"

  for line in \
    "useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin --comment shipit site blog blog" \
    "useradd --system --gid blog --no-create-home --home-dir $SRV_ROOT/blog/home --shell /usr/sbin/nologin --comment shipit build blog blog-build" \
    "chown -- root:blog $SRV_ROOT/blog" "chown -- root:blog $SRV_ROOT/blog/releases" \
    "chown -- blog-build:blog $SRV_ROOT/blog/repo.git" "chown -- caddy:caddy $LOG_ROOT/blog" \
    "chown -- blog-build:blog $SRV_ROOT/blog/releases/$rel" "chown -R -- root:blog $SRV_ROOT/blog/releases/$rel" \
    "setfacl -m u:caddy:x -- $SRV_ROOT/blog $SRV_ROOT/blog/releases $SRV_ROOT/blog/releases/$rel" \
    "setfacl -R -P -m u:caddy:rX -- $SRV_ROOT/blog/releases/$rel/dist" \
    "runuser -u blog-build" "runuser -u caddy" "systemctl reload caddy"; do
    grep -qxF -- "$line" "$calls" || {
      echo "missing: $line"
      return 1
    }
  done
  # The release is handed to the build user before it's built, and taken back before Caddy sees it.
  [ "$(grep -n -- "-- blog-build:blog $SRV_ROOT/blog/releases/" "$calls" | cut -d: -f1)" -lt \
    "$(grep -n -- "-R -- root:blog" "$calls" | cut -d: -f1)" ]
  [ "$(grep -n -- "-R -- root:blog" "$calls" | cut -d: -f1)" -lt \
    "$(grep -n -- "setfacl -R" "$calls" | cut -d: -f1)" ]
  [ -d "$LOG_ROOT/blog" ]
  for d in "$SRV_ROOT/blog:2750" "$SRV_ROOT/blog/releases:2750" "$SRV_ROOT/blog/repo.git:700" \
    "$SRV_ROOT/blog/.ssh:700" "$SRV_ROOT/blog/home:700" "$LOG_ROOT/blog:750" \
    "$SRV_ROOT/blog/releases/$rel:2750"; do
    [ -n "$(find "${d%:*}" -maxdepth 0 -perm "${d##*:}")" ] || {
      echo "mode of $d"
      return 1
    }
  done
}

@test "later deploys: previous follows, two releases kept, pins of deleted releases dropped" {
  host
  sha1=$(git -C "$remote" rev-parse HEAD)
  run cmd_deploy https://github.com/me/blog blog
  [ "$status" -eq 0 ]
  rel1=$(current)

  # The same commit again: a second release with the same SHA; one pin.
  run cmd_deploy blog
  [ "$status" -eq 0 ]
  rel2=$(current)
  [ "$rel2" != "$rel1" ]
  [ "$(previous)" = "$rel1" ]
  [ "$(pins)" = "refs/shipit/$sha1" ]

  sha2=$(commit dist/index.html v2)
  run cmd_deploy blog main
  [ "$status" -eq 0 ]
  [ "$(previous)" = "$rel2" ]
  [ "$(cat "$SRV_ROOT/blog/current/dist/index.html")" = v2 ]
  [ "$(releases | wc -l | tr -d ' ')" -eq 2 ]
  [ ! -e "$SRV_ROOT/blog/$rel1" ]
  # rel1 is gone, but previous (rel2) has its SHA, so the pin stays.
  [ "$(pins | sort)" = "$(printf 'refs/shipit/%s\n' "$sha1" "$sha2" | sort)" ]
  rel3=$(current)

  run cmd_deploy blog "$sha2"
  [ "$status" -eq 0 ]
  [ "$(previous)" = "$rel3" ]
  [ "$(pins)" = "refs/shipit/$sha2" ]
  [ "$(releases | wc -l | tr -d ' ')" -eq 2 ]
  # The Caddy file didn't change, so Caddy was reloaded once, by the first deploy.
  [ "$(grep -c 'systemctl reload caddy' "$calls")" -eq 1 ]
}

@test "a tag and the URL form with .git and other letter case deploy too" {
  host
  git -C "$remote" tag v1
  run cmd_deploy https://github.com/me/blog blog
  [ "$status" -eq 0 ]
  run cmd_deploy https://github.com/Me/Blog.git blog v1
  [ "$status" -eq 0 ] || {
    echo "$output"
    return 1
  }
  grep -qx 'REPO=https://github.com/me/blog' "$SHIPIT_ETC/sites/blog.conf"
}

@test "the URL form with a repo other than the registered one is refused" {
  host
  run cmd_deploy https://github.com/me/blog blog
  [ "$status" -eq 0 ]
  rel=$(current)
  : >"$calls"
  run cmd_deploy https://github.com/me/other blog
  [ "$status" -eq 1 ]
  [ "$output" = "The site blog is deployed from https://github.com/me/blog, not https://github.com/me/other. Pick another name for this repo, or run: shipit deploy blog" ]
  [ "$(current)" = "$rel" ]
  [ ! -s "$calls" ]
}

@test "the name form needs a registered site" {
  host
  run cmd_deploy blog
  [ "$status" -eq 1 ]
  [ "$output" = "There's no site named blog. Deploy it first with: shipit deploy <repo-url> blog" ]
  [ ! -e "$SHIPIT_ETC/sites/blog.conf" ]
  [ ! -e "$SHIPIT_VAR/blog.lock" ]
  [ ! -s "$calls" ]
}

@test "a changed site.type is refused on a later deploy" {
  host
  run cmd_deploy https://github.com/me/blog blog
  [ "$status" -eq 0 ]
  rel=$(current)
  commit shipit.ini $'[site]\n\tdomain = blog.example.com\n\ttype = nextjs' >/dev/null
  run cmd_deploy blog
  [ "$status" -eq 1 ]
  [ "${lines[-1]}" = "shipit.ini says the site type is nextjs, but this site is deployed as static. Changing a site's type isn't supported." ]
  [ "$(current)" = "$rel" ]
}

@test "a domain or alias clash with another site is refused on a later deploy" {
  host
  printf 'REPO=https://github.com/me/other\nTYPE=static\nDOMAIN=other.example.com\nALIASES=www.other.example.com\n' \
    >"$SHIPIT_ETC/sites/other.conf"
  run cmd_deploy https://github.com/me/blog blog
  [ "$status" -eq 0 ]
  rel=$(current)
  for line in 'alias = www.other.example.com' 'alias = other.example.com'; do
    commit shipit.ini "$(ini blog.example.com "$line")" >/dev/null
    run cmd_deploy blog
    [ "$status" -eq 1 ]
    [[ ${lines[-1]} == "The hostname "*" is already used by the site other. Remove it from shipit.ini or from other." ]]
    [ "$(current)" = "$rel" ]
    [ "$(releases)" = "${rel#releases/}" ]
  done
  grep -qx 'DOMAIN=blog.example.com' "$SHIPIT_ETC/sites/blog.conf"
  run ! grep -q ALIASES "$SHIPIT_ETC/sites/blog.conf"
}

@test "first deploy of a node site: port, unit, daemon-reload, enable, restart, health check, Caddy file" {
  host
  commit shipit.ini "$(node_ini 'node server.js')" >/dev/null
  run cmd_deploy https://github.com/me/blog blog
  [ "$status" -eq 0 ] || {
    echo "$output"
    return 1
  }
  rel=$(releases)
  [ "${lines[-1]}" = "Deployed blog: now serving $rel." ]
  [[ $output == *"Gave blog the port 3000."* ]]
  [ "$(current)" = "releases/$rel" ]
  diff "$SHIPIT_ETC/sites/blog.conf" - <<'EOF'
# managed by shipit (shipit deploy and rollback write this file)
REPO=https://github.com/me/blog
TYPE=node
DOMAIN=blog.example.com
PORT=3000
EOF
  diff <(unit) "$golden/site-node.service"
  diff <(caddy_file) "$golden/site-proxy.caddy"
  grep -qx "systemd-analyze verify .*/unit/shipit-blog.service" "$calls"
  # In order: install the unit, reload systemd, enable, reload Caddy, restart, health check.
  diff <(grep -E '^(systemctl|curl)' "$calls") - <<'EOF'
systemctl daemon-reload
systemctl enable --quiet shipit-blog
systemctl reload caddy
systemctl restart shipit-blog
curl -s -o /dev/null -w %{http_code} --max-time 5 -H Host: blog.example.com http://127.0.0.1:3000/
EOF
  # No setfacl for Caddy: it proxies, and never reads the release.
  run ! grep -q setfacl "$calls"
  [ -n "$(find "$SYSTEMD_DIR/shipit-blog.service" -perm 644)" ]
}

@test "a node site's first deploy takes the lowest free port, and later deploys keep it" {
  host
  printf 'REPO=https://github.com/me/a\nTYPE=node\nDOMAIN=a.example.com\nPORT=3000\n' >"$SHIPIT_ETC/sites/a.conf"
  printf 'REPO=https://github.com/me/b\nPORT=3002\n' >"$SHIPIT_ETC/sites/b.conf" # b's first deploy is under way
  commit shipit.ini "$(node_ini 'node server.js')" >/dev/null
  run cmd_deploy https://github.com/me/blog blog
  [ "$status" -eq 0 ]
  grep -qx PORT=3001 "$SHIPIT_ETC/sites/blog.conf"
  rm "$SHIPIT_ETC/sites/a.conf"
  run cmd_deploy blog
  [ "$status" -eq 0 ]
  grep -qx PORT=3001 "$SHIPIT_ETC/sites/blog.conf"
  run ! grep -q 'Gave blog' <<<"$output"
}

@test "first deploy of a nextjs site: .next/cache links to the cache folder; stop, clean, start" {
  host
  stub npm '[ "$1" = run ] || exit 0; mkdir -p .next/cache && echo old >.next/cache/f'
  commit package.json '{"scripts": {"build": "next build"}}' \
    shipit.ini $'[site]\n\tdomain = blog.example.com\n\ttype = nextjs' >/dev/null
  run cmd_deploy https://github.com/me/blog blog
  [ "$status" -eq 0 ] || {
    echo "$output"
    return 1
  }
  [ "$(readlink "$SRV_ROOT/blog/current/.next/cache")" = /var/cache/shipit-blog ]
  diff <(unit) "$golden/site-nextjs.service"
  diff <(grep -E '^systemctl (stop|clean|start|restart) ' "$calls") - <<'EOF'
systemctl stop shipit-blog
systemctl clean --what=cache shipit-blog
systemctl start shipit-blog
EOF
}

@test "a node site's data folders: only the unit changes, so systemd reloads and Caddy doesn't" {
  host
  commit shipit.ini "$(node_ini 'node server.js')" >/dev/null
  run cmd_deploy https://github.com/me/blog blog
  [ "$status" -eq 0 ]
  commit shipit.ini "$(node_ini 'node server.js')"$'\n[data]\n\tdir = uploads\n\tdir = db' >/dev/null
  : >"$calls"
  run cmd_deploy blog
  [ "$status" -eq 0 ]
  diff <(unit) "$golden/site-node-data.service"
  grep -qx 'systemctl daemon-reload' "$calls"
  grep -qx 'systemctl restart shipit-blog' "$calls"
  run ! grep -q 'systemctl reload caddy' "$calls"
  # systemd makes the data folder; shipit never touches it.
  run ! grep -q 'shipit-blog/\|/var/lib' "$calls"

  # An alias changes only the Caddy file.
  commit shipit.ini "$(node_ini 'node server.js' 'alias = www.blog.example.com')"$'\n[data]\n\tdir = uploads\n\tdir = db' >/dev/null
  : >"$calls"
  run cmd_deploy blog
  [ "$status" -eq 0 ]
  grep -qx 'systemctl reload caddy' "$calls"
  run ! grep -q 'daemon-reload' "$calls"
  grep -qx 'systemctl restart shipit-blog' "$calls"
}

@test "a failed health check reverts a later deploy: links, unit and Caddy file back, release deleted" {
  host
  commit shipit.ini "$(node_ini 'node server.js')" >/dev/null
  run cmd_deploy https://github.com/me/blog blog
  [ "$status" -eq 0 ]
  run cmd_deploy blog
  [ "$status" -eq 0 ]
  old_current=$(current) old_previous=$(previous)
  old_unit=$(unit) old_caddy=$(caddy_file)
  commit shipit.ini "$(node_ini 'node other.js' 'alias = www.blog.example.com')" >/dev/null
  # The new release answers 500; once reverted, the old one answers 200.
  curl_codes 500 200
  : >"$calls"
  run cmd_deploy blog
  [ "$status" -eq 1 ]
  [ "${lines[-1]}" = "Deploy failed health check; still serving ${old_current#releases/}." ]
  [[ $output == *"http://127.0.0.1:3000/ (Host: blog.example.com) answered 500 within 0 s;"* ]]
  [ "$(current)" = "$old_current" ]
  [ "$(previous)" = "$old_previous" ]
  [ "$(releases | sort)" = "$(printf '%s\n' "${old_current#releases/}" "${old_previous#releases/}" | sort)" ]
  [ "$(unit)" = "$old_unit" ]
  [ "$(caddy_file)" = "$old_caddy" ]
  run ! grep -q ALIASES "$SHIPIT_ETC/sites/blog.conf"
  # The new unit and Caddy file went in, then the old ones again; each start was health-checked.
  [ "$(grep -c 'systemctl daemon-reload' "$calls")" -eq 2 ]
  [ "$(grep -c 'systemctl reload caddy' "$calls")" -eq 2 ]
  [ "$(grep -c 'systemctl restart shipit-blog' "$calls")" -eq 2 ]
  [ "$(grep -c '^curl' "$calls")" -eq 2 ]
}

@test "a failed first deploy of a node site stops, disables and removes the unit; a rerun can succeed" {
  host
  commit shipit.ini "$(node_ini 'node server.js')" >/dev/null
  curl_codes 000 200
  run cmd_deploy https://github.com/me/blog blog
  [ "$status" -eq 1 ]
  [ "${lines[-1]}" = "First deploy of blog failed; nothing is served." ]
  [[ $output == *"gave no answer"* ]]
  [ ! -e "$SYSTEMD_DIR/shipit-blog.service" ]
  [ ! -e "$SRV_ROOT/blog/current" ]
  [ ! -e "$CADDY_ETC/sites/blog.caddy" ]
  [ -z "$(releases)" ]
  grep -qx 'systemctl stop shipit-blog' "$calls"
  grep -qx 'systemctl disable --quiet shipit-blog' "$calls"
  [ "$(grep -c 'systemctl daemon-reload' "$calls")" -eq 2 ]
  [ "$(grep -c 'systemctl reload caddy' "$calls")" -eq 2 ]
  # The users and the conf (REPO and the port) are kept.
  diff "$SHIPIT_ETC/sites/blog.conf" - <<'EOF'
# managed by shipit (shipit deploy and rollback write this file)
REPO=https://github.com/me/blog
PORT=3000
EOF
  [ "$(wc -l <"$passwd" | tr -d ' ')" -eq 2 ]

  run cmd_deploy https://github.com/me/blog blog
  [ "$status" -eq 0 ] || {
    echo "$output"
    return 1
  }
  grep -qx PORT=3000 "$SHIPIT_ETC/sites/blog.conf"
  diff <(unit) "$golden/site-node.service"
}

@test "a unit file shipit didn't write is refused, and the deploy reverts" {
  host
  commit shipit.ini "$(node_ini 'node server.js')" >/dev/null
  echo '[Service]' >"$SYSTEMD_DIR/shipit-blog.service"
  run cmd_deploy https://github.com/me/blog blog
  [ "$status" -eq 1 ]
  [[ $output == *"$SYSTEMD_DIR/shipit-blog.service wasn't written by shipit, so it wasn't replaced."* ]]
  [ "${lines[-1]}" = "First deploy of blog failed; nothing is served." ]
  [ "$(cat "$SYSTEMD_DIR/shipit-blog.service")" = '[Service]' ]
  run ! grep -q '^systemctl' "$calls"
}

@test "a site Caddy file shipit didn't write is refused before anything is installed" {
  host
  echo 'blog.example.com { respond "mine" }' >"$CADDY_ETC/sites/blog.caddy"
  run cmd_deploy https://github.com/me/blog blog
  [ "$status" -eq 1 ]
  [[ $output == *"$CADDY_ETC/sites/blog.caddy wasn't written by shipit, so it wasn't replaced. Move it away, then run the deploy again."* ]]
  [ "${lines[-1]}" = "First deploy of blog failed; nothing is served." ]
  [ "$(cat "$CADDY_ETC/sites/blog.caddy")" = 'blog.example.com { respond "mine" }' ]
  run ! grep -q '^systemctl\|^caddy' "$calls"
}

@test "a user named like the site that shipit didn't make is refused before anything changes" {
  host
  echo 'blog-build:x:1000:1000:Someone:/home/blog:/bin/bash' >"$passwd"
  run cmd_deploy https://github.com/me/blog blog
  [ "$status" -eq 1 ]
  [ "$output" = "A user named blog-build already exists, and shipit didn't create it, so the site can't be called blog. Pick another name." ]
  run ! grep -q useradd "$calls"
  [ ! -e "$SHIPIT_ETC/sites/blog.conf" ]
}

@test "a first deploy that stopped half-way resumes: existing shipit users are kept" {
  host
  echo 'blog:x:999:999:shipit site blog:/nonexistent:/usr/sbin/nologin' >"$passwd"
  run cmd_deploy https://github.com/me/blog blog
  [ "$status" -eq 0 ]
  [ "$(grep -c useradd "$calls")" -eq 1 ]
  grep -q 'useradd .* blog-build$' "$calls"
}

@test "install runs without secrets, build gets the env file on stdin, never on a command line" {
  host
  stub npm 'echo "npm $* SECRET=${SECRET-unset} umask=$(umask)" >>"'"$calls"'"
    if [ "$1 $2" = "run build" ]; then mkdir -p dist && echo "built with $SECRET" >dist/index.html; fi'
  commit package.json '{"scripts": {"build": "vite build"}}' package-lock.json '{}' dist/index.html src >/dev/null
  printf '# secrets\nSECRET="s3cr3t value"\nOTHER=1\n' >"$SHIPIT_ETC/sites/blog.env"
  commit shipit.ini "$(ini blog.example.com 'env = SECRET' 'env = OTHER')" >/dev/null
  run cmd_deploy https://github.com/me/blog blog
  [ "$status" -eq 0 ] || {
    echo "$output"
    return 1
  }
  [[ $output == *"Install: npm ci"* ]]
  [[ $output == *"Build: npm run build"* ]]
  grep -qx 'npm ci SECRET=unset umask=0027' "$calls"
  grep -qx 'npm run build SECRET=s3cr3t value umask=0027' "$calls"
  [ "$(cat "$SRV_ROOT/blog/current/dist/index.html")" = 'built with s3cr3t value' ]
  run ! grep -q 's3cr3t' <(grep -v '^npm' "$calls")
}

@test "node.install and node.build from shipit.ini override the defaults" {
  host
  stub make 'echo "make $*" >>"'"$calls"'"'
  commit package.json '{"scripts": {"build": "x"}}' \
    shipit.ini "$(printf '%s\n[node]\n\tinstall = make deps\n\tbuild = make site' "$(ini blog.example.com)")" >/dev/null
  run cmd_deploy https://github.com/me/blog blog
  [ "$status" -eq 0 ] || {
    echo "$output"
    return 1
  }
  diff <(grep '^make' "$calls") - <<<$'make deps\nmake site'
}

@test "missing site.env keys are named, before anything is built" {
  host
  printf 'A=1\n' >"$SHIPIT_ETC/sites/blog.env"
  commit shipit.ini "$(ini blog.example.com 'env = A' 'env = B' 'env = C')" >/dev/null
  run cmd_deploy https://github.com/me/blog blog
  [ "$status" -eq 1 ]
  [ "${lines[-1]}" = "$SHIPIT_ETC/sites/blog.env is missing B, C, which site.env in shipit.ini needs. Add them as KEY=value lines, then run the deploy again." ]
  [ -z "$(releases)" ]
}

@test "an env file setting PATH and LD_PRELOAD passes root's check without affecting it" {
  host
  printf 'PATH=/nonexistent\nLD_PRELOAD=x\n' >"$SHIPIT_ETC/sites/blog.env"
  run cmd_deploy https://github.com/me/blog blog
  [ "$status" -eq 0 ] || {
    echo "$output"
    return 1
  }
}

@test "a broken env file stops the deploy before the build" {
  host
  printf 'A=1\nnot a line\n' >"$SHIPIT_ETC/sites/blog.env"
  run cmd_deploy https://github.com/me/blog blog
  [ "$status" -eq 1 ]
  [[ $output == *"Line 2 of $SHIPIT_ETC/sites/blog.env isn't KEY=value"* ]]
  [ -z "$(releases)" ]
}

@test "a failed build deletes the half-built release and leaves the live site alone" {
  host
  run cmd_deploy https://github.com/me/blog blog
  [ "$status" -eq 0 ]
  rel=$(current)
  stub npm 'exit 3'
  commit package.json '{"scripts": {"build": "x"}}' >/dev/null
  run cmd_deploy blog
  [ "$status" -eq 1 ]
  [ "${lines[-1]}" = "The install step (npm install) failed, so the release was deleted and the site wasn't changed." ]
  [ "$(current)" = "$rel" ]
  [ "$(releases)" = "${rel#releases/}" ]
}

@test "a release whose root links outside it is refused and deleted" {
  host
  ln -s ../shipit.ini "$remote/dist/leak.txt"
  git -C "$remote" add -A
  git -C "$remote" -c user.name=t -c user.email=t@example.com commit -q -m leak
  run cmd_deploy https://github.com/me/blog blog
  [ "$status" -eq 1 ]
  [[ $output == *"dist/leak.txt is a symlink to somewhere outside dist"* ]]
  [ -z "$(releases)" ]
  run ! grep -q setfacl "$calls"
}

@test "a release without its static.root is refused" {
  host
  commit shipit.ini "$(ini blog.example.com | sed 's/root = dist/root = out/')" >/dev/null
  run cmd_deploy https://github.com/me/blog blog
  [ "$status" -eq 1 ]
  [[ $output == *"The release has no folder out (static.root in shipit.ini)"* ]]
  [ -z "$(releases)" ]
}

@test "a private repo: the deploy key is printed with the plan's message, then a rerun fetches over SSH" {
  host
  # HTTPS without credentials fails; SSH goes through an ssh stub that serves $remote once the key
  # is "added" (the file $added exists).
  rm "$SRV_ROOT/blog/home/.gitconfig"
  site_gitconfig url."$BATS_TEST_TMPDIR/nowhere".insteadOf https://github.com/me/blog
  added=$BATS_TEST_TMPDIR/added
  stub ssh 'echo "ssh $*" >>"'"$calls"'"; [ -e "'"$added"'" ] || exit 255; exec git upload-pack "'"$remote"'"'
  run cmd_deploy https://github.com/me/blog blog
  [ "$status" -eq 1 ]
  key=$SRV_ROOT/blog/.ssh/id_ed25519
  [ -f "$key" ]
  [ "${lines[-2]}" = "$(cat "$key.pub")" ]
  [[ ${lines[-2]} == "ssh-ed25519 "*" shipit-blog" ]]
  [ "${lines[-1]}" = "Can't fetch https://github.com/me/blog. If it's a private repo, add this key as a read-only deploy key at https://github.com/me/blog/settings/keys/new, then run the same command again." ]
  [ ! -e "$SRV_ROOT/blog/current" ]
  grep -qx 'REPO=https://github.com/me/blog' "$SHIPIT_ETC/sites/blog.conf"
  grep -qF "ssh -i $key -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$SHIPIT_TEMPLATES/github_known_hosts -o GlobalKnownHostsFile=/dev/null " "$calls"
  grep -q " git@github.com git-upload-pack 'me/blog.git'$" "$calls"
  pub=$(cat "$key.pub")

  touch "$added"
  run cmd_deploy https://github.com/me/blog blog
  [ "$status" -eq 0 ] || {
    echo "$output"
    return 1
  }
  [ "$(cat "$key.pub")" = "$pub" ] # the key is reused
  # Later deploys use SSH too, because the site has a key.
  : >"$calls"
  run cmd_deploy blog
  [ "$status" -eq 0 ]
  grep -q "^ssh -i $key " "$calls"
}

@test "a config that fails validation reverts a later deploy to the old release" {
  host
  run cmd_deploy https://github.com/me/blog blog
  [ "$status" -eq 0 ]
  run cmd_deploy blog
  [ "$status" -eq 0 ]
  old_current=$(current) old_previous=$(previous)
  # caddy refuses any config with the new domain.
  stub caddy 'echo "caddy $*" >>"'"$calls"'"; ! grep -q new.example.com "$3" || { echo "Error: bad" >&2; exit 1; }'
  commit shipit.ini "$(ini new.example.com)" >/dev/null
  : >"$calls"
  run cmd_deploy blog
  [ "$status" -eq 1 ]
  [ "${lines[-1]}" = "Deploy failed: the new release's config couldn't be installed; still serving ${old_current#releases/}." ]
  [[ $output == *"Error: bad"* ]]
  [ "$(current)" = "$old_current" ]
  [ "$(previous)" = "$old_previous" ]
  [ "$(releases | sort)" = "$(printf '%s\n' "${old_current#releases/}" "${old_previous#releases/}" | sort)" ]
  grep -qx 'DOMAIN=blog.example.com' "$SHIPIT_ETC/sites/blog.conf"
  grep -q 'blog.example.com {' "$CADDY_ETC/sites/blog.caddy"
  run ! grep -q 'systemctl reload' "$calls"
}

@test "a failed first deploy removes current, the Caddy file and the release, and keeps users and conf" {
  host
  stub systemctl 'echo "systemctl $*" >>"'"$calls"'"; [ "$1" != reload ] || [ -e "'"$BATS_TEST_TMPDIR"'/reloaded" ] || { touch "'"$BATS_TEST_TMPDIR"'/reloaded"; exit 1; }'
  run cmd_deploy https://github.com/me/blog blog
  [ "$status" -eq 1 ]
  [[ $output == *"Reloading Caddy failed."* ]]
  [ "${lines[-1]}" = "First deploy of blog failed; nothing is served." ]
  [ ! -e "$SRV_ROOT/blog/current" ]
  [ ! -e "$CADDY_ETC/sites/blog.caddy" ]
  [ -z "$(releases)" ]
  [ "$(grep -c 'systemctl reload caddy' "$calls")" -eq 2 ]
  [ "$(grep -c . "$SHIPIT_ETC/sites/blog.conf")" -eq 2 ] # the marker and REPO
  [ "$(wc -l <"$passwd" | tr -d ' ')" -eq 2 ]

  # Running it again starts over.
  run cmd_deploy https://github.com/me/blog blog
  [ "$status" -eq 0 ]
  [ -e "$CADDY_ETC/sites/blog.caddy" ]
}

@test "two deploys of one site run one after the other" {
  host
  order=$BATS_TEST_TMPDIR/order
  stub npm '[ "$1" = run ] || exit 0; echo start >>"'"$order"'"; sleep 1; mkdir -p dist; echo end >>"'"$order"'"'
  commit package.json '{"scripts": {"build": "x"}}' >/dev/null
  run cmd_deploy https://github.com/me/blog blog
  [ "$status" -eq 0 ]
  : >"$order"
  cmd_deploy blog >"$BATS_TEST_TMPDIR/out1" 2>&1 &
  first=$!
  until grep -q start "$order" 2>/dev/null; do sleep 0.1; done
  cmd_deploy blog >"$BATS_TEST_TMPDIR/out2" 2>&1 &
  second=$!
  wait "$first"
  wait "$second"
  [ "$(cat "$order")" = $'start\nend\nstart\nend' ]
  grep -qx 'Another deploy or rollback of blog is running; waiting.' "$BATS_TEST_TMPDIR/out2"
  run ! grep -q waiting "$BATS_TEST_TMPDIR/out1"
  [ "$(releases | wc -l | tr -d ' ')" -eq 2 ]
}
