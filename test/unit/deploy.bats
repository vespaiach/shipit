#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2034,SC2030,SC2031,SC2153 # single-quoted stub bodies; tests set lib variables, each in its own @test subshell
# lib/deploy.sh (plan §5.2): the site Caddy file against golden files, the small parsers and checks
# deploy uses, and whole deploys of a static site in a temp root: git runs for real against a local
# repo (the build user's ~/.gitconfig points the GitHub URL at it), the host commands are stubs.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  load_common
  # shellcheck source=lib/deploy.sh
  . "$REPO_ROOT/lib/deploy.sh"
  golden=$REPO_ROOT/test/golden
  tpl=$REPO_ROOT/templates
  CADDY_ETC=$BATS_TEST_TMPDIR/caddy
  LOG_ROOT=$BATS_TEST_TMPDIR/log
  mkdir -p "$SHIPIT_ETC/sites" "$CADDY_ETC/sites" "$LOG_ROOT"
}

need_envsubst() { command -v envsubst >/dev/null || skip "envsubst (gettext-base) isn't installed"; }

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

@test "both golden site files pass caddy validate" {
  command -v caddy >/dev/null || skip "caddy isn't installed"
  local d=$BATS_TEST_TMPDIR/v f
  mkdir -p "$d/log/blog"
  for f in site-static.caddy site-static-aliases.caddy; do
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

@test "ENV_EXEC refuses a line that isn't KEY=value, naming it" {
  for line in ' A=1' '1A=x' 'A-B=x' 'no equals' '=x' 'export A=1'; do
    run sh -c "$ENV_EXEC" /etc/shipit/sites/blog.env true <<<$'OK=1\n'"$line"
    [ "$status" -eq 1 ] || {
      echo "accepted: $line"
      return 1
    }
    [[ $output == "Line 2 of /etc/shipit/sites/blog.env isn't KEY=value"* ]]
  done
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

# ---- Whole deploys in a temp root ----------------------------------------------------------------

# host: stubs the host commands (each appends its arguments to $calls), keeps a fake passwd that
# useradd writes and getent reads, and makes a local repo ($remote) that https://github.com/me/blog
# points at for the build user's git.
host() {
  command -v flock >/dev/null || skip "flock (util-linux) isn't installed"
  command -v jq >/dev/null || skip "jq isn't installed"
  need_envsubst
  atomic_mv
  calls=$BATS_TEST_TMPDIR/calls passwd=$BATS_TEST_TMPDIR/passwd
  : >"$calls"
  : >"$passwd"
  local cmd
  for cmd in chown setfacl systemctl caddy; do
    stub "$cmd" 'echo "'"$cmd"' $*" >>"'"$calls"'"'
  done
  stub getent '[ "$1" = passwd ] && grep "^$2:" "'"$passwd"'" || exit 2'
  stub useradd 'echo "useradd $*" >>"'"$calls"'"
    for a; do name=$a; done
    while [ $# -gt 0 ]; do [ "$1" = --comment ] && c=$2; shift; done
    echo "$name:x:999:999:$c:/nonexistent:/usr/sbin/nologin" >>"'"$passwd"'"'
  # runuser runs the command as the current user.
  stub runuser 'echo "runuser $1 $2" >>"'"$calls"'"; while [ "$1" != -- ]; do shift; done; shift; exec "$@"'
  BUILD_PATH=$BATS_TEST_TMPDIR/stubs:$PATH
  remote=$BATS_TEST_TMPDIR/remote
  git init -q -b main "$remote"
  site_gitconfig url."$remote".insteadOf https://github.com/me/blog
  commit shipit.ini "$(ini blog blog.example.com)" dist/index.html hello >/dev/null
}

# site_gitconfig <key> <value>: sets a key in the build user's ~/.gitconfig.
site_gitconfig() {
  mkdir -p "$SRV_ROOT/blog/home"
  git config -f "$SRV_ROOT/blog/home/.gitconfig" "$1" "$2"
}

# ini <name> <domain> [line]...: a static shipit.ini, serving dist.
ini() {
  local name=$1 domain=$2
  shift 2
  printf '[site]\n\tname = %s\n\tdomain = %s\n\ttype = static\n' "$name" "$domain"
  printf '\t%s\n' "$@"
  printf '[static]\n\troot = dist\n'
}

# commit <path> <content>...: writes the files in $remote, commits and prints the SHA.
commit() {
  (
    cd "$remote" || exit 1
    while [ "$#" -gt 0 ]; do
      mkdir -p "$(dirname "$1")"
      printf '%s\n' "$2" >"$1"
      shift 2
    done
    git add -A
    git -c user.name=t -c user.email=t@example.com commit -q -m change
    git rev-parse HEAD
  )
}

current() { readlink "$SRV_ROOT/blog/current"; }
previous() { readlink "$SRV_ROOT/blog/previous"; }
releases() { ls "$SRV_ROOT/blog/releases"; }
pins() { git -C "$SRV_ROOT/blog/repo.git" for-each-ref --format='%(refname)' refs/shipit/; }

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
# managed by shipit (shipit deploy writes this file)
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
  [ ! -s "$calls" ]
}

@test "a first deploy whose site.name differs from the name given is refused" {
  host
  commit shipit.ini "$(ini docs docs.example.com)" >/dev/null
  run cmd_deploy https://github.com/me/blog blog
  [ "$status" -eq 1 ]
  [ "${lines[-1]}" = "shipit.ini says the site name is docs, but you asked to deploy it as blog." ]
  [ ! -e "$SRV_ROOT/blog/current" ]
  [ -z "$(releases)" ]
}

@test "a renamed site.name is refused on a later deploy" {
  host
  run cmd_deploy https://github.com/me/blog blog
  [ "$status" -eq 0 ]
  rel=$(current)
  commit shipit.ini "$(ini blog2 blog.example.com)" >/dev/null
  run cmd_deploy blog
  [ "$status" -eq 1 ]
  [ "${lines[-1]}" = "shipit.ini says the site name is blog2, but this repo is deployed as blog. Renaming a site isn't supported; change site.name back." ]
  [ "$(current)" = "$rel" ]
  [ "$(releases)" = "${rel#releases/}" ]
}

@test "a changed site.type is refused on a later deploy" {
  host
  run cmd_deploy https://github.com/me/blog blog
  [ "$status" -eq 0 ]
  rel=$(current)
  commit shipit.ini $'[site]\n\tname = blog\n\tdomain = blog.example.com\n\ttype = nextjs' >/dev/null
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
    commit shipit.ini "$(ini blog blog.example.com "$line")" >/dev/null
    run cmd_deploy blog
    [ "$status" -eq 1 ]
    [[ ${lines[-1]} == "The hostname "*" is already used by the site other. Remove it from shipit.ini or from other." ]]
    [ "$(current)" = "$rel" ]
    [ "$(releases)" = "${rel#releases/}" ]
  done
  grep -qx 'DOMAIN=blog.example.com' "$SHIPIT_ETC/sites/blog.conf"
  run ! grep -q ALIASES "$SHIPIT_ETC/sites/blog.conf"
}

@test "node and nextjs sites aren't deployed yet; nothing is served" {
  host
  commit shipit.ini $'[site]\n\tname = blog\n\tdomain = blog.example.com\n\ttype = node\n[node]\n\tstart = node server.js' >/dev/null
  run cmd_deploy https://github.com/me/blog blog
  [ "$status" -eq 1 ]
  [ "${lines[-1]}" = "Deploying node and nextjs sites isn't supported yet." ]
  [ ! -e "$SRV_ROOT/blog/current" ]
  [ "$(grep -c . "$SHIPIT_ETC/sites/blog.conf")" -eq 2 ] # the marker and REPO
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
  commit shipit.ini "$(ini blog blog.example.com 'env = SECRET' 'env = OTHER')" >/dev/null
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
    shipit.ini "$(printf '%s\n[node]\n\tinstall = make deps\n\tbuild = make site' "$(ini blog blog.example.com)")" >/dev/null
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
  commit shipit.ini "$(ini blog blog.example.com 'env = A' 'env = B' 'env = C')" >/dev/null
  run cmd_deploy https://github.com/me/blog blog
  [ "$status" -eq 1 ]
  [ "${lines[-1]}" = "$SHIPIT_ETC/sites/blog.env is missing B, C, which site.env in shipit.ini needs. Add them as KEY=value lines, then run the deploy again." ]
  [ -z "$(releases)" ]
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
  commit shipit.ini "$(ini blog blog.example.com | sed 's/root = dist/root = out/')" >/dev/null
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
  commit shipit.ini "$(ini blog new.example.com)" >/dev/null
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
  grep -qx 'Another deploy of blog is running; waiting.' "$BATS_TEST_TMPDIR/out2"
  run ! grep -q waiting "$BATS_TEST_TMPDIR/out1"
  [ "$(releases | wc -l | tr -d ' ')" -eq 2 ]
}
