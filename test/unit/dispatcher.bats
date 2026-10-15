#!/usr/bin/env bats
# shellcheck disable=SC2016 # stub bodies are single-quoted on purpose
# bin/shipit: command names, the root check, help and the unknown-command message.

setup() {
  load helpers
  shipit=$REPO_ROOT/bin/shipit
}

as_root() { stub id '[ "$1" = -u ] && echo 0 || exec /usr/bin/id "$@"'; }
as_user() { stub id '[ "$1" = -u ] && echo 1000 || exec /usr/bin/id "$@"'; }

@test "help works without root" {
  as_user
  for arg in help -h --help; do
    run "$shipit" "$arg"
    [ "$status" -eq 0 ]
    [[ $output == *"Usage: sudo shipit <command>"* ]]
  done
}

@test "help lists every public command, with plan §5's arguments" {
  run "$shipit" help
  for line in '  setup ' '  deploy <name> [ref] ' \
    '  deploy <repo-url> <name> [ref] ' '  rollback <name> ' '  delete <name> ' '  help '; do
    [[ $output == *"$line"* ]] || {
      echo "missing: $line"
      return 1
    }
  done
}

@test "no command prints usage and fails" {
  run "$shipit"
  [ "$status" -eq 1 ]
  [[ $output == *"Usage:"* ]]
}

@test "unknown command is refused, even as root" {
  as_root
  for cmd in frobnicate status logs env backup restore; do
    run "$shipit" "$cmd"
    [ "$status" -eq 1 ]
    [ "$output" = "Unknown command: $cmd. Run 'shipit help' for the list." ]
  done
}

@test "every command except help needs root" {
  as_user
  for cmd in setup deploy rollback delete; do
    run "$shipit" "$cmd" blog
    [ "$status" -eq 1 ]
    [ "$output" = "Run this as root, or with sudo: sudo shipit $cmd blog" ] || {
      echo "$cmd: $output"
      return 1
    }
  done
}

@test "the root message repeats the arguments" {
  as_user
  run "$shipit" deploy https://github.com/me/blog blog main
  [ "$output" = "Run this as root, or with sudo: sudo shipit deploy https://github.com/me/blog blog main" ]
}

@test "works through a symlink, as installed" {
  as_root
  ln -s "$shipit" "$BATS_TEST_TMPDIR/shipit"
  run "$BATS_TEST_TMPDIR/shipit" help
  [ "$status" -eq 0 ]
}

@test "every library can be sourced without side effects" {
  local lib
  for lib in common config setup deploy rollback delete; do
    run bash -c 'set -euo pipefail; . "$1/lib/common.sh"; . "$1/lib/$2.sh"' _ "$REPO_ROOT" "$lib"
    [ "$status" -eq 0 ]
    [ -z "$output" ] || {
      echo "$lib: $output"
      return 1
    }
  done
}

@test "lib/common.sh sets the plan §4 paths, and finds templates/ next to lib/" {
  run bash -c 'set -euo pipefail; . "$1/lib/common.sh"; echo "$SHIPIT_ETC $SHIPIT_VAR $SRV_ROOT $SHIPIT_TEMPLATES"' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "/etc/shipit /var/lib/shipit /srv $REPO_ROOT/lib/../templates" ]
}
