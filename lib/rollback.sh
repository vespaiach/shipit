# shellcheck shell=bash
# shipit rollback <app> (plan §3): switches current back to previous, holding the app lock, then checks
# health. It never rolls forward or touches the database. The steps are deploy.sh's switch_back, which
# HEALTH_FAIL=rollback also runs. Sourcing this file only defines constants and functions.

# shellcheck source=lib/deploy.sh
. "${BASH_SOURCE[0]%/*}/deploy.sh"

cmd_rollback() {
  local conf from to
  if [ "$#" -ne 1 ] || [ -z "$1" ] || [[ $1 == -* ]]; then die "Usage: sudo shipit rollback <app>"; fi
  check_app_name "$1" || exit 1
  APP=$1
  conf=$SHIPIT_ETC/apps/$APP.conf
  [ -e "$conf" ] || die "There's no app named $APP."
  DOMAIN=$(conf_get "$conf" DOMAIN) || exit 1
  PORT=$(conf_get "$conf" PORT) || exit 1
  { check_domain "$DOMAIN" "$APP" && check_port "$PORT" "$APP"; } || die "Fix $conf first."

  DEPLOY_TMP=$(mktemp -d)
  trap deploy_exit EXIT
  lock_try "$SHIPIT_VAR/$APP.lock" || die "Another deploy or rollback of $APP is running."
  DEPLOY_LOCKED=1
  to=$(previous_release) || die "No previous release to roll back to."
  from=$(readlink "$SHIPIT_OPT/$APP/current") || from=''
  DEPLOY_SHA=${to##*-}

  log "== Rolling back $APP to ${to##*/}"
  switch_back "$to"
  if health_wait; then
    DEPLOY_RESULT=rolled-back
    log "Rolled back to ${to##*/}; the database keeps ${from##*-}'s migrations."
    return 0
  fi
  DEPLOY_RESULT=rolled-back-unhealthy
  die "Rolled back to ${to##*/}; the database keeps ${from##*-}'s migrations." \
    "But ${HEALTH_PATH:-/} answered $HEALTH_CODE. Check: systemctl status '$APP@*'"
}
