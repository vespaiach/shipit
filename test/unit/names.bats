#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2034 # stub bodies are single-quoted on purpose; tests set lib variables
# App-name derivation from a repo URL, and port allocation (plan §2 "What the tool works out").

setup() {
  load helpers
  load_common
  stub systemctl 'exit 1'
}

@test "app name from repo URL" {
  [ "$(app_name_from_repo https://github.com/vespaiach/tracklite)" = tracklite ]
  [ "$(app_name_from_repo https://github.com/me/my-app.git)" = my_app ]
  [ "$(app_name_from_repo git@github.com:me/My.Site.git)" = my_site ]
  [ "$(app_name_from_repo https://github.com/me/my-app/)" = my_app ]
  [ "$(app_name_from_repo ssh://git@localhost/srv/git/next-app.git)" = next_app ]
  [ "$(app_name_from_repo file:///srv/git/node.app)" = node_app ]
}

@test "a derived name can still be invalid, for the caller to catch" {
  run check_app_name "$(app_name_from_repo https://github.com/me/1st-app)"
  [ "$status" -eq 1 ]
}

@test "port allocation: first app gets 3001" {
  stub ss 'echo "LISTEN 0 128 0.0.0.0:22 0.0.0.0:*"'
  run allocate_port
  [ "$status" -eq 0 ]
  [ "$output" = 3001 ]
}

@test "port allocation: skips ports in app configs and ports in use" {
  write_app_conf one 'DOMAIN=one.example.com' 'PORT=3001'
  write_app_conf two 'DOMAIN=two.example.com' 'PORT=3003'
  stub ss 'echo "LISTEN 0 511 127.0.0.1:3002 0.0.0.0:*"'
  run allocate_port
  [ "$status" -eq 0 ]
  [ "$output" = 3004 ]
}

@test "port allocation: reuses a gap left by a removed app" {
  write_app_conf two 'DOMAIN=two.example.com' 'PORT=3002'
  stub ss 'true'
  run allocate_port
  [ "$output" = 3001 ]
}

@test "conf_get reads a value, including quoted values and comments" {
  write_app_conf one 'DATABASE=one          # optional' 'LOG_REDACT_QUERY="token code"'
  [ "$(conf_get "$SHIPIT_ETC/apps/one.conf" DATABASE)" = one ]
  [ "$(conf_get "$SHIPIT_ETC/apps/one.conf" LOG_REDACT_QUERY)" = "token code" ]
  [ "$(conf_get "$SHIPIT_ETC/apps/one.conf" MISSING)" = "" ]
}
