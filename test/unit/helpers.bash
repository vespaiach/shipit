# shellcheck shell=bash
# Shared set-up for the unit tests: source lib/common.sh, point its constants at a temp dir, and put a
# stub directory first on PATH so commands like id, curl and mv can be faked per test.

REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)

load_common() {
  # shellcheck source=lib/common.sh
  . "$REPO_ROOT/lib/common.sh"
  # shellcheck disable=SC2034 # read by lib/common.sh's users
  SHIPIT_ETC=$BATS_TEST_TMPDIR/etc
  # shellcheck disable=SC2034 # read by lib/common.sh's users
  SHIPIT_VAR=$BATS_TEST_TMPDIR/var
  # shellcheck disable=SC2034 # read by lib/common.sh's users
  SRV_ROOT=$BATS_TEST_TMPDIR/srv
  mkdir -p "$SHIPIT_ETC" "$SHIPIT_VAR" "$SRV_ROOT"
}

# stub <command> <script body>: creates an executable stub that runs the body with bash.
stub() {
  mkdir -p "$BATS_TEST_TMPDIR/stubs"
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"$BATS_TEST_TMPDIR/stubs/$1"
  chmod +x "$BATS_TEST_TMPDIR/stubs/$1"
  case ":$PATH:" in
    *":$BATS_TEST_TMPDIR/stubs:"*) ;;
    *) PATH=$BATS_TEST_TMPDIR/stubs:$PATH ;;
  esac
}

# atomic_mv: atomic_link uses GNU mv -T. Where mv has no -T (macOS), a stub does the same rename(2).
atomic_mv() {
  local d=$BATS_TEST_TMPDIR/mvcheck
  mkdir -p "$d"
  ln -s / "$d/a"
  mv -T "$d/a" "$d/b" 2>/dev/null && return 0
  command -v perl >/dev/null || skip "mv has no -T and perl isn't installed"
  # shellcheck disable=SC2016 # expanded by the stub, not here
  stub mv '[ "$1" = -T ] && shift; [ "$1" = -- ] && shift; exec perl -e '\''rename($ARGV[0], $ARGV[1]) or die "mv: $!\n"'\'' "$@"'
  hash -r
}
