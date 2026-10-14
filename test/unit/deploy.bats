#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031,SC2034 # single-quoted stub bodies and file contents; tests set lib variables
# lib/deploy.sh: the unit, target and site templates against golden files and their validators, and
# the small parsers and decisions deploy uses.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  load_common
  # shellcheck source=lib/deploy.sh
  . "$REPO_ROOT/lib/deploy.sh"
  # deploy's commands run as deployer; here as the current user, with the same clean environment.
  # shellcheck disable=SC2329 # called by the deploy functions under test
  as_deployer() { (cd / && env -i HOME="$HOME" PATH="$PATH" "$@"); }
  golden=$REPO_ROOT/test/golden
  fixture=$REPO_ROOT/test/fixtures/next-app
  node_fixture=$REPO_ROOT/test/fixtures/node-app
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

@test "app name: refused when a folder of that name already exists in the state root" {
  stub getent 'exit 2'
  stub systemctl 'exit 1'
  stub id 'exit 1'
  mkdir -p "$STATE_ROOT/apt"
  run app_name_free apt
  [ "$status" -eq 1 ]
  [ "$output" = "$STATE_ROOT/apt already exists and isn't the apt app's own folder, so systemd would hand it to apt. Choose another app name." ]
}

# load_conf_stubs: what deploy_load_conf asks the host: no such user, no unit, nothing listening.
load_conf_stubs() {
  stub getent 'exit 2'
  stub systemctl 'exit 1'
  stub ss 'exit 0'
}

@test "deploy_load_conf: BACKUP defaults to postgres with a DATABASE and none without" {
  load_conf_stubs
  write_app_conf tracklite REPO=https://github.com/me/tracklite BRANCH=main DOMAIN=t.example.com PORT=3001 DATABASE=tracklite
  deploy_load_conf
  [ "$BACKUP" = postgres ]
  write_app_conf tracklite REPO=https://github.com/me/tracklite BRANCH=main DOMAIN=t.example.com PORT=3001 DATABASE=
  deploy_load_conf
  [ "$BACKUP" = none ]
  write_app_conf tracklite REPO=https://github.com/me/tracklite BRANCH=main DOMAIN=t.example.com PORT=3001 \
    BACKUP=state 'BACKUP_PATHS="backups photos"'
  deploy_load_conf
  [ "$BACKUP" = state ]
  [ "$BACKUP_PATHS" = 'backups photos' ]
}

