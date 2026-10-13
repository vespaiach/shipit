#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2034 # single-quoted stub bodies; tests set lib variables
# lib/logs.sh: which files each target follows, the refusals, and the tail call (stubbed).

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  load_common
  # shellcheck source=lib/logs.sh
  . "$REPO_ROOT/lib/logs.sh"
  LOG_ROOT=$BATS_TEST_TMPDIR/log
  dir=$LOG_ROOT/node_app
  mkdir -p "$dir/builds"
  touch "$dir"/{access,deploy,web,web.error,worker,worker.error}.log "$dir/web.log.1" "$dir/access.log.2.gz" \
    "$dir/builds/deploy-20261013T093005Z.log"
  write_app_conf node_app DOMAIN=node-app.localhost PORT=3002
  stub tail 'printf "%s\n" "$@"'
}

@test "log_targets: one name per log, error logs folded into their process" {
  [ "$(log_targets "$dir")" = $'access\ndeploy\nweb\nworker' ]
}

@test "log_files: a process follows its log and its error log" {
  [ "$(log_files "$dir" worker)" = "$dir/worker.log"$'\n'"$dir/worker.error.log" ]
}

@test "log_files: access and deploy follow their one file" {
  [ "$(log_files "$dir" access)" = "$dir/access.log" ]
  [ "$(log_files "$dir" deploy)" = "$dir/deploy.log" ]
}

@test "log_files: a process without an error log follows just its log" {
  rm "$dir/web.error.log"
  [ "$(log_files "$dir" web)" = "$dir/web.log" ]
}

@test "log_files: nothing named means every current log, not rotated ones or builds" {
  run log_files "$dir"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf "$dir/%s.log\n" access deploy web.error web worker.error worker)" ]
}

@test "log_files: an unknown target is refused, listing what exists" {
  run --separate-stderr log_files "$dir" nope
  [ "$status" -eq 1 ]
  [ "$stderr" = "There's no nope log in $dir. Choose one of: access deploy web worker." ]
}

@test "log_files: a target that isn't a process name is refused before any file is looked at" {
  local t
  for t in ../../etc/passwd web.error 'a b' Web '*'; do
    run --separate-stderr log_files "$dir" "$t"
    [ "$status" -eq 1 ] || {
      echo "accepted $t"
      return 1
    }
    [[ $stderr == "Invalid process name"* ]]
  done
}

@test "logs: runs tail -n 100 -F on the chosen files" {
  run cmd_logs node_app worker
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' -n 100 -F -- "$dir/worker.log" "$dir/worker.error.log")" ]
  run cmd_logs node_app
  [ "$status" -eq 0 ]
  [ "$(grep -c "^$dir/" <<<"$output")" = 6 ]
}

@test "logs: refuses unknown apps, bad targets and missing logs" {
  run cmd_logs
  [ "$status" -eq 1 ]
  [[ $output == Usage:* ]]
  run cmd_logs nope
  [ "$status" -eq 1 ]
  [ "$output" = "There's no app named nope." ]
  run cmd_logs node_app nope
  [ "$status" -eq 1 ]
  [[ $output == "There's no nope log"* ]]
  [[ $output != *-F* ]]
  write_app_conf fresh DOMAIN=fresh.localhost PORT=3009
  run cmd_logs fresh
  [ "$status" -eq 1 ]
  [ "$output" = "There are no logs in $LOG_ROOT/fresh yet. Deploy the app first: sudo shipit deploy fresh" ]
}
