#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2034 # stub bodies are single-quoted on purpose; tests set lib variables
# render() (plan §6): substitutes only the listed variables, and fails on an unset or empty one.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  load_common
  command -v envsubst >/dev/null || skip "envsubst (gettext-base) isn't installed"
  tpl=$REPO_ROOT/test/fixtures/render.tpl
}

@test "render substitutes listed variables and leaves everything else" {
  DOMAIN=app.example.com PORT=3001 OTHER=nope HOME=/nope run render "$tpl" DOMAIN PORT
  [ "$status" -eq 0 ]
  diff <(printf '%s\n' "$output") "$REPO_ROOT/test/golden/render.out"
}

@test "render fails on an unset variable, names it, and writes nothing" {
  unset PORT
  DOMAIN=app.example.com
  run --separate-stderr render "$tpl" DOMAIN PORT
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ $stderr == *"PORT is unset or empty"* ]]
}

@test "render fails on an empty variable" {
  DOMAIN=app.example.com
  PORT=''
  run --separate-stderr render "$tpl" DOMAIN PORT
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ $stderr == *"PORT is unset or empty"* ]]
}

@test "render fails on a missing template" {
  DOMAIN=app.example.com
  run --separate-stderr render "$BATS_TEST_TMPDIR/nope.tpl" DOMAIN
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "render doesn't export variables to the caller" {
  unset DOMAIN
  DOMAIN=app.example.com
  render "$tpl" DOMAIN PORT >/dev/null 2>&1 || true
  PORT=3001
  render "$tpl" DOMAIN PORT >/dev/null
  run bash -c 'echo "${DOMAIN-unset}"'
  [ "$output" = unset ]
}

@test "render keeps values with \$, & and slashes literal" {
  DOMAIN='a.example.com'
  PORT='$HOME&/\1'
  run render "$tpl" DOMAIN PORT
  [ "$status" -eq 0 ]
  [[ $output == *'127.0.0.1:$HOME&/\1 {'* ]]
}
