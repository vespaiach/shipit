#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031,SC2034 # single-quoted stub bodies; tests set lib variables
# lib/env.sh: validating the edited copy, installing it only when it changed, and the restart (all with
# the editor, systemctl and chown stubbed). cmd_env itself edits /etc/<app>/env, so it's e2e only.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  load_common
  # shellcheck source=lib/env.sh
  . "$REPO_ROOT/lib/env.sh"
  APP=node_app
  env=$BATS_TEST_TMPDIR/env
  new=$BATS_TEST_TMPDIR/new
  printf 'APP_URL=https://node-app.localhost\nGREETING=hello\n' >"$env"
  chmod 644 "$env"
  stub systemctl 'echo "$*" >>"'"$BATS_TEST_TMPDIR"'/systemctl.calls"'
  stub chown 'echo "$*" >>"'"$BATS_TEST_TMPDIR"'/chown.calls"'
}

# shellcheck disable=SC2012 # one known file; stat's flags differ between GNU and BSD
perms() { ls -ln -- "$1" | cut -c 1-10; }

# ---- Validation of the edited copy (env_file_lines, named after the real file) -------------------

@test "edited file: KEY=value lines, comments and blanks pass" {
  printf '%s\n' '# a comment' '' '; another' 'APP_URL=https://x.example.com' 'EMPTY=' 'URL=a=b&c=$d' >"$new"
  run env_file_lines "$new" /etc/node_app/env
  [ "$status" -eq 0 ]
}

@test "edited file: a bad line is refused, naming the real file and the line" {
  local line
  for line in 'NO_EQUALS' 'export A=1' ' A=1' 'A B=1' '1A=x' 'A="q"' "A='q'" 'A=back\slash' 'A= x' 'A=x '; do
    printf 'OK=1\n\n%s\n' "$line" >"$new"
    run --separate-stderr env_file_lines "$new" /etc/node_app/env
    [ "$status" -eq 1 ] || {
      echo "accepted $line"
      return 1
    }
    [[ $stderr == "/etc/node_app/env line 3"* ]] || {
      echo "$stderr"
      return 1
    }
  done
}

@test "edited file: a carriage return (a file saved with CRLF) is refused" {
  printf 'A=1\r\n' >"$new"
  run --separate-stderr env_file_lines "$new" /etc/node_app/env
  [ "$status" -eq 1 ]
  [[ $stderr == "/etc/node_app/env line 1 (A)"* ]]
}

# ---- Install only if changed, then restart -------------------------------------------------------

@test "env_install: a changed file is installed 600, chowned to root and the target restarted" {
  printf 'APP_URL=https://node-app.localhost\nGREETING=edited\n' >"$new"
  run env_install "$new" "$env"
  [ "$status" -eq 0 ]
  grep -qx GREETING=edited "$env"
  [ "$(perms "$env")" = -rw------- ]
  grep -qx "root:root $env" "$BATS_TEST_TMPDIR/chown.calls"
  [ "$(cat "$BATS_TEST_TMPDIR/systemctl.calls")" = 'restart node_app.target' ]
  [[ $output == *"Restarted node_app.target."* ]]
}

@test "env_install: an unchanged file isn't rewritten and nothing restarts" {
  cp "$env" "$new"
  run env_install "$new" "$env"
  [ "$status" -eq 0 ]
  [ "$output" = "No changes, so $env and node_app are as they were." ]
  [ ! -e "$BATS_TEST_TMPDIR/systemctl.calls" ]
  [ "$(perms "$env")" = -rw------- ]
}

@test "env_install: a failed restart says how to look" {
  stub systemctl 'exit 1'
  printf 'GREETING=x\n' >"$new"
  run env_install "$new" "$env"
  [ "$status" -eq 1 ]
  [[ $output == *"Restarting node_app.target failed. Check: systemctl status 'node_app@*'" ]]
}

@test "env_edit: EDITOR may carry arguments, and nano is the fallback" {
  stub nano 'echo "nano $*"'
  EDITOR='' run env_edit "$new"
  [ "$output" = "nano $new" ]
  stub myedit 'echo "myedit $*"'
  EDITOR='myedit -w' run env_edit "$new"
  [ "$output" = "myedit -w $new" ]
}

# ---- cmd_env's refusals --------------------------------------------------------------------------

@test "env: refuses a missing or bad app, and extra arguments" {
  run cmd_env
  [ "$status" -eq 1 ]
  [[ $output == Usage:* ]]
  run cmd_env a b
  [ "$status" -eq 1 ]
  run cmd_env Bad
  [ "$status" -eq 1 ]
  run cmd_env nope
  [ "$status" -eq 1 ]
  [ "$output" = "There's no app named nope." ]
}

# ---- Edit until valid ----------------------------------------------------------------------------

# editor <content>...: an EDITOR stub that writes the next content on each run (the last one repeats)
# and counts its runs in edits.
editor() {
  local i=1 c
  for c in "$@"; do
    printf '%s\n' "$c" >"$BATS_TEST_TMPDIR/content.$i"
    i=$((i + 1))
  done
  stub fake-editor 'd="'"$BATS_TEST_TMPDIR"'"; n=$(( $(cat "$d/edits" 2>/dev/null || echo 0) + 1 )); echo $n >"$d/edits"
[ -e "$d/content.$n" ] || n=$((n - 1)); cp "$d/content.$n" "$1"'
  export EDITOR=fake-editor
}

edits() { cat "$BATS_TEST_TMPDIR/edits"; }

@test "edit until valid: a good edit is accepted at once" {
  editor 'GREETING=hi'
  cp "$env" "$new"
  run env_edit_until_valid "$new" /etc/node_app/env </dev/null
  [ "$status" -eq 0 ]
  [ "$(edits)" = 1 ]
  [ "$(cat "$new")" = GREETING=hi ]
}

@test "edit until valid: a bad line names the line and offers another edit" {
  editor $'GREETING=hi\nBAD LINE' 'GREETING=fixed'
  run --separate-stderr env_edit_until_valid "$new" /etc/node_app/env <<<''
  [ "$status" -eq 0 ]
  [ "$(edits)" = 2 ]
  [[ $stderr == *"/etc/node_app/env line 2 isn't KEY=value."* ]]
  [ "$(cat "$new")" = GREETING=fixed ]
}

@test "edit until valid: answering no aborts, and the env file is never touched" {
  editor 'A="quoted"'
  run env_edit_until_valid "$new" "$env" <<<'n'
  [ "$status" -eq 1 ]
  [[ $output == *"line 1 (A)"* ]]
  [[ $output == *"$env wasn't changed." ]]
  [ "$(edits)" = 1 ]
  grep -qx GREETING=hello "$env"
}

@test "edit until valid: with no terminal to ask in, a bad edit aborts" {
  editor 'A= x'
  run env_edit_until_valid "$new" "$env" </dev/null
  [ "$status" -eq 1 ]
  [[ $output == *"$env wasn't changed." ]]
}

@test "edit until valid: a failing editor aborts" {
  stub broken-editor 'exit 3'
  EDITOR=broken-editor run env_edit_until_valid "$new" "$env"
  [ "$status" -eq 1 ]
  [ "$output" = "The editor failed, so $env wasn't changed." ]
}
