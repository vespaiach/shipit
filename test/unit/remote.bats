#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2034,SC2030,SC2031 # single-quoted stub bodies; tests set lib variables, each in its own @test subshell
# lib/remote.sh (plan §5.4): parsing $SSH_ORIGINAL_COMMAND for the ci user's forced command, the
# refusals, and the call to cmd_deploy or cmd_rollback (stubbed here; deploy.bats and rollback.bats
# test those). Also the GitHub Actions examples against the plan.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  load_common
  # shellcheck source=lib/remote.sh
  . "$REPO_ROOT/lib/remote.sh"
  mkdir -p "$SHIPIT_ETC/sites"
  # Stand-ins for the real commands: print what they were called with.
  # shellcheck disable=SC2329 # called by cmd_remote
  cmd_deploy() { echo "cmd_deploy $*"; }
  # shellcheck disable=SC2329 # called by cmd_remote
  cmd_rollback() { echo "cmd_rollback $*"; }
  sha=0123456789abcdef0123456789abcdef01234567
}

# deployed <name>: a site whose first deploy succeeded.
deployed() {
  printf 'REPO=https://github.com/me/%s\nTYPE=static\nDOMAIN=%s.example.com\n' "$1" "$1" \
    >"$SHIPIT_ETC/sites/$1.conf"
}

# remote <name> <SSH_ORIGINAL_COMMAND>: runs cmd_remote as the forced command would.
remote() {
  SSH_ORIGINAL_COMMAND=$2 run --separate-stderr cmd_remote "$1"
}

# refused <name> <command>...: each command is refused, and nothing is run.
refused() {
  local name=$1 cmd
  shift
  for cmd; do
    remote "$name" "$cmd"
    [ "$status" -eq 1 ] && [ -z "$output" ] || {
      echo "not refused: ${cmd@Q} ($output)"
      return 1
    }
  done
}

# ---- Accepted commands ---------------------------------------------------------------------------

@test "deploy with a SHA, a branch, a tag-like name, or no ref" {
  deployed blog
  remote blog "deploy blog $sha"
  [ "$status" -eq 0 ]
  [ "$output" = "cmd_deploy blog $sha" ]
  remote blog 'deploy blog main'
  [ "$output" = 'cmd_deploy blog main' ]
  remote blog 'deploy blog release/v1.2.0'
  [ "$output" = 'cmd_deploy blog release/v1.2.0' ]
  remote blog 'deploy blog'
  [ "$status" -eq 0 ]
  [ "$output" = 'cmd_deploy blog' ]
}

@test "rollback" {
  deployed blog
  remote blog 'rollback blog'
  [ "$status" -eq 0 ]
  [ "$output" = 'cmd_rollback blog' ]
}

@test "remote_parse sets the command and its arguments" {
  remote_parse blog "deploy blog $sha"
  [ "$REMOTE_CMD" = deploy ]
  [ "${REMOTE_ARGS[*]}" = "blog $sha" ]
  remote_parse blog 'rollback blog'
  [ "$REMOTE_CMD" = rollback ]
  [ "${REMOTE_ARGS[*]}" = blog ]
}

# ---- Refused commands ----------------------------------------------------------------------------

@test "site A's key can't deploy or roll back site B" {
  deployed blog
  deployed api
  refused blog 'deploy api' "deploy api $sha" 'rollback api'
  remote blog 'deploy api main'
  [ "$stderr" = "This key belongs to the site blog, so it can't deploy or roll back api." ]
  remote blog 'rollback api'
  [ "$stderr" = "This key belongs to the site blog, so it can't deploy or roll back api." ]
  # Nor by a name that only starts or ends like its own.
  refused blog 'deploy blog2' 'rollback blo' 'deploy xblog'
}

@test "a ref starting with - is refused, even one git would take as an option" {
  deployed blog
  refused blog 'deploy blog --upload-pack=x' 'deploy blog -main' 'deploy blog --help' \
    'deploy blog -' 'deploy blog --'
  remote blog 'deploy blog -main'
  [ "$stderr" = "Invalid ref '-main': use a 40-character commit SHA or a branch name." ]
}

