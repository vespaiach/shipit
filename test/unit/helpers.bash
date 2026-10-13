# shellcheck shell=bash
# Shared set-up for the unit tests: source lib/common.sh, point its constants at a temp dir, and put a
# stub directory first on PATH so getent, ss, systemctl and id can be faked per test.

REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)

load_common() {
  # shellcheck source=lib/common.sh
  . "$REPO_ROOT/lib/common.sh"
  SHIPIT_ETC=$BATS_TEST_TMPDIR/etc
  SHIPIT_VAR=$BATS_TEST_TMPDIR/var
  # shellcheck disable=SC2034 # read by lib/common.sh
  SHIPIT_OWNER_UID=$(id -u)
  mkdir -p "$SHIPIT_ETC/apps" "$SHIPIT_VAR"
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

# write_app_conf <app> <lines...>: writes an app config with safe permissions.
write_app_conf() {
  local app=$1
  shift
  printf '%s\n' "$@" >"$SHIPIT_ETC/apps/$app.conf"
  chmod 644 "$SHIPIT_ETC/apps/$app.conf"
}
