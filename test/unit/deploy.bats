#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2034 # single-quoted stub bodies and file contents; tests set lib variables
# lib/deploy.sh: the unit, target and site templates against golden files and their validators, and
# the small parsers and decisions deploy uses.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  load_common
  # shellcheck source=lib/deploy.sh
  . "$REPO_ROOT/lib/deploy.sh"
  golden=$REPO_ROOT/test/golden
  fixture=$REPO_ROOT/test/fixtures/next-app
  APP=tracklite
  DOMAIN=tracklite.example.com
  PORT=3001
  LOG_REDACT_QUERY=''
}

need_envsubst() { command -v envsubst >/dev/null || skip "envsubst (gettext-base) isn't installed"; }

# matches <golden> <command...>: runs the command and compares its stdout with the golden file.
matches() {
  local name=$1
  shift
  run "$@"
  [ "$status" -eq 0 ]
  diff <(printf '%s\n' "$output") "$golden/$name"
}

# ---- Templates against golden files --------------------------------------------------------------

@test "site with LOG_REDACT_QUERY deletes the parameter from the access log" {
  need_envsubst
  LOG_REDACT_QUERY=token
  matches site.caddy render_site
}

@test "site without LOG_REDACT_QUERY has no format filter block" {
  need_envsubst
  matches site.no-redact.caddy render_site
  [[ $output != *filter* ]]
}

@test "site gets one delete line per redacted parameter" {
  need_envsubst
  LOG_REDACT_QUERY='token code'
  run render_site
  [ "$status" -eq 0 ]
  [[ $output == *$'\t\t\t\tdelete token\n\t\t\t\tdelete code\n\t\t\t}'* ]]
}

@test "app@.service matches the plan" {
  need_envsubst
  matches app@.service render_service
}

@test "app.target wants each process" {
  need_envsubst
  matches app.target render_target web worker
}

@test "app.target for zero config wants only web" {
  need_envsubst
  run render_target web
  [ "$status" -eq 0 ]
  grep -qx 'Wants=tracklite@web.service' <<<"$output"
}

