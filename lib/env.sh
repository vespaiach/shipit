# shellcheck shell=bash
# shipit env <app> (plan §3): edits a private copy of /etc/<app>/env in $EDITOR (nano when it's unset),
# checks every line the way systemd and the build read the file (env_file_lines), installs it as
# root:root 600 only if it changed, then restarts <app>.target. Holds the app lock, so it can't race a
# deploy or rollback. Sourcing this file only defines constants and functions.

# shellcheck source=lib/deploy.sh
. "${BASH_SOURCE[0]%/*}/deploy.sh"

ENV_TMP=''

# env_edit <file>: opens the file in the editor. EDITOR may carry arguments (like "code -w").
env_edit() {
  # shellcheck disable=SC2086 # EDITOR is split into the command and its arguments on purpose
  ${EDITOR:-nano} "$1"
}

# env_check_reserved <file> <name>: refuses PORT and NODE_ENV. The unit sets them, and systemd lets
# EnvironmentFile= override Environment=, so a value here would move the app off its port.
env_check_reserved() {
  local key
  for key in PORT NODE_ENV; do
    if grep -q "^$key=" "$1"; then
      err "$2: remove $key. shipit sets it in the app's unit."
      return 1
    fi
  done
}

# env_edit_until_valid <copy> <env file>: edits the copy until every line passes, asking after each
# refusal whether to edit again. Fails, with the env file untouched, when the answer is no.
env_edit_until_valid() {
  local answer
  while :; do
    env_edit "$1" || die "The editor failed, so $2 wasn't changed."
    env_file_lines "$1" "$2" >/dev/null && env_check_reserved "$1" "$2" && return 0
    ask "Edit it again? [Y/n] " answer || die "$2 wasn't changed."
    case $answer in
      '' | [Yy] | [Yy][Ee][Ss]) ;;
      *) die "$2 wasn't changed." ;;
    esac
  done
}

# env_install <new file> <env file>: installs the new file as root:root 600 if it differs, then
# restarts the app. Says so when nothing changed.
env_install() {
  if ! install_if_changed "$1" "$2" 600; then
    log "No changes, so $2 and $APP are as they were."
    return 0
  fi
  chown root:root "$2"
  log "Wrote $2."
  systemctl restart "$APP.target" || die "Restarting $APP.target failed. Check: systemctl status '$APP@*'"
  log "Restarted $APP.target. Check it with: sudo shipit status $APP"
}

env_exit() {
  [ -z "$ENV_TMP" ] || rm -rf -- "$ENV_TMP"
}

cmd_env() {
  local file copy
  if [ "$#" -ne 1 ] || [ -z "$1" ] || [[ $1 == -* ]]; then die "Usage: sudo shipit env <app>"; fi
  check_app_name "$1" || exit 1
  APP=$1
  [ -e "$SHIPIT_ETC/apps/$APP.conf" ] || die "There's no app named $APP."
  file=/etc/$APP/env
  [ -f "$file" ] || die "$file doesn't exist yet. Deploy the app first: sudo shipit deploy $APP"
  lock_try "$SHIPIT_VAR/$APP.lock" || die "Another deploy or rollback of $APP is running."

  # A private copy: mktemp -d makes a folder only root can enter, and the copy is 600.
  ENV_TMP=$(mktemp -d)
  trap env_exit EXIT
  copy=$ENV_TMP/env
  install -m 600 "$file" "$copy"
  env_edit_until_valid "$copy" "$file"
  env_install "$copy" "$file"
}
