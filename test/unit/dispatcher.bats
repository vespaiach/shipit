#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2034 # stub bodies are single-quoted on purpose; tests set lib variables
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

@test "help lists every command" {
  run "$shipit" help
  for cmd in setup deploy rollback status logs env backup restore help; do
    [[ $output == *"  $cmd "* ]] || {
      echo "missing $cmd"
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
  run "$shipit" frobnicate
  [ "$status" -eq 1 ]
  [ "$output" = "Unknown command: frobnicate. Run 'shipit help' for the list." ]
}

@test "every command except help needs root" {
  as_user
  for cmd in setup deploy rollback status logs env backup restore; do
    run "$shipit" "$cmd" myapp
    [ "$status" -eq 1 ]
    [ "$output" = "Run this as root, or with sudo: sudo shipit $cmd myapp" ] || {
      echo "$cmd: $output"
      return 1
    }
  done
}

@test "the root message repeats the arguments" {
  as_user
  run "$shipit" deploy https://github.com/me/app --ref abc123
  [ "$output" = "Run this as root, or with sudo: sudo shipit deploy https://github.com/me/app --ref abc123" ]
}

@test "commands without a library yet say they're not implemented" {
  as_root
  for cmd in setup deploy rollback status logs env backup restore; do
    [ ! -f "$REPO_ROOT/lib/$cmd.sh" ] || continue
    run "$shipit" "$cmd"
    [ "$status" -eq 1 ]
    [ "$output" = "shipit $cmd is not implemented yet." ]
  done
}

@test "works through a symlink, as installed" {
  as_root
  ln -s "$shipit" "$BATS_TEST_TMPDIR/shipit"
  run "$BATS_TEST_TMPDIR/shipit" help
  [ "$status" -eq 0 ]
}

@test "lib/common.sh can be sourced without side effects" {
  run bash -c 'set -euo pipefail; . "$1/lib/common.sh"; echo "$DEPLOY_USER $SHIPIT_ETC $SHIPIT_VAR"' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "deployer /etc/shipit /var/lib/shipit" ]
}
