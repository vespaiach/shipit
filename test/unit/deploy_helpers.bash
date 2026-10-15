# shellcheck shell=bash
# shellcheck disable=SC2016,SC2034,SC2153 # single-quoted stub bodies; sets lib variables the tests read
# The temp-root harness for deploy and rollback tests (load after helpers): lib/deploy.sh sourced with
# its paths in $BATS_TEST_TMPDIR, host commands stubbed, git run for real against a local repo that the
# build user's ~/.gitconfig puts in place of https://github.com/me/blog.

# deploy_setup: sources lib/common.sh and lib/deploy.sh and points their paths at the temp dir. stdin is
# /dev/null, as without a terminal, so a first deploy never waits for answers; a test that wants to
# answer the prompts redirects the command's stdin itself.
deploy_setup() {
  exec </dev/null
  load_common
  # shellcheck source=lib/deploy.sh
  . "$REPO_ROOT/lib/deploy.sh"
  golden=$REPO_ROOT/test/golden
  tpl=$REPO_ROOT/templates
  CADDY_ETC=$BATS_TEST_TMPDIR/caddy
  LOG_ROOT=$BATS_TEST_TMPDIR/log
  SYSTEMD_DIR=$BATS_TEST_TMPDIR/systemd
  mkdir -p "$SHIPIT_ETC/sites" "$CADDY_ETC/sites" "$LOG_ROOT" "$SYSTEMD_DIR"
}

need_envsubst() { command -v envsubst >/dev/null || skip "envsubst (gettext-base) isn't installed"; }

# curl_codes <code>...: a curl stub answering the codes in turn (the last one from then on), logging
# its arguments to $calls. 000 exits 7, as curl does when nothing answers.
curl_codes() {
  calls=${calls:-$BATS_TEST_TMPDIR/calls}
  printf '%s\n' "$@" >"$BATS_TEST_TMPDIR/codes"
  stub curl 'echo "curl $*" >>"'"$calls"'"; f="'"$BATS_TEST_TMPDIR"'/codes"
    code=$(head -n 1 "$f")
    if [ "$(wc -l <"$f")" -gt 1 ]; then tail -n +2 "$f" >"$f.t"; cat "$f.t" >"$f"; fi
    printf %s "$code"; [ "$code" != 000 ] || exit 7'
}

# host: stubs the host commands (each appends its arguments to $calls), keeps a fake passwd that
# useradd writes and getent reads, writes the site's shipit.ini (put_ini), and makes a local repo
# ($remote) that https://github.com/me/blog points at for the build user's git.
host() {
  command -v flock >/dev/null || skip "flock (util-linux) isn't installed"
  command -v jq >/dev/null || skip "jq isn't installed"
  need_envsubst
  atomic_mv
  calls=$BATS_TEST_TMPDIR/calls passwd=$BATS_TEST_TMPDIR/passwd
  : >"$calls"
  : >"$passwd"
  local cmd
  for cmd in chown setfacl systemctl caddy systemd-analyze; do
    stub "$cmd" 'echo "'"$cmd"' $*" >>"'"$calls"'"'
  done
  # The health check answers 200 (curl_codes changes that), at once: one try, no waiting.
  curl_codes 200
  HEALTH_TIMEOUT=0 HEALTH_INTERVAL=0
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
  put_ini "$(ini blog.example.com)"
  commit dist/index.html hello >/dev/null
}

# put_ini <content>: writes the site's shipit.ini, /srv/blog/config/shipit.ini (the server's file, never the
# repo's). A later deploy picks up what a test writes here between deploys.
put_ini() {
  mkdir -p "$SRV_ROOT/blog/config"
  printf '%s\n' "$1" >"$SRV_ROOT/blog/config/shipit.ini"
}

# site_gitconfig <key> <value>: sets a key in the build user's ~/.gitconfig.
site_gitconfig() {
  mkdir -p "$SRV_ROOT/blog/home"
  git config -f "$SRV_ROOT/blog/home/.gitconfig" "$1" "$2"
}

# ini <domain> [line]...: a static shipit.ini, serving dist.
ini() {
  local domain=$1
  shift
  printf '[site]\n\tdomain = %s\n\ttype = static\n' "$domain"
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

# node_ini <start> [site line]...: a node shipit.ini for blog.example.com.
node_ini() {
  local start=$1
  shift
  printf '[site]\n\tdomain = blog.example.com\n\ttype = node\n'
  printf '\t%s\n' "$@"
  printf '[node]\n\tstart = %s\n' "$start"
}

# unit, caddy_file: the installed unit and Caddy file, with the temp root's paths put back.
unit() {
  local u
  u=$(<"$SYSTEMD_DIR/shipit-blog.service")
  u=${u//$SRV_ROOT//srv}
  printf '%s\n' "${u//$SHIPIT_ETC//etc/shipit}"
}
caddy_file() {
  local c
  c=$(<"$CADDY_ETC/sites/blog.caddy")
  c=${c//$SRV_ROOT//srv}
  printf '%s\n' "${c//$LOG_ROOT//var/log/shipit}"
}

current() { readlink "$SRV_ROOT/blog/current"; }
previous() { readlink "$SRV_ROOT/blog/previous"; }
releases() { ls "$SRV_ROOT/blog/releases"; }
