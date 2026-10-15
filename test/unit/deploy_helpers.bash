# shellcheck shell=bash
# shellcheck disable=SC2016,SC2034,SC2153 # single-quoted stub bodies; sets lib variables the tests read
# The temp-root harness for deploy and rollback tests (load after helpers): lib/deploy.sh sourced with
# its paths in $BATS_TEST_TMPDIR, host commands stubbed, git run for real against a local repo that the
# build user's ~/.gitconfig puts in place of https://github.com/me/blog.

# deploy_setup_file: call it from setup_file. Writes the host-command stubs once per test file, in
# $BATS_FILE_TMPDIR/stubs, for every test of the file to share (they're never changed; each test's state
# is in the paths $STUB_CALLS, $STUB_PASSWD and $STUB_CODES, which host and curl_codes set). A new
# executable costs macOS ~0.2 s on its first run, which was most of a deploy test.
deploy_setup_file() {
  local d=$BATS_FILE_TMPDIR/stubs cmd
  mkdir -p "$d"
  for cmd in chown setfacl systemctl caddy systemd-analyze; do
    printf '#!/usr/bin/env bash\necho "%s $*" >>"$STUB_CALLS"\n' "$cmd" >"$d/$cmd"
  done
  printf '#!/usr/bin/env bash\n%s\n' '[ "$1" = passwd ] && grep "^$2:" "$STUB_PASSWD" || exit 2' >"$d/getent"
  printf '#!/usr/bin/env bash\n%s\n' 'echo "useradd $*" >>"$STUB_CALLS"
for a; do name=$a; done
while [ $# -gt 0 ]; do [ "$1" = --comment ] && c=$2; shift; done
echo "$name:x:999:999:$c:/nonexistent:/usr/sbin/nologin" >>"$STUB_PASSWD"' >"$d/useradd"
  # runuser runs the command as the current user.
  printf '#!/usr/bin/env bash\n%s\n' 'echo "runuser $1 $2" >>"$STUB_CALLS"; while [ "$1" != -- ]; do shift; done; shift; exec "$@"' >"$d/runuser"
  printf '#!/usr/bin/env bash\n%s\n' 'echo "curl $*" >>"$STUB_CALLS"; f=$STUB_CODES
code=$(head -n 1 "$f")
if [ "$(wc -l <"$f")" -gt 1 ]; then tail -n +2 "$f" >"$f.t"; cat "$f.t" >"$f"; fi
printf %s "$code"; [ "$code" != 000 ] || exit 7' >"$d/curl"
  chmod +x "$d"/*
}

# shared_stubs: puts the shared stubs on PATH, behind the test's own (so `stub` still overrides them).
shared_stubs() {
  [ -x "$BATS_FILE_TMPDIR/stubs/curl" ] || {
    echo "deploy_setup_file wasn't called from setup_file" >&2
    return 1
  }
  mkdir -p "$BATS_TEST_TMPDIR/stubs"
  PATH=$BATS_TEST_TMPDIR/stubs:$BATS_FILE_TMPDIR/stubs:$PATH
}

# deploy_setup: sources lib/common.sh and lib/deploy.sh and points their paths at the temp dir.
deploy_setup() {
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

# curl_codes <code>...: makes the shared curl stub answer the codes in turn (the last one from then on),
# logging its arguments to $calls. 000 exits 7, as curl does when nothing answers.
curl_codes() {
  shared_stubs
  calls=${calls:-$BATS_TEST_TMPDIR/calls}
  export STUB_CALLS=$calls STUB_CODES=$BATS_TEST_TMPDIR/codes
  printf '%s\n' "$@" >"$STUB_CODES"
}

# host: uses the shared stubs for the host commands (each appends its arguments to $calls), keeps a fake passwd that
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
  shared_stubs
  export STUB_PASSWD=$passwd
  # The health check answers 200 (curl_codes changes that), at once: one try, no waiting.
  curl_codes 200
  HEALTH_TIMEOUT=0 HEALTH_INTERVAL=0
  BUILD_PATH=$BATS_TEST_TMPDIR/stubs:$PATH
  remote=$BATS_TEST_TMPDIR/remote
  git init -q -b main "$remote"
  site_gitconfig url."$remote".insteadOf https://github.com/me/blog
  commit shipit.ini "$(ini blog.example.com)" dist/index.html hello >/dev/null
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
pins() { git -C "$SRV_ROOT/blog/repo.git" for-each-ref --format='%(refname)' refs/shipit/; }
