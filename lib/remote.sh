# shellcheck shell=bash
# shipit remote <name> (internal, run only by the ci user's forced command, plan §5.4): parses the
# command CI sent over SSH ($SSH_ORIGINAL_COMMAND, the one value shipit reads from the environment) and
# runs deploy or rollback in this process, for the key's own site only.
# Sourcing this file only defines constants and functions. Needs lib/common.sh.

# shellcheck source=lib/rollback.sh
. "${BASH_SOURCE[0]%/*}/rollback.sh"

REMOTE_USAGE="Usage: shipit remote <name>. Only the ci user's SSH keys run it, as their forced command."

# The parsed command: deploy or rollback, and the arguments to call cmd_<command> with.
REMOTE_CMD='' REMOTE_ARGS=()

# remote_parse <key's site> <command>: accepts exactly `deploy <site> [ref]` or `rollback <site>`,
# single spaces between words, nothing else. The ref is a 40-hex SHA or a branch or tag made only of
# letters, digits and . _ / - (and check_ref's rule). Sets REMOTE_CMD and REMOTE_ARGS.
remote_parse() {
  local LC_ALL=C site=$1 cmd=$2 name ref='' allowed
  allowed="This key can only run: deploy $site [<commit sha or branch>], or rollback $site."
  REMOTE_CMD='' REMOTE_ARGS=()
  if [ -z "$cmd" ]; then
    err "No command given. $allowed"
    return 1
  fi
  if [[ $cmd =~ ^deploy\ ([a-z][a-z0-9-]*)(\ ([A-Za-z0-9._/-]+))?$ ]]; then
    REMOTE_CMD=deploy name=${BASH_REMATCH[1]} ref=${BASH_REMATCH[3]}
  elif [[ $cmd =~ ^rollback\ ([a-z][a-z0-9-]*)$ ]]; then
    REMOTE_CMD=rollback name=${BASH_REMATCH[1]}
  else
    err "Refused the command ${cmd@Q}. $allowed"
    return 1
  fi
  if [ "$name" != "$site" ]; then
    err "This key belongs to the site $site, so it can't deploy or roll back $name."
    return 1
  fi
  REMOTE_ARGS=("$site")
  if [ -n "$ref" ]; then
    check_ref "$ref" || return 1
    REMOTE_ARGS+=("$ref")
  fi
}

cmd_remote() {
  if [ "$#" -ne 1 ]; then
    err "$REMOTE_USAGE"
    exit 1
  fi
  check_site_name "$1" || exit 1
  remote_parse "$1" "${SSH_ORIGINAL_COMMAND-}" || exit 1
  site_conf_read "$1" || exit 1
  [ -n "$CONF_TYPE" ] \
    || die "$1 has never been deployed successfully. Its first deploy must be run by hand, as root: shipit deploy <repo-url> $1"
  "cmd_$REMOTE_CMD" "${REMOTE_ARGS[@]}"
}
