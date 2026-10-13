#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2034 # single-quoted file contents; tests set lib variables
# libexec/run (plan §3): the process launcher, run against a release in a temp dir.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  # shellcheck source=libexec/run
  . "$REPO_ROOT/libexec/run"
  load_common
  SHIPIT_OPT=$BATS_TEST_TMPDIR/opt
  current=$SHIPIT_OPT/myapp/current
  mkdir -p "$current/node_modules/.bin"
  # A stand-in for next that prints how it was called and where.
  printf '#!/bin/sh\necho "next $* in $(pwd)"\n' >"$current/node_modules/.bin/next"
  chmod +x "$current/node_modules/.bin/next"
  export PORT=3001
}

@test "zero config: web runs next start on 127.0.0.1 and PORT, from the release" {
  run launch myapp web
  [ "$status" -eq 0 ]
  [ "$output" = "next start --hostname 127.0.0.1 --port 3001 in $(cd "$current" && pwd -P)" ] \
    || [ "$output" = "next start --hostname 127.0.0.1 --port 3001 in $current" ]
}

@test "zero config: any other process isn't defined and exits 78" {
  run --separate-stderr launch myapp worker
  [ "$status" -eq 78 ]
  [ "$stderr" = "worker isn't defined in this release" ]
}

@test "deploy.conf: its processes run, with PORT already set when it's sourced" {
  printf '%s\n' 'PROCESS_web="next start --port $PORT"' 'PROCESS_worker="echo worker"' >"$current/deploy.conf"
  run launch myapp worker
  [ "$status" -eq 0 ]
  [ "$output" = worker ]
  run launch myapp web
  [[ $output == "next start --port 3001 in "* ]]
}

@test "deploy.conf: a process it doesn't list exits 78, even web" {
  printf '%s\n' 'PROCESS_worker="echo worker"' >"$current/deploy.conf"
  run --separate-stderr launch myapp web
  [ "$status" -eq 78 ]
  [ "$stderr" = "web isn't defined in this release" ]
}

@test "the command replaces the launcher, so the app is the unit's main process" {
  printf '%s\n' 'PROCESS_web="echo \$\$"' >"$current/deploy.conf"
  run bash -c '. "$1"; SHIPIT_OPT=$2; echo $$; launch myapp web' _ "$REPO_ROOT/libexec/run" "$SHIPIT_OPT"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "${lines[1]}" ]
}

@test "PATH is the release's node_modules/.bin, then the system's" {
  printf '%s\n' 'PROCESS_web="printenv PATH"' >"$current/deploy.conf"
  run launch myapp web
  [ "$output" = "$current/node_modules/.bin:/usr/bin:/bin" ]
}

@test "invalid app or process names exit 78" {
  run launch ../etc web
  [ "$status" -eq 78 ]
  run launch myapp 'web;id'
  [ "$status" -eq 78 ]
  run launch myapp
  [ "$status" -eq 78 ]
}

@test "without PORT it refuses to start" {
  unset PORT
  run --separate-stderr launch myapp web
  [ "$status" -eq 78 ]
  [[ $stderr == "PORT isn't set."* ]]
}
