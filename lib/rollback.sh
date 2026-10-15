# shellcheck shell=bash
# shipit rollback: goes back exactly one release (plan §5.3): swaps current and previous, renders the
# config from the new current (site_apply_config, plan §5.5), restarts and health-checks it
# (site_restart_and_check), and swaps back if either fails. Reuses lib/deploy.sh's helpers and state.
# Sourcing this file only defines constants and functions. Needs lib/common.sh.

# shellcheck source=lib/deploy.sh
. "${BASH_SOURCE[0]%/*}/deploy.sh"

ROLLBACK_USAGE='Usage: shipit rollback <name>'

# rollback_args <arg>...: exactly one argument, a valid site name; sets SITE.
rollback_args() {
  if [ "$#" -ne 1 ]; then
    err "$ROLLBACK_USAGE"
    return 1
  fi
  SITE=$1
  check_site_name "$SITE"
}

# rollback_links <current> <previous>: points the two links at the releases given, previous first, as
# deploy does (C.1): a crash in between leaves current, and the config rendered from it, as they were.
rollback_links() {
  atomic_link "$2" "$SITE_DIR/previous" && atomic_link "$1" "$SITE_DIR/current"
}

# rollback_revert <reason>: puts current and previous back, re-renders the config from the original
# current and restarts it (best effort, reporting a failure), then exits non-zero.
rollback_revert() {
  rollback_links "$OLD_CURRENT" "$OLD_PREVIOUS" \
    || die "Switching the links back failed. Fix them by hand: current -> $OLD_CURRENT, previous -> $OLD_PREVIOUS."
  if ! site_apply_config; then
    err "Installing the config of ${OLD_CURRENT#releases/} again failed too; fix the error above."
  elif ! site_restart_and_check; then
    err "${OLD_CURRENT#releases/} didn't come back up either; fix the error above."
  fi
  die "$1; still serving ${OLD_CURRENT#releases/}."
}

cmd_rollback() {
  rollback_args "$@" || exit 1
  SITE_DIR=$SRV_ROOT/$SITE BUILD_USER=$SITE-build
  DEPLOY_TMP=$(mktemp -d) || die "Couldn't make a temp folder."
  trap deploy_exit EXIT
  # caddy validates the site's Caddy file from here as the caddy user. Nothing in it is secret.
  chmod 755 "$DEPLOY_TMP"

  # An unknown site is refused before the lock, so it leaves no lock file behind.
  [ -e "$SHIPIT_ETC/sites/$SITE.conf" ] || site_conf_read "$SITE" || exit 1
  site_lock
  site_conf_read "$SITE" || exit 1
  [ -n "$CONF_TYPE" ] || die "$SITE has never been deployed successfully, so there's nothing to roll back to."
  OLD_CURRENT=$(link_target "$SITE_DIR/current") || exit 1
  OLD_PREVIOUS=$(link_target "$SITE_DIR/previous") || exit 1
  [ -n "$OLD_CURRENT" ] || die "$SITE_DIR/current is missing. Deploy $SITE again: shipit deploy $SITE"
  if [ -z "$OLD_PREVIOUS" ] || [ "$OLD_PREVIOUS" = "$OLD_CURRENT" ] || [ ! -d "$SITE_DIR/$OLD_PREVIOUS" ]; then
    die "$SITE has no previous release to roll back to."
  fi

  log "Rolling back $SITE to ${OLD_PREVIOUS#releases/}."
  rollback_links "$OLD_PREVIOUS" "$OLD_CURRENT" || rollback_revert "Rollback failed: switching the links failed"
  site_apply_config || rollback_revert "Rollback failed: the previous release's config couldn't be installed"
  site_restart_and_check || rollback_revert "Rollback failed health check"
  LOCK_FD=$SITE_LOCK_FD
  lock_release
  log "Rolled back $SITE: now serving ${OLD_PREVIOUS#releases/}."
}
