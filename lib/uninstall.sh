# shellcheck shell=bash
# shipit uninstall: removes shipit from the VPS (plan §5.7), after the admin types "uninstall": every
# site, as shipit delete deletes it (data and users included), then the files setup wrote, the old ci
# user (decision 68), shipit's own folders, and shipit itself. Packages stay installed, and ufw stays on.
# A file without the marker, or a user without shipit's GECOS, is left alone. Everything is skipped
# when it's already gone, so an uninstall that stopped half-way is finished by running it again.
# Sourcing this file only defines constants and functions. Needs lib/common.sh.

# shellcheck source=lib/delete.sh
. "${BASH_SOURCE[0]%/*}/delete.sh"

UNINSTALL_USAGE='Usage: shipit uninstall (it takes no arguments)'

# Where install.sh puts shipit.
INSTALL_DIR=/usr/local/lib/shipit
INSTALL_LINK=/usr/local/bin/shipit
# What setup made for CI before it was removed (decision 68).
SUDOERS_DIR=/etc/sudoers.d
CI_HOME=/home/ci

# uninstall_sites: sets SITES to the name of every site that has a <name>.conf.
uninstall_sites() {
  local conf name
  SITES=()
  for conf in "$SHIPIT_ETC"/sites/*.conf; do
    [ -e "$conf" ] || continue
    name=${conf##*/}
    name=${name%.conf}
    if check_site_name "$name" 2>/dev/null; then SITES+=("$name"); fi
  done
}

# uninstall_confirm: says what goes and asks for the word uninstall on stdin (prompts on stderr).
# Anything else, or no input at all, refuses.
uninstall_confirm() {
  local answer site data=()
  for site in "${SITES[@]}"; do
    [ ! -e "$STATE_ROOT/shipit-$site" ] || data+=("$STATE_ROOT/shipit-$site")
  done
  err "This uninstalls shipit. It deletes:"
  if [ "${#SITES[@]}" -gt 0 ]; then
    err "- the sites ${SITES[*]}, as shipit delete does: releases, repos, shipit.ini, env files, Caddy files, units, caches, logs, data and users"
  fi
  err "- shipit's Caddyfile (Caddy is stopped), fail2ban jail, unattended-upgrades file and SSH drop-in (password logins follow sshd's own settings again)" \
    "- the Caddy and NodeSource apt sources and keys (the packages stay installed, but get no more updates from those repos)" \
    "- the firewall's 80/tcp, 443/tcp and 443/udp rules (ufw stays on, SSH allowed)" \
    "- $SHIPIT_ETC, $SHIPIT_VAR, $LOG_ROOT, the old ci user, and shipit itself"
  if [ "${#data[@]}" -gt 0 ]; then
    err "Site data goes too: ${data[*]}. shipit keeps no backup: copy it first if you may need it."
  fi
  err "It can't be undone."
  printf 'Type uninstall to go on: ' >&2
  if ! IFS= read -r answer && [ -z "$answer" ]; then
    err ''
    die "Nothing was removed: there was no answer. Run it in a terminal (ssh -t), or pipe the answer: echo uninstall | shipit uninstall"
  fi
  [ "$answer" = uninstall ] || die "Nothing was removed: the answer wasn't uninstall."
}

# uninstall_file <file>: deletes the file if shipit wrote it. Fails when there was nothing of shipit's
# to delete.
uninstall_file() {
  [ -e "$1" ] || return 1
  if ! is_shipit_file "$1"; then
    err "$1 wasn't written by shipit, so it was left alone."
    return 1
  fi
  rm -f -- "$1" || die "Deleting $1 failed."
  log "Deleted $1."
}

