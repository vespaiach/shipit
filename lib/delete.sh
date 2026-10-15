# shellcheck shell=bash
# shipit delete: removes a site and everything shipit keeps for it (plan §5.6), after the admin types
# the site's name. Under the site lock: the Caddy file (Caddy reloaded), the unit, the site's processes,
# its folders, env file and users, then <name>.conf last, so a delete that stops half-way is finished by
# running it again. Reuses lib/deploy.sh's helpers and state.
# Sourcing this file only defines constants and functions. Needs lib/common.sh.

# shellcheck source=lib/deploy.sh
. "${BASH_SOURCE[0]%/*}/deploy.sh"

DELETE_USAGE='Usage: shipit delete <name>'

# delete_args <arg>...: exactly one argument, a valid site name; sets SITE.
delete_args() {
  if [ "$#" -ne 1 ]; then
    err "$DELETE_USAGE"
    return 1
  fi
  SITE=$1
  check_site_name "$SITE"
}

# delete_confirm: says what goes and asks for the site's name on stdin (prompts on stderr). Anything
# else, or no input at all, refuses.
delete_confirm() {
  local answer data=$STATE_ROOT/shipit-$SITE what
  what="This deletes the site $SITE${CONF_DOMAIN:+ ($CONF_DOMAIN)}: its releases, repo, shipit.ini, env file, Caddy file, unit, cache and logs, and the users $SITE and $BUILD_USER"
  if [ -e "$data" ]; then
    err "$what, and its data in $data. It can't be undone, and shipit keeps no backup: copy the data first if you may need it."
  else
    err "$what. It can't be undone."
  fi
  printf 'Type %s to delete it: ' "$SITE" >&2
  if ! IFS= read -r answer && [ -z "$answer" ]; then
    err ''
    die "Nothing was deleted: there was no answer. Run it in a terminal (ssh -t), or pipe the name: echo $SITE | shipit delete $SITE"
  fi
  [ "$answer" = "$SITE" ] || die "Nothing was deleted: the answer wasn't $SITE."
}

# delete_caddy: removes the site's Caddy file, if it's shipit's, and reloads Caddy.
delete_caddy() {
  local file=$CADDY_ETC/sites/$SITE.caddy
  [ -e "$file" ] || return 0
  if ! is_shipit_file "$file"; then
    err "$file wasn't written by shipit, so it was left alone."
    return 0
  fi
  rm -f -- "$file" || die "Deleting $file failed."
  systemctl reload caddy || err "Reloading Caddy failed. Check: systemctl status caddy"
  log "Deleted $file and reloaded Caddy."
}

# delete_user <user> <comment>: deletes the user if shipit made it (its GECOS is <comment>).
delete_user() {
  case "$(user_state "$1" "$2")" in
    missing) ;;
    shipit)
      userdel "$1" || die "Deleting the user $1 failed."
      log "Deleted the user $1."
      ;;
    *) err "The user $1 wasn't created by shipit, so it was left alone." ;;
  esac
}

cmd_delete() {
  local unit path key
  delete_args "$@" || exit 1
  SITE_DIR=$SRV_ROOT/$SITE BUILD_USER=$SITE-build
  unit=$SYSTEMD_DIR/shipit-$SITE.service key=$SITE_DIR/.ssh/id_ed25519

  # An unknown site is refused before asking, and before the lock, so it leaves no lock file behind.
  site_conf_read "$SITE" || exit 1
  delete_confirm
  site_lock
  site_conf_read "$SITE" || exit 1

  delete_caddy
  if [ -e "$unit" ] && ! is_shipit_file "$unit"; then
    err "$unit wasn't written by shipit, so it was left alone."
  fi
  site_unit_remove
  # userdel refuses a user that still has processes (a build's leftovers, say).
  pkill -KILL -u "$BUILD_USER" 2>/dev/null || true
  pkill -KILL -u "$SITE" 2>/dev/null || true
  [ -e "$key" ] || key=''
  for path in "$SITE_DIR" "$STATE_ROOT/shipit-$SITE" "$CACHE_ROOT/shipit-$SITE" "$LOG_ROOT/$SITE" \
    "$SHIPIT_ETC/sites/$SITE.env"; do
    rm -rf -- "$path" || die "Deleting $path failed."
  done
  # The build user first: its primary group is <name>, which userdel <name> removes.
  delete_user "$BUILD_USER" "shipit build $SITE"
  delete_user "$SITE" "shipit site $SITE"
  # Last, so a delete that stopped half-way still knows the site and can be run again. The lock file
  # stays: a deploy waiting on it must not race one that would make a new file.
  rm -f -- "$SHIPIT_ETC/sites/$SITE.conf" || die "Deleting $SHIPIT_ETC/sites/$SITE.conf failed."
  LOCK_FD=$SITE_LOCK_FD
  lock_release
  log "Deleted $SITE."
  if [ -n "$key" ]; then
    log "Remove its deploy key from GitHub too: https://github.com/$(repo_slug "$CONF_REPO")/settings/keys"
  fi
}