@test "deploy_load_conf: a bad BACKUP or BACKUP_PATHS, or BACKUP=postgres without a DATABASE, is refused" {
  load_conf_stubs
  local base=(REPO=https://github.com/me/tracklite BRANCH=main DOMAIN=t.example.com PORT=3001)
  write_app_conf tracklite "${base[@]}" BACKUP=files
  run deploy_load_conf
  [ "$status" -eq 1 ]
  [[ $output == "Invalid BACKUP 'files': use postgres, state or none."* ]]
  write_app_conf tracklite "${base[@]}" BACKUP=postgres
  run deploy_load_conf
  [ "$status" -eq 1 ]
  [[ $output == "BACKUP=postgres needs a DATABASE. Set DATABASE, or use BACKUP=state or BACKUP=none."* ]]
  write_app_conf tracklite "${base[@]}" BACKUP=state BACKUP_PATHS=../etc
  run deploy_load_conf
  [ "$status" -eq 1 ]
  [[ $output == "Invalid BACKUP_PATHS entry '../etc'"* ]]
  [[ $output == *"Fix $SHIPIT_ETC/apps/tracklite.conf, then re-run sudo shipit deploy tracklite." ]]
}

@test "deploy_load_conf: refuses an app whose state folder belongs to someone else" {
  load_conf_stubs
  stub id 'echo 99999'
  write_app_conf tracklite REPO=https://github.com/me/tracklite BRANCH=main DOMAIN=t.example.com PORT=3001
  mkdir -p "$STATE_ROOT/tracklite"
  run deploy_load_conf
  [ "$status" -eq 1 ]
  [[ $output == "$STATE_ROOT/tracklite already exists and isn't the tracklite app's own folder"* ]]
}

@test "app config round-trips through conf_get" {
  REPO='file:///srv/git/odd name&co.git'
  BRANCH=main
  DATABASE=''
  app_conf_text >"$SHIPIT_ETC/apps/$APP.conf"
  chmod 644 "$SHIPIT_ETC/apps/$APP.conf"
  local f=$SHIPIT_ETC/apps/$APP.conf
  [ "$(conf_get "$f" REPO)" = "$REPO" ]
  [ "$(conf_get "$f" BRANCH)" = main ]
  [ "$(conf_get "$f" DOMAIN)" = tracklite.example.com ]
  [ "$(conf_get "$f" PORT)" = 3001 ]
  [ "$(conf_get "$f" HEALTH_FAIL)" = report ]
  [ -z "$(conf_get "$f" DATABASE)" ]
  grep -qx "DATABASE=''" "$f"
  DATABASE=tracklite
  app_conf_text >"$f"
  [ "$(conf_get "$f" DATABASE)" = tracklite ]
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

@test "deploy: usage, and --ref must be a sha" {
  local usage="Usage: sudo shipit deploy <github-url | app> [--ref <sha>]"
  run --separate-stderr cmd_deploy
  [ "$status" -eq 1 ]
  [ "$stderr" = "$usage" ]
  run --separate-stderr cmd_deploy a b
  [ "$status" -eq 1 ]
  [ "$stderr" = "$usage" ]
  run --separate-stderr cmd_deploy myapp --ref
  [ "$stderr" = "$usage" ]
  run --separate-stderr cmd_deploy myapp --other abc123
  [ "$stderr" = "$usage" ]
  run --separate-stderr cmd_deploy myapp --ref 'HEAD~1'
  [ "$status" -eq 1 ]
  [[ $stderr == "Invalid --ref 'HEAD~1'"* ]]
  # A valid sha gets as far as the next check.
  run --separate-stderr cmd_deploy myapp --ref abc123
  [ "$status" -eq 1 ]
  [[ $stderr == *"sudo shipit setup"* ]]
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

# ---- deploy.conf ---------------------------------------------------------------------------------

@test "process names: the fixture's web and worker, rendered into the target" {
  need_envsubst
  mapfile -t procs < <(conf_processes <"$node_fixture/deploy.conf")
  [ "${procs[*]}" = 'web worker' ]
  matches app.target render_target "${procs[@]}"
}

@test "process names: only PROCESS_<name>= at the start of a line counts" {
  run conf_processes <<'EOF'
# PROCESS_commented="no"
  PROCESS_indented="no"
	PROCESS_tabbed="no"
export PROCESS_exported="no"
PROCESS_$(touch /tmp/pwned)="no"
PROCESS_`id`="no"
PROCESS_${X}="no"
PROCESS_Upper="no"
PROCESS_9lives="no"
PROCESS_dash-ed="no"
PROCESS_spaced ="no"
PROCESS_plus+="no"
PROCESS_web="node server.js $(id); PROCESS_inline=1"
PROCESS_worker=$(echo evil)
PROCESS_web="again"
PROCESS_mail_2="node mail.js"
 # PROCESS_x=1
EOF
  [ "$status" -eq 0 ]
  [ "$output" = $'web\nworker\nmail_2' ]
  [ ! -e /tmp/pwned ]
}

@test "process names: none in a deploy.conf without PROCESS_ lines" {
  run conf_processes <<<$'INSTALL=x\nBUILD=y'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "app.target with several processes matches the golden file" {
  need_envsubst
  mapfile -t procs < <(conf_processes <<<$'PROCESS_web=a\n  PROCESS_hidden=b\nPROCESS_worker=c\nPROCESS_mailer=d')
  matches app.target.three render_target "${procs[@]}"
}

@test "HEALTH_PATH: plain paths, quoted or with a comment, and the last one wins" {
  local line
  for line in 'HEALTH_PATH=/health' 'HEALTH_PATH="/health"' "HEALTH_PATH='/health'" \
    'HEALTH_PATH=/health                     # optional; strict' 'HEALTH_PATH=/health   '; do
    run conf_health_path <<<"$line"
    [ "$status" -eq 0 ] && [ "$output" = /health ] || {
      echo "$line gave $output"
      return 1
    }
  done
  run conf_health_path <<<$'HEALTH_PATH=/first\nHEALTH_PATH=/api/v1/health.json\n'
  [ "$output" = /api/v1/health.json ]
  run conf_health_path <"$node_fixture/deploy.conf"
  [ "$output" = /health ]
}

@test "HEALTH_PATH: unset, empty, indented or commented means none" {
  local conf
  for conf in 'INSTALL=x' 'HEALTH_PATH=' '  HEALTH_PATH=$(id)' '# HEALTH_PATH=/x' 'export HEALTH_PATH=/x'; do
    run conf_health_path <<<"$conf"
    [ "$status" -eq 0 ] && [ -z "$output" ] || {
      echo "$conf gave $output"
      return 1
    }
  done
}

@test "HEALTH_PATH: anything but a plain path is refused, naming the line" {
  local line
  for line in 'HEALTH_PATH=$(id)' 'HEALTH_PATH=/h$(id)' 'HEALTH_PATH=`id`' 'HEALTH_PATH=health' \
    'HEALTH_PATH=/a b' 'HEALTH_PATH=/h;id' 'HEALTH_PATH=/h#x' 'HEALTH_PATH="/h' 'HEALTH_PATH=/h?x=1' \
    'HEALTH_PATH=$HOME' 'HEALTH_PATH=http://evil/' 'HEALTH_PATH=/h && id'; do
    run --separate-stderr conf_health_path <<<$'INSTALL=x\n'"$line"
    [ "$status" -eq 1 ] || {
      echo "accepted $line"
      return 1
    }
    [[ $stderr == "deploy.conf line 2: HEALTH_PATH must be a plain path"* ]]
  done
}

# deploy_commands_in <release>: runs D3 on the release with as_deployer stubbed.
deploy_commands_in() {
  RELEASE=$1
  DEPLOY_TMP=$BATS_TEST_TMPDIR/tmp
  mkdir -p "$DEPLOY_TMP"
  deploy_commands
  printf '%s|%s\n' "${PROCESSES[*]}" "$HEALTH_PATH"
}

@test "D3: a release with deploy.conf uses its processes and HEALTH_PATH" {
  run deploy_commands_in "$node_fixture"
  [ "$status" -eq 0 ]
  [ "$output" = 'web worker|/health' ]
}

@test "D3: zero config runs web with the lenient health check" {
  command -v jq >/dev/null || skip "jq isn't installed"
  run deploy_commands_in "$fixture"
  [ "$status" -eq 0 ]
  [ "$output" = 'web|' ]
}

@test "D3: deploy.conf must set INSTALL, BUILD and a process; MIGRATE is optional" {
  local d=$BATS_TEST_TMPDIR/rel
  mkdir -p "$d"
  printf '%s\n' 'BUILD=b' >"$d/deploy.conf"
  run --separate-stderr deploy_commands_in "$d"
  [ "$status" -eq 1 ]
  [ "$stderr" = 'deploy.conf must set INSTALL PROCESS_<name>.' ]
  printf '%s\n' 'INSTALL=i' 'BUILD=b' 'MIGRATE=m' 'PROCESS_web="x --port $PORT"' >"$d/deploy.conf"
  run --separate-stderr deploy_commands_in "$d"
  [ "$status" -eq 0 ]
  [ "$output" = 'web|' ]
}

@test "D3: a process only a computed line defines doesn't count" {
  local d=$BATS_TEST_TMPDIR/rel
  mkdir -p "$d"
  printf '%s\n' 'INSTALL=i' 'BUILD=b' '  PROCESS_web=x' >"$d/deploy.conf"
  run --separate-stderr deploy_commands_in "$d"
  [ "$status" -eq 1 ]
  [[ $stderr == "deploy.conf defines no process to run."* ]]
}

@test "build: deploy.conf's commands run with the env file's values, literally" {
  local d=$BATS_TEST_TMPDIR/rel
  mkdir -p "$d"
  printf '%s\n' "INSTALL='echo \"install \$SECRET\"'" 'BUILD="echo build on $PORT"' >"$d/deploy.conf"
  run env PORT=3005 bash -c "$BUILD_SCRIPT" build "$d" <<<$'SECRET=a $(id) b\nOTHER=1'
  [ "$status" -eq 0 ]
  [ "$output" = $'== echo "install $SECRET"\ninstall a $(id) b\n== echo build on 3005\nbuild on 3005' ]
}

# ---- .env.example --------------------------------------------------------------------------------

@test ".env.example keys: only KEY= at the start of a line counts" {
  run env_example_keys <<'EOF'
# COMMENTED=1
  INDENTED=1
	TABBED=1
export EXPORTED=1
$(touch /tmp/pwned)=1
`id`=1
lower=1
MIXED_case=1
9LIVES=1
SPACED =1
DATABASE_URL=postgres://x
API_KEY=
GREETING=hello $(id)
API_KEY=again
_PRIVATE=
EOF
  [ "$status" -eq 0 ]
  [ "$output" = $'DATABASE_URL\nAPI_KEY\nGREETING\n_PRIVATE' ]
  [ ! -e /tmp/pwned ]
}

@test ".env.example keys: the fixture's" {
  run env_example_keys <"$node_fixture/.env.example"
  [ "$output" = $'GREETING\nAPI_TOKEN' ]
}

@test "missing keys: those the env file has, PORT and NODE_ENV are never asked" {
  local f=$BATS_TEST_TMPDIR/env
  run env_missing_keys "$f" <<<$'A\nPORT\nNODE_ENV\nB'
  [ "$output" = $'A\nB' ]
  printf '%s\n' 'APP_URL=https://a.example.com' 'A=' 'AB=1' '# B=1' >"$f"
  run env_missing_keys "$f" <<<$'APP_URL\nA\nB\nC'
  [ "$output" = $'B\nC' ]
}

# ---- Private repos -------------------------------------------------------------------------------

@test "SSH URL for a deploy key: GitHub HTTPS becomes git@, SSH URLs stay, file:// has none" {
  [ "$(repo_ssh_url https://github.com/me/my-app)" = git@github.com:me/my-app.git ]
  [ "$(repo_ssh_url https://github.com/me/my-app.git)" = git@github.com:me/my-app.git ]
  [ "$(repo_ssh_url git@github.com:me/my-app.git)" = git@github.com:me/my-app.git ]
  [ "$(repo_ssh_url ssh://git@localhost/home/git/a.git)" = ssh://git@localhost/home/git/a.git ]
  run repo_ssh_url file:///srv/git/a.git
  [ "$status" -eq 1 ]
  run repo_ssh_url 'https://github.com/me/a b'
  [ "$status" -eq 1 ]
}

@test "deploy key: only SSH URLs use one" {
  repo_uses_key git@github.com:me/a.git
  repo_uses_key ssh://git@localhost/srv/a.git
  run ! repo_uses_key https://github.com/me/a
  run ! repo_uses_key file:///srv/git/a.git
}

@test "deploy key: GitHub's page for adding it, and none for other hosts" {
  [ "$(deploy_key_url git@github.com:Me/My-App.git)" = https://github.com/me/my-app/settings/keys/new ]
  [ "$(deploy_key_url https://github.com/me/app)" = https://github.com/me/app/settings/keys/new ]
  [ -z "$(deploy_key_url ssh://git@localhost/srv/a.git)" ]
}

@test "deploy key: ssh uses only that key and the pinned host keys" {
  [ "$(git_ssh_command /home/deployer/.ssh/shipit_a)" = 'ssh -i /home/deployer/.ssh/shipit_a -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/dev/null' ]
}

# fake_git <failures>: a git stub that logs each call and its GIT_SSH_COMMAND, and fails the first
# <failures> times (or always, with -1).
fake_git() {
  : >"$BATS_TEST_TMPDIR/git.calls"
  stub git '
calls=$(($(wc -l <"'"$BATS_TEST_TMPDIR"'/git.calls") + 1))
printf "%s|%s\n" "$*" "${GIT_SSH_COMMAND-}" >>"'"$BATS_TEST_TMPDIR"'/git.calls"
[ '"$1"' -ge 0 ] && [ "$calls" -gt '"$1"' ] || exit 128
printf "ref: refs/heads/trunk\tHEAD\n0123456789abcdef0123456789abcdef01234567\tHEAD\n"'
}

@test "new app: a repo anonymous git can read is public, over HTTPS" {
  fake_git 0
  run new_app_repo git@github.com:me/app.git "$BATS_TEST_TMPDIR/head"
  [ "$status" -eq 0 ]
  [ "$output" = https://github.com/me/app.git ]
  [ "$(default_branch <"$BATS_TEST_TMPDIR/head")" = trunk ]
  grep -qx 'ls-remote --symref https://github.com/me/app.git HEAD|' "$BATS_TEST_TMPDIR/git.calls"
}

@test "new app: a repo anonymous git can't read is private, over SSH" {
  fake_git -1
  run new_app_repo https://github.com/me/app "$BATS_TEST_TMPDIR/head"
  [ "$status" -eq 0 ]
  [ "$output" = git@github.com:me/app.git ]
  run new_app_repo git@github.com:me/app.git "$BATS_TEST_TMPDIR/head"
  [ "$output" = git@github.com:me/app.git ]
}

@test "new app: ssh:// URLs always use a deploy key, and an unreadable file:// URL fails" {
  fake_git 0
  run new_app_repo ssh://git@localhost/home/git/a.git "$BATS_TEST_TMPDIR/head"
  [ "$output" = ssh://git@localhost/home/git/a.git ]
  [ ! -s "$BATS_TEST_TMPDIR/git.calls" ]
  fake_git -1
  run new_app_repo file:///srv/git/missing.git "$BATS_TEST_TMPDIR/head"
  [ "$status" -eq 1 ]
}

# repo_access_as <repo>: runs deploy_repo_access for the app with deployer's home in the temp dir.
repo_access_as() {
  REPO=$1
  DEPLOY_TMP=$BATS_TEST_TMPDIR/tmp
  mkdir -p "$DEPLOY_TMP"
  deploy_repo_access
}

stub_deployer_home() {
  stub getent '[ "$2" = deployer ] && echo "deployer:x:999:999::'"$BATS_TEST_TMPDIR"'/home:/usr/sbin/nologin"'
  stub ssh-keygen 'while [ $# -gt 1 ]; do [ "$1" = -f ] && f=$2; shift; done; echo private >"$f"; echo "ssh-ed25519 AAAAtest shipit" >"$f.pub"'
  stub hostname 'echo vps'
}

@test "repo access: a public repo needs no key and no ls-remote" {
  stub_deployer_home
  fake_git 0
  run repo_access_as https://github.com/me/app
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$BATS_TEST_TMPDIR/git.calls" ]
  [ ! -e "$BATS_TEST_TMPDIR/home/.ssh" ]
}

@test "repo access: a working deploy key prints nothing" {
  stub_deployer_home
  fake_git 0
  run repo_access_as git@github.com:me/app.git
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -f "$BATS_TEST_TMPDIR/home/.ssh/shipit_$APP" ]
  grep -qF "ls-remote --symref git@github.com:me/app.git HEAD|ssh -i $BATS_TEST_TMPDIR/home/.ssh/shipit_$APP -o IdentitiesOnly=yes" \
    "$BATS_TEST_TMPDIR/git.calls"
}

@test "repo access: prints the key and GitHub's page, then retries until the key works" {
  stub_deployer_home
  fake_git 3
  KEY_RETRY_SECONDS=0
  run repo_access_as git@github.com:me/app.git
  [ "$status" -eq 0 ]
  [[ $output == *"https://github.com/me/app/settings/keys/new"* ]]
  [[ $output == *$'\n  ssh-ed25519 AAAAtest shipit\n'* ]]
  [ "$(grep -c 'ssh-ed25519' <<<"$output")" = 1 ]
  [[ $output == *"Waiting for the repo to accept it"* ]]
  [ "${lines[${#lines[@]} - 1]}" = "The deploy key works." ]
  [ "$(wc -l <"$BATS_TEST_TMPDIR/git.calls" | tr -d ' ')" = 4 ]
  [ "$(default_branch <"$BATS_TEST_TMPDIR/tmp/head")" = trunk ]
}

@test "repo access: an existing key is kept" {
  stub_deployer_home
  fake_git 0
  mkdir -p "$BATS_TEST_TMPDIR/home/.ssh"
  echo old >"$BATS_TEST_TMPDIR/home/.ssh/shipit_$APP"
  run repo_access_as ssh://git@localhost/home/git/a.git
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/home/.ssh/shipit_$APP")" = old ]
}

# ---- Database ------------------------------------------------------------------------------------

@test "database: package.json listing a PostgreSQL client or ORM defaults to yes" {
  command -v jq >/dev/null || skip "jq isn't installed"
  local f=$BATS_TEST_TMPDIR/package.json dep
  for dep in pg postgres drizzle-orm prisma @prisma/client; do
    jq -n --arg d "$dep" '{dependencies: ({next: "16.0.0"} | .[$d] = "1.0.0")}' >"$f"
    run package_wants_database "$f"
    [ "$status" -eq 0 ] || {
      echo "no database for $dep"
      return 1
    }
  done
  echo '{"devDependencies": {"prisma": "6.0.0"}}' >"$f"
  run package_wants_database "$f"
  [ "$status" -eq 0 ]
}

@test "database: the fixtures, other packages, and broken or missing files default to no" {
  command -v jq >/dev/null || skip "jq isn't installed"
  local f=$BATS_TEST_TMPDIR/package.json body
  run package_wants_database "$fixture/package.json"
  [ "$status" -eq 1 ]
  run package_wants_database "$node_fixture/package.json"
  [ "$status" -eq 1 ]
  for body in '{"dependencies": {"pg-promise-x": "1", "mysql": "1"}}' '{"scripts": {"pg": "x"}}' \
    '{"peerDependencies": {"pg": "1"}}' 'not json' '[]' '{"dependencies": ["pg"]}'; do
    printf '%s\n' "$body" >"$f"
    run package_wants_database "$f"
    [ "$status" -eq 1 ] || {
      echo "database for $body"
      return 1
    }
  done
  run package_wants_database "$BATS_TEST_TMPDIR/missing.json"
  [ "$status" -eq 1 ]
}

# ask_database_with <package.json or ''> <answers>: runs the question with the branch's package.json
# stubbed, and prints DATABASE.
ask_database_with() {
  DEPLOY_TMP=$BATS_TEST_TMPDIR/tmp
  mkdir -p "$DEPLOY_TMP"
  if [ -n "$1" ]; then
    eval "repo_package_json() { cat '$1'; }"
  else
    # shellcheck disable=SC2329 # called by ask_database
    repo_package_json() { return 1; }
  fi
  ask_database <<<"$2"
  printf 'DATABASE=%s\n' "$DATABASE"
}

@test "database question: Enter takes the default from package.json" {
  command -v jq >/dev/null || skip "jq isn't installed"
  local f=$BATS_TEST_TMPDIR/package.json
  echo '{"dependencies": {"drizzle-orm": "1", "postgres": "3"}}' >"$f"
  run ask_database_with "$f" ''
  [ "$output" = DATABASE=tracklite ]
  run ask_database_with "$node_fixture/package.json" ''
  [ "$output" = DATABASE= ]
  run ask_database_with '' ''
  [ "$output" = DATABASE= ]
}

@test "database question: an answer overrides the default, and anything else is asked again" {
  command -v jq >/dev/null || skip "jq isn't installed"
  local f=$BATS_TEST_TMPDIR/package.json
  echo '{"dependencies": {"pg": "8"}}' >"$f"
  run ask_database_with "$f" 'n'
  [ "$output" = DATABASE= ]
  run ask_database_with "$fixture/package.json" $'maybe\nYes'
  [ "$output" = DATABASE=tracklite ]
}

@test "database question: fails with no answer to read" {
  DEPLOY_TMP=$BATS_TEST_TMPDIR
  repo_package_json() { return 1; }
  run --separate-stderr ask_database </dev/null
  [ "$status" -eq 1 ]
  [[ $stderr == *"Run it in a terminal."* ]]
}

@test "SQL quoting: identifiers and literals double their own quote character" {
  [ "$(sql_ident tracklite)" = '"tracklite"' ]
  [ "$(sql_ident 'a"b')" = '"a""b"' ]
  [ "$(sql_literal tracklite)" = "'tracklite'" ]
  [ "$(sql_literal "it's")" = "'it''s'" ]
  [ "$(sql_literal 'a"b')" = "'a\"b'" ]
}

@test "SQL: the role queries quote the name as a literal" {
  [ "$(sql_role_exists tracklite)" = "SELECT 1 FROM pg_roles WHERE rolname = 'tracklite';" ]
  [ "$(sql_database_owner user)" = "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = 'user';" ]
}

@test "SQL: the role is created with LOGIN and the password as a literal" {
  [ "$(sql_create_role user 0a1b)" = "CREATE ROLE \"user\" LOGIN PASSWORD '0a1b';" ]
}

@test "SQL: database creation, revoke connect and grant match the golden file" {
  matches database.sql sql_database tracklite tracklite
}

@test "SQL: names stay quoted inside the CREATE DATABASE string" {
  run sql_database app 'odd"db'
  [[ ${lines[0]} == "SELECT 'CREATE DATABASE \"odd\"\"db\" OWNER \"app\"' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'odd\"db')\\gexec" ]]
}

@test "DATABASE_URL uses TCP on loopback with the role's password" {
  [ "$(database_url tracklite 0123abcd tracklite)" = postgresql://tracklite:0123abcd@127.0.0.1:5432/tracklite ]
  check_env_value "$(database_url tracklite "$(db_password)" tracklite)"
}

@test "database password: 48 hex characters, different each time" {
  local a b
  a=$(db_password)
  b=$(db_password)
  [[ $a =~ ^[0-9a-f]{48}$ ]]
  [ "$a" != "$b" ]
}

# ---- MIGRATE -------------------------------------------------------------------------------------

@test "D3: zero config migrates only when package.json has a db:migrate script" {
  command -v jq >/dev/null || skip "jq isn't installed"
  local d=$BATS_TEST_TMPDIR/rel
  DEPLOY_TMP=$BATS_TEST_TMPDIR
  RELEASE=$fixture
  deploy_commands
  [ "$MIGRATE" = '' ]
  mkdir -p "$d"
  jq '.scripts["db:migrate"] = "drizzle-kit migrate"' "$fixture/package.json" >"$d/package.json"
  cp "$fixture/package-lock.json" "$d/"
  RELEASE=$d
  deploy_commands
  [ "$MIGRATE" = 'npm run db:migrate' ]
}

@test "zero config: db:migrate detection reads scripts only" {
  command -v jq >/dev/null || skip "jq isn't installed"
  local f=$BATS_TEST_TMPDIR/package.json
  run package_has_script "$node_fixture/package.json" db:migrate
  [ "$status" -eq 0 ]
  run package_has_script "$fixture/package.json" db:migrate
  [ "$status" -eq 1 ]
  echo '{"scripts": {"db:migrate:dev": "x"}, "db:migrate": "y"}' >"$f"
  run package_has_script "$f" db:migrate
  [ "$status" -eq 1 ]
}

@test "migrate: deploy.conf's MIGRATE runs with the env file's values, literally" {
  local d=$BATS_TEST_TMPDIR/rel
  mkdir -p "$d"
  printf '%s\n' 'MIGRATE="echo migrate \"\$DATABASE_URL\" on $PORT"' >"$d/deploy.conf"
  run env PORT=3005 bash -c "$MIGRATE_SCRIPT" migrate "$d" '' <<<'DATABASE_URL=postgresql://a:$(id)@127.0.0.1:5432/a'
  [ "$status" -eq 0 ]
  [ "$output" = $'== echo migrate "$DATABASE_URL" on 3005\nmigrate postgresql://a:$(id)@127.0.0.1:5432/a on 3005' ]
}

@test "migrate: zero config runs the default it's given, and nothing when there's none" {
  local d=$BATS_TEST_TMPDIR/rel
  mkdir -p "$d"
  run bash -c "$MIGRATE_SCRIPT" migrate "$d" 'echo zero-config' </dev/null
  [ "$output" = $'== echo zero-config\nzero-config' ]
  run bash -c "$MIGRATE_SCRIPT" migrate "$d" '' </dev/null
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # A deploy.conf without MIGRATE runs nothing, whatever root passed.
  printf '%s\n' 'INSTALL=i' >"$d/deploy.conf"
  run bash -c "$MIGRATE_SCRIPT" migrate "$d" '' </dev/null
  [ -z "$output" ]
}

# migrate_in <release>: runs D6 the way cmd_deploy does, with deploy_exit as the EXIT trap and the env
# file stubbed.
migrate_in() {
  set -o pipefail
  SHIPIT_OPT=$BATS_TEST_TMPDIR/opt
  RELEASE=$1
  DEPLOY_TMP=$BATS_TEST_TMPDIR/tmp
  BUILD_LOG=$BATS_TEST_TMPDIR/build.log
  mkdir -p "$DEPLOY_TMP"
  # shellcheck disable=SC2329 # called by deploy_migrate
  env_file_lines() { printf 'SECRET=x\n'; }
  trap deploy_exit EXIT
  deploy_migrate
}

# migrate_then_switch <release>: D6, then what a successful switch does, so deploy_exit keeps it.
migrate_then_switch() {
  migrate_in "$1"
  SWITCHED=1
}

@test "migrate: a failing migration deletes the new release and leaves current alone" {
  local opt=$BATS_TEST_TMPDIR/opt/$APP old new
  old=$opt/releases/20260101T000000Z-aaaaaaa
  new=$opt/releases/20260102T000000Z-bbbbbbb
  mkdir -p "$old" "$new"
  ln -s "$old" "$opt/current"
  printf '%s\n' 'MIGRATE="echo migrating; exit 3"' >"$new/deploy.conf"
  run --separate-stderr migrate_in "$new"
  [ "$status" -eq 1 ]
  [ "$stderr" = "Migrations failed, so nothing was switched. Still serving 20260101T000000Z-aaaaaaa. See $BATS_TEST_TMPDIR/build.log" ]
  [ ! -e "$new" ]
  [ -d "$old" ]
  [ "$(readlink "$opt/current")" = "$old" ]
  grep -qx migrating "$BATS_TEST_TMPDIR/build.log"
}

@test "migrate: a failing first migration deletes the release too" {
  local new=$BATS_TEST_TMPDIR/opt/$APP/releases/20260102T000000Z-bbbbbbb
  mkdir -p "$new"
  printf '%s\n' 'MIGRATE="false"' >"$new/deploy.conf"
  run --separate-stderr migrate_in "$new"
  [ "$status" -eq 1 ]
  [ "$stderr" = "Migrations failed, so nothing was switched. See $BATS_TEST_TMPDIR/build.log" ]
  [ ! -e "$new" ]
}

@test "migrate: a passing migration keeps the release" {
  local new=$BATS_TEST_TMPDIR/opt/$APP/releases/20260102T000000Z-bbbbbbb
  mkdir -p "$new"
  printf '%s\n' 'MIGRATE="echo \$SECRET"' >"$new/deploy.conf"
  run migrate_then_switch "$new"
  [ "$status" -eq 0 ]
  [ "$output" = $'== echo $SECRET\nx' ]
  [ -d "$new" ]
}