# uninstall_host: undoes setup (plan §5.1), except the packages and ufw itself.
uninstall_host() {
  local rule file
  # The sites are gone; this catches a Caddy file whose site isn't (a .conf deleted by hand, say).
  for file in "$CADDY_ETC"/sites/*.caddy; do
    [ ! -e "$file" ] || uninstall_file "$file" || true
  done
  if uninstall_file "$CADDY_ETC/Caddyfile"; then
    systemctl disable --now --quiet caddy || err "Stopping Caddy failed. Check: systemctl status caddy"
    log "Stopped and disabled Caddy: its config was shipit's."
  fi
  # Only if it's empty: a file in it that shipit didn't write stays.
  rmdir -- "$CADDY_ETC/sites" 2>/dev/null || true
  if uninstall_file "$FAIL2BAN_ETC/jail.d/shipit-sshd.conf"; then
    systemctl reload fail2ban || err "Reloading fail2ban failed. Check: systemctl status fail2ban"
  fi
  uninstall_file "$APT_ETC/apt.conf.d/52shipit-auto-upgrades" || true
  if uninstall_file "$SSH_ETC/sshd_config.d/10-shipit.conf"; then
    systemctl reload ssh || err "Reloading ssh failed. Check: sshd -t"
    log "SSH password logins follow sshd's own settings again."
  fi
  # A key has no marker: it goes with the source file that uses it.
  if uninstall_file "$APT_ETC/sources.list.d/caddy-stable.list"; then
    rm -f -- "$APT_ETC/keyrings/caddy-stable-archive-keyring.gpg"
  fi
  if uninstall_file "$APT_ETC/sources.list.d/nodesource.list"; then
    rm -f -- "$APT_ETC/keyrings/nodesource.gpg"
  fi
  uninstall_file "$APT_ETC/preferences.d/shipit-nodejs" || true
  if command -v ufw >/dev/null; then
    for rule in 80/tcp 443/tcp 443/udp; do
      ufw delete allow "$rule" >/dev/null || err "ufw delete allow $rule failed. Check: ufw status"
    done
    log "Removed the firewall's 80/tcp, 443/tcp and 443/udp rules; ufw stays on, with SSH allowed."
  fi
}

# uninstall_ci: the ci user and its sudoers rule, left on a VPS set up before CI was removed.
uninstall_ci() {
  uninstall_file "$SUDOERS_DIR/shipit-ci" || true
  [ "$(user_state ci 'shipit ci')" = shipit ] || return 0
  pkill -KILL -u ci 2>/dev/null || true
  userdel ci || die "Deleting the user ci failed."
  rm -rf -- "$CI_HOME" || die "Deleting $CI_HOME failed."
  log "Deleted the user ci and $CI_HOME."
}

# uninstall_self: the installed copy, and the link to it.
uninstall_self() {
  if [ -L "$INSTALL_LINK" ] && [ "$(readlink -- "$INSTALL_LINK")" = "$INSTALL_DIR/bin/shipit" ]; then
    rm -f -- "$INSTALL_LINK" || die "Deleting $INSTALL_LINK failed."
    log "Deleted $INSTALL_LINK."
  fi
  [ -e "$INSTALL_DIR" ] || return 0
  rm -rf -- "$INSTALL_DIR" || die "Deleting $INSTALL_DIR failed."
  log "Deleted $INSTALL_DIR."
}

cmd_uninstall() {
  local site path
  if [ "$#" -gt 0 ]; then
    err "$UNINSTALL_USAGE"
    exit 1
  fi
  uninstall_sites
  uninstall_confirm
  # Each site's .conf goes last, so a rerun still finds the sites that weren't finished.
  for site in "${SITES[@]}"; do
    SITE=$site SITE_DIR=$SRV_ROOT/$site BUILD_USER=$site-build
    delete_site
  done
  uninstall_host
  uninstall_ci
  for path in "$SHIPIT_ETC" "$SHIPIT_VAR" "$LOG_ROOT"; do
    rm -rf -- "$path" || die "Deleting $path failed."
  done
  # Last. The libraries are already read, and bash keeps reading bin/shipit through its open file.
  uninstall_self
  log "Uninstalled shipit. The packages setup installed (caddy, nodejs, corepack, ufw, fail2ban, unattended-upgrades, jq, git, acl, ...) are still there; remove the ones you don't need with apt-get purge."
}