@test "rendering fails rather than write a unit with an empty port" {
  need_envsubst
  PORT=''
  run --separate-stderr render_service
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# ---- Validators on the rendered files (skipped where the tool is missing) -------------------------

@test "both rendered sites pass caddy validate" {
  need_envsubst
  command -v caddy >/dev/null || skip "caddy isn't installed"
  local d=$BATS_TEST_TMPDIR/caddy
  mkdir -p "$d/sites"
  : >"$d/sites/$APP.extra"
  printf 'import %s/sites/*.caddy\n' "$d" >"$d/Caddyfile"
  for LOG_REDACT_QUERY in '' 'token code'; do
    # Point the absolute paths at the temp dir; caddy validate opens the log file.
    render_site | sed "s|/etc/caddy/sites|$d/sites|; s|/var/log/shipit|$d/log|" >"$d/sites/$APP.caddy"
    run caddy validate --config "$d/Caddyfile" --adapter caddyfile
    [ "$status" -eq 0 ] || {
      echo "$output"
      return 1
    }
  done
}

@test "rendered units pass systemd-analyze verify" {
  need_envsubst
  command -v systemd-analyze >/dev/null || skip "systemd-analyze isn't installed"
  local d=$BATS_TEST_TMPDIR/units
  mkdir -p "$d"
  # The launcher and the app user exist only on a deployed host, so point ExecStart at /bin/true.
  render_service | sed 's|^ExecStart=.*|ExecStart=/bin/true %i|' >"$d/$APP@.service"
  render_target web worker >"$d/$APP.target"
  run systemd-analyze verify "$d/$APP@.service" "$d/$APP.target"
  [ "$status" -eq 0 ] || {
    echo "$output"
    return 1
  }
}

@test "logrotate's pattern covers the app's logs but not the per-deploy build logs" {
  local d=$BATS_TEST_TMPDIR/log
  mkdir -p "$d/app/builds"
  touch "$d/app/"{web.log,web.error.log,access.log,deploy.log} "$d/app/builds/deploy-20260101T000000Z.log"
  grep -q '^/var/log/shipit/\*/\*\.log {$' "$REPO_ROOT/templates/logrotate"
  run bash -c 'cd "$1" && printf "%s\n" */*.log' _ "$d"
  [ "$output" = $'app/access.log\napp/deploy.log\napp/web.error.log\napp/web.log' ]
}

# ---- Zero-config detection -----------------------------------------------------------------------

@test "zero config: the fixture Next.js app qualifies" {
  command -v jq >/dev/null || skip "jq isn't installed"
  run zero_config_check "$fixture"
  [ "$status" -eq 0 ]
}

@test "zero config: next in devDependencies also counts" {
  command -v jq >/dev/null || skip "jq isn't installed"
  local d=$BATS_TEST_TMPDIR/app
  mkdir -p "$d"
  echo '{"devDependencies": {"next": "16.0.0"}}' >"$d/package.json"
  : >"$d/package-lock.json"
  run zero_config_check "$d"
  [ "$status" -eq 0 ]
}

@test "zero config: refuses package.json without next" {
  command -v jq >/dev/null || skip "jq isn't installed"
  local d=$BATS_TEST_TMPDIR/app
  mkdir -p "$d"
  jq 'del(.dependencies.next)' "$fixture/package.json" >"$d/package.json"
  cp "$fixture/package-lock.json" "$d/"
  run zero_config_check "$d"
  [ "$status" -eq 1 ]
  [[ $output == *"package.json doesn't list next"* ]]
}

@test "zero config: refuses a repo without package-lock.json, naming the file" {
  command -v jq >/dev/null || skip "jq isn't installed"
  local d=$BATS_TEST_TMPDIR/app
  mkdir -p "$d"
  cp "$fixture/package.json" "$d/"
  run zero_config_check "$d"
  [ "$status" -eq 1 ]
  [[ $output == *"need package-lock.json"* ]]
}

@test "zero config: refuses a repo without package.json, and a broken one" {
  command -v jq >/dev/null || skip "jq isn't installed"
  local d=$BATS_TEST_TMPDIR/app
  mkdir -p "$d"
  run zero_config_check "$d"
  [ "$status" -eq 1 ]
  [[ $output == *"no package.json"* ]]
  echo 'not json' >"$d/package.json"
  : >"$d/package-lock.json"
  run zero_config_check "$d"
  [ "$status" -eq 1 ]
}

@test "zero config: one web process" {
  run release_processes "$fixture"
  [ "$output" = web ]
}

# ---- Repo, branch and app name -------------------------------------------------------------------

@test "default branch from ls-remote --symref" {
  run default_branch <<<$'ref: refs/heads/trunk\tHEAD\n0123456789abcdef0123456789abcdef01234567\tHEAD'
  [ "$status" -eq 0 ]
  [ "$output" = trunk ]
  run default_branch <<<$'ref: refs/heads/feature/x\tHEAD'
  [ "$output" = feature/x ]
}

@test "default branch: fails without a symref line" {
  run default_branch <<<$'0123456789abcdef0123456789abcdef01234567\tHEAD'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "public check uses HTTPS for GitHub SSH URLs and keeps other URLs" {
  [ "$(repo_probe_url git@github.com:me/my-app.git)" = https://github.com/me/my-app.git ]
  [ "$(repo_probe_url https://github.com/me/my-app)" = https://github.com/me/my-app ]
  [ "$(repo_probe_url file:///srv/git/a.git)" = file:///srv/git/a.git ]
  [ "$(repo_probe_url ssh://git@localhost/srv/a.git)" = ssh://git@localhost/srv/a.git ]
}

@test "repo key: GitHub URL forms of one repo match" {
  local k
  k=$(repo_key https://github.com/Me/My-App)
  [ "$k" = github.com/me/my-app ]
  [ "$(repo_key https://github.com/me/my-app.git)" = "$k" ]
  [ "$(repo_key git@github.com:me/my-app.git)" = "$k" ]
  [ "$(repo_key https://github.com/me/other)" != "$k" ]
}

@test "app for repo: finds the app whatever the URL form, and nothing for a new repo" {
  write_app_conf one 'REPO=https://github.com/me/one.git' 'DOMAIN=one.example.com' 'PORT=3001'
  write_app_conf two 'REPO=file:///srv/git/two.git' 'DOMAIN=two.example.com' 'PORT=3002'
  [ "$(app_for_repo git@github.com:me/one.git)" = one ]
  [ "$(app_for_repo https://github.com/me/one)" = one ]
  [ "$(app_for_repo file:///srv/git/two.git)" = two ]
  run app_for_repo https://github.com/me/three
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "app name: a derived name that's free is used as it is" {
  stub getent 'exit 2'
  stub systemctl 'exit 1'
  run app_name_free "$(app_name_from_repo https://github.com/me/next-app)"
  [ "$status" -eq 0 ]
}

@test "app name: refused when invalid, or taken by another app, user or unit" {
  stub getent 'exit 2'
  stub systemctl 'exit 1'
  run app_name_free "$(app_name_from_repo https://github.com/me/1st-app)"
  [ "$status" -eq 1 ]
  write_app_conf next_app 'REPO=https://github.com/other/next-app'
  run app_name_free next_app
  [ "$status" -eq 1 ]
  [[ $output == *"already used by another app"* ]]
  stub getent 'echo "postgres:x:105:110:PostgreSQL administrator:/var/lib/postgresql:/bin/bash"'
  run app_name_free postgres
  [ "$status" -eq 1 ]
  stub getent 'exit 2'
  stub systemctl 'printf "# /usr/lib/systemd/system/getty@.service\n[Unit]\n"'
  run app_name_free getty
  [ "$status" -eq 1 ]
}

@test "app config round-trips through conf_get" {
  REPO='file:///srv/git/odd name&co.git'
  BRANCH=main
  app_conf_text >"$SHIPIT_ETC/apps/$APP.conf"
  chmod 644 "$SHIPIT_ETC/apps/$APP.conf"
  local f=$SHIPIT_ETC/apps/$APP.conf
  [ "$(conf_get "$f" REPO)" = "$REPO" ]
  [ "$(conf_get "$f" BRANCH)" = main ]
  [ "$(conf_get "$f" DOMAIN)" = tracklite.example.com ]
  [ "$(conf_get "$f" PORT)" = 3001 ]
  [ "$(conf_get "$f" HEALTH_FAIL)" = report ]
  [ -z "$(conf_get "$f" DATABASE)" ]
}

# ---- Env file ------------------------------------------------------------------------------------

@test "env file: lines are read literally, comments and blanks skipped" {
  local f=$BATS_TEST_TMPDIR/env
  printf '%s\n' '# comment' '' '; also a comment' 'APP_URL=https://a.example.com' \
    'SECRET=a $HOME `id` $(id) b' 'EQ=x=y' 'BLANK=' >"$f"
  run env_file_lines "$f"
  [ "$status" -eq 0 ]
  [ "$output" = 'APP_URL=https://a.example.com
SECRET=a $HOME `id` $(id) b
EQ=x=y
BLANK=' ]
  # Exporting each line the way the build does keeps the value literal.
  run bash -c 'while IFS= read -r l; do export "$l"; done; printf "%s|" "$SECRET" "$EQ"' <<<"$output"
  [ "$output" = 'a $HOME `id` $(id) b|x=y|' ]
}

@test "env file: a last line without a newline is still read" {
  local f=$BATS_TEST_TMPDIR/env
  printf 'A=1\nB=2' >"$f"
  run env_file_lines "$f"
  [ "$output" = $'A=1\nB=2' ]
}

@test "env file: refuses lines that aren't KEY=value, naming the line" {
  local f=$BATS_TEST_TMPDIR/env line
  for line in 'export A=1' '1A=x' 'A B=x' 'just text' ' A=1'; do
    printf 'OK=1\n%s\n' "$line" >"$f"
    run --separate-stderr env_file_lines "$f"
    [ "$status" -eq 1 ] || {
      echo "accepted $line"
      return 1
    }
    [[ $stderr == *"line 2"* ]]
  done
}

@test "env file: refuses values the env-value rule refuses" {
  local f=$BATS_TEST_TMPDIR/env line
  for line in 'A="quoted"' "A='q'" 'A=back\slash' 'A= lead' 'A=trail '; do
    printf '%s\n' "$line" >"$f"
    run --separate-stderr env_file_lines "$f"
    [ "$status" -eq 1 ] || {
      echo "accepted $line"
      return 1
    }
    [[ $stderr == *"line 1 (A)"* ]]
  done
}

@test "env file: only missing keys are added, existing values never change" {
  local f=$BATS_TEST_TMPDIR/env
  run env_add_missing "$f" APP_URL=https://a.example.com
  [ "$output" = APP_URL=https://a.example.com ]
  printf 'APP_URL=https://old.example.com\nKEY=v' >"$f"
  run env_add_missing "$f" APP_URL=https://a.example.com NEW=1
  [ "$output" = $'APP_URL=https://old.example.com\nKEY=v\nNEW=1' ]
  run env_add_missing "$f" APP_URL=https://a.example.com
  [ "$output" = $'APP_URL=https://old.example.com\nKEY=v' ]
}

# ---- Health and housekeeping ---------------------------------------------------------------------

@test "health: zero config counts any answer below 500" {
  local code
  for code in 200 204 301 308 401 404 499; do
    run health_ok "$code"
    [ "$status" -eq 0 ] || {
      echo "refused $code"
      return 1
    }
  done
  for code in 500 502 503 000 '' abc 99 600; do
    run health_ok "$code"
    [ "$status" -eq 1 ] || {
      echo "accepted $code"
      return 1
    }
  done
}

@test "health: with HEALTH_PATH, only exactly 200 counts" {
  run health_ok 200 1
  [ "$status" -eq 0 ]
  local code
  for code in 201 204 301 308 404 500 000; do
    run health_ok "$code" 1
    [ "$status" -eq 1 ] || {
      echo "accepted $code"
      return 1
    }
  done
}

@test "build logs: only the newest 10 are kept" {
  local d=$BATS_TEST_TMPDIR/builds i
  mkdir -p "$d"
  for i in $(seq -w 1 12); do : >"$d/deploy-202601${i}T000000Z.log"; done
  : >"$d/other.log"
  prune_build_logs "$d" 10
  [ "$(find "$d" -name 'deploy-*.log' | wc -l | tr -d ' ')" = 10 ]
  [ ! -e "$d/deploy-20260101T000000Z.log" ]
  [ ! -e "$d/deploy-20260102T000000Z.log" ]
  [ -e "$d/deploy-20260103T000000Z.log" ]
  [ -e "$d/other.log" ]
  prune_build_logs "$BATS_TEST_TMPDIR/empty" 10
}

@test "free_gb prints a whole number" {
  run free_gb /
  [ "$status" -eq 0 ]
  [[ $output =~ ^[0-9]+$ ]]
}

# ---- Command line --------------------------------------------------------------------------------

@test "deploy: usage, and --ref isn't implemented yet" {
  run --separate-stderr cmd_deploy
  [ "$status" -eq 1 ]
  [[ $stderr == "Usage: sudo shipit deploy <github-url | app>" ]]
  run --separate-stderr cmd_deploy a b
  [ "$status" -eq 1 ]
  run --separate-stderr cmd_deploy myapp --ref abc123
  [ "$status" -eq 1 ]
  [[ $stderr == *"--ref isn't implemented yet"* ]]
}

@test "deploy: refuses before setup has run" {
  run --separate-stderr cmd_deploy myapp
  [ "$status" -eq 1 ]
  [[ $stderr == *"sudo shipit setup"* ]]
}

@test "deploy: an unknown app name is refused with the next step" {
  touch "$SHIPIT_ETC/host.conf"
  run --separate-stderr deploy_resolve nope
  [ "$status" -eq 1 ]
  [[ $stderr == *"There's no app named nope"* ]]
}