@test "refs git refuses are refused" {
  deployed blog
  refused blog 'deploy blog a..b' 'deploy blog main.lock' 'deploy blog /main' 'deploy blog main/' \
    'deploy blog .main'
}

@test "extra words, odd spacing, tabs, newlines, quotes and shell syntax are refused" {
  deployed blog
  refused blog 'deploy blog main extra' 'rollback blog main' 'deploy  blog' 'deploy blog  main' \
    ' deploy blog' 'deploy blog ' $'deploy\tblog' $'deploy blog\tmain' $'deploy blog\nrollback blog' \
    $'deploy blog\n' $'rollback blog\n' $'deploy blog main\r' 'deploy blog;id' 'deploy blog main;id' \
    'deploy blog $(id)' 'deploy blog `id`' 'deploy blog main&&id' 'deploy blog main|id' \
    "deploy blog 'main'" 'deploy blog "main"' 'deploy blog ma\in' 'deploy blog main@{1}' \
    'deploy blog HEAD~1' 'deploy blog main^' 'deploy blog ref:x' 'deploy "blog"' 'deploy Blog' \
    'deploy https://github.com/me/blog blog' 'DEPLOY blog' 'deploy' 'rollback'
  remote blog 'deploy blog $(id)'
  [ "$stderr" = "Refused the command 'deploy blog \$(id)'. This key can only run: deploy blog [<commit sha or branch>], or rollback blog." ]
}

@test "an unknown command is refused, listing what's allowed" {
  deployed blog
  refused blog 'status blog' 'setup' 'remote blog' 'sh' 'logs blog' 'git-upload-pack blog'
  remote blog 'sh -i'
  [ "$stderr" = "Refused the command 'sh -i'. This key can only run: deploy blog [<commit sha or branch>], or rollback blog." ]
}

@test "an empty or missing command (an interactive login) is refused, listing what's allowed" {
  deployed blog
  remote blog ''
  [ "$status" -eq 1 ]
  [ "$stderr" = "No command given. This key can only run: deploy blog [<commit sha or branch>], or rollback blog." ]
  unset SSH_ORIGINAL_COMMAND
  run --separate-stderr cmd_remote blog
  [ "$status" -eq 1 ]
  [[ $stderr == "No command given."* ]]
}

@test "a site whose first deploy never succeeded, or an unknown site, is refused" {
  printf 'REPO=https://github.com/me/blog\nPORT=3000\n' >"$SHIPIT_ETC/sites/blog.conf"
  remote blog 'deploy blog main'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "blog has never been deployed successfully. Its first deploy must be run by hand, as root: shipit deploy <repo-url> blog" ]
  remote api 'rollback api'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ $stderr == "There's no site named api."* ]]
}

@test "remote takes exactly one valid site name" {
  deployed blog
  SSH_ORIGINAL_COMMAND='deploy blog' run --separate-stderr cmd_remote
  [ "$status" -eq 1 ]
  [ "$stderr" = "$REMOTE_USAGE" ]
  SSH_ORIGINAL_COMMAND='deploy blog' run --separate-stderr cmd_remote blog extra
  [ "$stderr" = "$REMOTE_USAGE" ]
  SSH_ORIGINAL_COMMAND='deploy Blog' run --separate-stderr cmd_remote Blog
  [ "$status" -eq 1 ]
  [[ $stderr == "Invalid site name 'Blog'"* ]]
  [ -z "$output" ]
}

# ---- GitHub Actions examples ---------------------------------------------------------------------

# plan_yaml <n>: the n-th yaml code block of docs/plan.md.
plan_yaml() {
  awk -v n="$1" '/^```yaml$/ { i++; on = (i == n); next } /^```$/ { on = 0 } on' "$REPO_ROOT/docs/plan.md"
}

@test "examples/deploy.yml and rollback.yml are the plan's workflows" {
  diff <(plan_yaml 1) "$REPO_ROOT/examples/deploy.yml"
  diff <(plan_yaml 2) "$REPO_ROOT/examples/rollback.yml"
  grep -q '"ci@$VPS_HOST" deploy blog "$GITHUB_SHA"' "$REPO_ROOT/examples/deploy.yml"
  grep -q '"ci@$VPS_HOST" rollback blog$' "$REPO_ROOT/examples/rollback.yml"
}
