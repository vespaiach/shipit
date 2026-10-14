# shellcheck shell=bash
# shipit setup (plan §3): prepares a Debian 13 VPS once. Every step checks before it acts, so a
# re-run changes no file. Sourcing this file only defines constants and functions.

NODE_INDEX_URL=https://nodejs.org/dist/index.json
GITHUB_META_URL=https://api.github.com/meta
CADDY_KEY_URL=https://dl.cloudsmith.io/public/caddy/stable/gpg.key
NODESOURCE_KEY_URL=https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key
SSHD_DROPIN=/etc/ssh/sshd_config.d/10-shipit.conf

# Debian packages setup needs before it adds the PGDG, Cloudsmith and NodeSource repos.
BASE_PACKAGES=(ca-certificates curl gnupg git jq gettext-base nftables unattended-upgrades
  postgresql-common sudo logrotate)

# What this run changed, and what to say at the end (filled in by the steps).
SETUP_CHANGES=()
SETUP_NOTES=()
SSH_HARDENED=''

note_change() { SETUP_CHANGES+=("$1"); }
note() { SETUP_NOTES+=("$1"); }

# ---- Small parsers and checks (unit-tested) ------------------------------------------------------

# is_debian13 <os-release file>
is_debian13() {
  grep -qx 'ID=debian' "$1" 2>/dev/null && grep -Eqx 'VERSION_ID="?13"?' "$1"
}

# meminfo_kb <field> <meminfo file>: prints the field's value in kB.
meminfo_kb() {
  awk -v f="$1:" '$1 == f { print $2; found = 1 } END { exit !found }' "$2"
}

# swap_size_for_ram <MemTotal in kB>: 4 GB of swap below 6 GB of RAM, 2 GB otherwise.
swap_size_for_ram() {
  if [ "$1" -lt $((6 * 1024 * 1024)) ]; then echo 4G; else echo 2G; fi
}

# low_memory <meminfo file>: succeeds when RAM plus swap is below 4 GB.
low_memory() {
  local ram swap
  ram=$(meminfo_kb MemTotal "$1") || return 1
  swap=$(meminfo_kb SwapTotal "$1") || return 1
  [ $((ram + swap)) -lt $((4 * 1024 * 1024)) ]
}

# node_lts_major: reads nodejs.org's dist/index.json on stdin and prints the newest LTS major version.
node_lts_major() {
  local major
  major=$(jq -r '[.[] | select(.lts) | .version | ltrimstr("v") | split(".")[0] | tonumber] | max') \
    || return 1
  [[ $major =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s\n' "$major"
}

# sshd_ports: reads `sshd -T` on stdin and prints the listening ports as "22" or "22, 2222".
sshd_ports() {
  awk '$1 == "port" && $2 ~ /^[0-9]+$/ { p = p (p ? ", " : "") $2 } END { if (!p) exit 1; print p }'
}

# session_used_key <pid>...: reads sshd's journal lines on stdin. Succeeds if one of the pids (this
# process's ancestors, so the sshd-session that started this login) logged "Accepted publickey".
# grep reads everything (no -q), so the writer never gets SIGPIPE under pipefail.
session_used_key() {
  local pids
  [ "$#" -gt 0 ] || return 1
  pids=$(
    IFS='|'
    printf '%s' "$*"
  )
  grep -E " sshd(-session)?\[($pids)\]: Accepted publickey for " >/dev/null
}

# ancestor_pids: this process and every parent up to (not including) init, one per line.
ancestor_pids() {
  local pid=$$
  while [[ $pid =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ]; do
    printf '%s\n' "$pid"
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') || return 0
  done
}

# github_known_hosts: reads api.github.com/meta on stdin and prints a known_hosts line per SSH key.
github_known_hosts() {
  local keys key count=0
  keys=$(jq -r '.ssh_keys[]') || return 1
  while IFS= read -r key; do
    [[ $key =~ ^(ssh-ed25519|ecdsa-sha2-nistp256|ssh-rsa)\ [A-Za-z0-9+/]+=*$ ]] || return 1
    printf 'github.com %s\n' "$key"
    count=$((count + 1))
  done <<<"$keys"
  [ "$count" -gt 0 ]
}

# merge_known_hosts <known_hosts file> <github lines file>: the file's other lines, then GitHub's.
merge_known_hosts() {
  if [ -f "$1" ]; then grep -Ev '^github\.com[ ,]' "$1" || true; fi
  cat "$2"
}

# is_package_default <file> <package>: the file is the package's conffile, unmodified.
is_package_default() {
  local sum
  sum=$(dpkg-query -W -f='${Conffiles}\n' "$2" 2>/dev/null | awk -v f="$1" '$1 == f { print $2 }')
  [ -n "$sum" ] && [ "$(md5sum <"$1" | cut -d' ' -f1)" = "$sum" ]
}

# is_replaceable <file> <package>: shipit may overwrite the file if it's missing, marked as shipit's,
# or still the package's untouched default (a fresh VPS ships stock nftables.conf and Caddyfile).
is_replaceable() {
  [ ! -e "$1" ] || is_shipit_file "$1" || is_package_default "$1" "$2"
}

# render_caddyfile: the root Caddyfile. With no ACME_EMAIL, the global options block (which holds
# only the email line) is left out of the template before rendering.
render_caddyfile() {
  local tpl=$SHIPIT_TEMPLATES/Caddyfile
  if [ -n "$ACME_EMAIL" ]; then
    render "$tpl" ACME_EMAIL
  else
    render <(sed '/^{$/,/^}$/d' "$tpl")
  fi
}

# render_sshd_conf: the drop-in. Root keeps key-only login when it's the admin; otherwise it's off.
render_sshd_conf() {
  local PERMIT_ROOT_LOGIN=no
  # shellcheck disable=SC2034 # render reads it by name
  [ "$ADMIN_USER" != root ] || PERMIT_ROOT_LOGIN=prohibit-password
  render "$SHIPIT_TEMPLATES/sshd.conf" PERMIT_ROOT_LOGIN
}

host_conf_text() {
  printf '%s\n' \
    "# Written by the first \`shipit setup\` and only read after that. No secrets." \
    "ACME_EMAIL=$ACME_EMAIL" \
    "ADMIN_USER=$ADMIN_USER" \
    "NODE_MAJOR=$NODE_MAJOR" \
    "SWAP_SIZE=$SWAP_SIZE" \
    "BACKUP_KEEP=14" \
    "LOG_KEEP_DAYS=14" \
    "MIN_FREE_DISK_GB=3" \
    "EXTRA_PACKAGES="
}

# load_host_conf <file>: reads and validates the values setup uses.
load_host_conf() {
  local var value
  for var in ACME_EMAIL ADMIN_USER NODE_MAJOR SWAP_SIZE LOG_KEEP_DAYS EXTRA_PACKAGES; do
    value=$(conf_get "$1" "$var") || return 1
    printf -v "$var" '%s' "$value"
  done
  if ! { [ -z "$ACME_EMAIL" ] || check_email "$ACME_EMAIL"; } \
    || ! check_admin_user "$ADMIN_USER" \
    || ! check_number NODE_MAJOR "$NODE_MAJOR" \
    || ! check_number LOG_KEEP_DAYS "$LOG_KEEP_DAYS" \
    || ! { [ -z "$EXTRA_PACKAGES" ] || check_packages "$EXTRA_PACKAGES"; } \
    || ! [[ $SWAP_SIZE =~ ^[1-9][0-9]*G$ ]]; then
    err "Fix $1 (SWAP_SIZE looks like 4G), then re-run sudo shipit setup."
    return 1
  fi
}

ask_host_questions() {
  while :; do
    ask 'Email for TLS certificate notices (blank for none): ' ACME_EMAIL || return 1
    if [ -z "$ACME_EMAIL" ] || check_email "$ACME_EMAIL"; then break; fi
  done
  while :; do
    ask 'Admin username [root]: ' ADMIN_USER || return 1
    ADMIN_USER=${ADMIN_USER:-root}
    if check_admin_user "$ADMIN_USER"; then break; fi
  done
}

# ---- Host helpers --------------------------------------------------------------------------------

apt_get() {
  DEBIAN_FRONTEND=noninteractive apt-get -q -y -o Dpkg::Options::=--force-confold "$@"
}

missing_packages() {
  local p
  for p in "$@"; do
    [ "$(dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null)" = installed ] || printf '%s\n' "$p"
  done
}

# install_packages <package>...: installs the missing ones.
install_packages() {
  local missing
  mapfile -t missing < <(missing_packages "$@")
  [ "${#missing[@]}" -gt 0 ] || return 0
  apt_get update >/dev/null || die "apt-get update failed. Fix the network or apt sources, then re-run sudo shipit setup."
  apt_get install "${missing[@]}" || die "Installing ${missing[*]} failed. Re-run sudo shipit setup to continue."
  note_change "Installed ${missing[*]}"
}

# fetch_keyring <url> <dest>: downloads an armored apt signing key, once.
fetch_keyring() {
  [ ! -s "$2" ] || return 0
  curl -fsSL "$1" | gpg --batch --yes --dearmor -o "$SETUP_TMP/keyring" \
    || die "Couldn't download the apt key from $1. Check the network, then re-run sudo shipit setup."
  install -m 644 "$SETUP_TMP/keyring" "$2"
  note_change "Added $2"
}

# ---- Steps ---------------------------------------------------------------------------------------

setup_host_conf() {
  local conf=$SHIPIT_ETC/host.conf mem
  install -d -m 755 "$SHIPIT_ETC" "$SHIPIT_ETC/apps"
  if [ ! -e "$conf" ]; then
    ask_host_questions || die "setup needs answers to its questions. Run it in a terminal."
    install_packages curl jq ca-certificates
    NODE_MAJOR=$(curl -fsSL "$NODE_INDEX_URL" | node_lts_major) \
      || die "Couldn't find the current Node.js LTS version at $NODE_INDEX_URL. Check the network, then re-run sudo shipit setup."
    mem=$(meminfo_kb MemTotal /proc/meminfo) || die "Couldn't read MemTotal from /proc/meminfo."
    SWAP_SIZE=$(swap_size_for_ram "$mem")
    host_conf_text >"$SETUP_TMP/host.conf"
    install -m 644 "$SETUP_TMP/host.conf" "$conf"
    note_change "Wrote $conf (Node $NODE_MAJOR, swap $SWAP_SIZE, admin $ADMIN_USER)"
  fi
  load_host_conf "$conf" || exit 1
}

setup_packages() {
  local lists_changed='' installed_major
  install_packages "${BASE_PACKAGES[@]}"
  # shellcheck disable=SC2086 # split on spaces; check_packages allows no glob characters
  [ -z "$EXTRA_PACKAGES" ] || install_packages $EXTRA_PACKAGES

  if ! compgen -G '/etc/apt/sources.list.d/pgdg.*' >/dev/null; then
    /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y >/dev/null \
      || die "Adding the PostgreSQL (PGDG) apt repository failed. Re-run sudo shipit setup to continue."
    note_change "Added the PostgreSQL (PGDG) apt repository"
  fi

  fetch_keyring "$CADDY_KEY_URL" /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  printf '%s\n' "$MANAGED_MARKER" \
    'deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main' \
    >"$SETUP_TMP/caddy.list"
  if install_if_changed "$SETUP_TMP/caddy.list" /etc/apt/sources.list.d/caddy-stable.list 644; then
    lists_changed=1
    note_change "Added the Caddy (Cloudsmith) apt repository"
  fi

  fetch_keyring "$NODESOURCE_KEY_URL" /usr/share/keyrings/nodesource.gpg
  printf '%s\n' "$MANAGED_MARKER" \
    "deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main" \
    >"$SETUP_TMP/nodesource.list"
  if install_if_changed "$SETUP_TMP/nodesource.list" /etc/apt/sources.list.d/nodesource.list 644; then
    lists_changed=1
    note_change "Added the Node.js $NODE_MAJOR (NodeSource) apt repository"
  fi
  # Prefer NodeSource's nodejs over Debian's.
  printf '%s\n' "$MANAGED_MARKER" 'Package: nodejs' 'Pin: origin deb.nodesource.com' 'Pin-Priority: 600' \
    >"$SETUP_TMP/nodejs.pref"
  install_if_changed "$SETUP_TMP/nodejs.pref" /etc/apt/preferences.d/shipit-nodejs 644 || true

  if [ -n "$lists_changed" ]; then
    apt_get update >/dev/null || die "apt-get update failed. Re-run sudo shipit setup to continue."
  fi
  install_packages postgresql-18 caddy nodejs
  # A changed NODE_MAJOR in host.conf moves nodejs to that major.
  installed_major=$(node --version 2>/dev/null) || true
  installed_major=${installed_major#v}
  if [ "${installed_major%%.*}" != "$NODE_MAJOR" ]; then
    apt_get install nodejs || die "Installing Node.js $NODE_MAJOR failed. Re-run sudo shipit setup to continue."
    note_change "Installed Node.js $NODE_MAJOR"
  fi
}

setup_swap() {
  if [ -z "$(swapon --show --noheadings)" ]; then
    rm -f /swapfile
    if ! { fallocate -l "$SWAP_SIZE" /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null \
      && swapon /swapfile; }; then
      die "Creating /swapfile failed. Re-run sudo shipit setup to continue."
    fi
    note_change "Created a $SWAP_SIZE swap file at /swapfile"
  fi
  if awk '$1 == "/swapfile" { found = 1 } END { exit !found }' /proc/swaps \
    && ! grep -Eq '^/swapfile[[:space:]]' /etc/fstab; then
    printf '/swapfile none swap sw 0 0\n' >>/etc/fstab
    note_change "Added /swapfile to /etc/fstab"
  fi
}

setup_users() {
  local home group
  if ! id "$DEPLOY_USER" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "/home/$DEPLOY_USER" --shell /usr/sbin/nologin "$DEPLOY_USER"
    note_change "Created the $DEPLOY_USER account"
  fi
  [ "$ADMIN_USER" != root ] || return 0

  if ! id "$ADMIN_USER" >/dev/null 2>&1; then
    # No password is set, so the account logs in with a key only.
    useradd --create-home --shell /bin/bash "$ADMIN_USER"
    note_change "Created the admin account $ADMIN_USER"
    if [ -s /root/.ssh/authorized_keys ]; then
      home=$(user_home "$ADMIN_USER")
      group=$(id -gn "$ADMIN_USER")
      install -d -m 700 -o "$ADMIN_USER" -g "$group" "$home/.ssh"
      install -m 600 -o "$ADMIN_USER" -g "$group" /root/.ssh/authorized_keys "$home/.ssh/authorized_keys"
      note_change "Copied root's SSH keys to $ADMIN_USER"
    fi
  fi

  render "$SHIPIT_TEMPLATES/sudoers" ADMIN_USER >"$SETUP_TMP/sudoers" || exit 1
  visudo -cqf "$SETUP_TMP/sudoers" || die "The rendered sudoers file didn't pass visudo -c, so it wasn't installed."
  if install_if_changed "$SETUP_TMP/sudoers" /etc/sudoers.d/shipit-admin 440; then
    note_change "Gave $ADMIN_USER password-less sudo (/etc/sudoers.d/shipit-admin)"
  fi
}

setup_github_keys() {
  local meta
  meta=$(curl -fsSL "$GITHUB_META_URL") \
    || die "Couldn't download GitHub's SSH host keys from $GITHUB_META_URL. Check the network, then re-run sudo shipit setup."
  printf '%s\n' "$meta" | github_known_hosts >"$SETUP_TMP/github.keys" \
    || die "$GITHUB_META_URL didn't list usable SSH host keys, so they weren't pinned. Re-run sudo shipit setup later."
  merge_known_hosts /etc/ssh/ssh_known_hosts "$SETUP_TMP/github.keys" >"$SETUP_TMP/known_hosts"
  if install_if_changed "$SETUP_TMP/known_hosts" /etc/ssh/ssh_known_hosts 644; then
    note_change "Pinned GitHub's SSH host keys in /etc/ssh/ssh_known_hosts"
  fi
}

setup_firewall() {
  local conf=/etc/nftables.conf SSH_PORTS
  if ! is_replaceable "$conf" nftables; then
    note "Left $conf alone, because shipit didn't write it. Make sure it allows SSH, TCP 80 and 443, and UDP 443."
    return 0
  fi
  SSH_PORTS=$(sshd -T 2>/dev/null | sshd_ports) \
    || die "Couldn't read the SSH port from sshd -T, so the firewall wasn't changed. Check that sshd's config is valid, then re-run sudo shipit setup."
  render "$SHIPIT_TEMPLATES/nftables.conf" SSH_PORTS >"$SETUP_TMP/nftables.conf" || exit 1
  nft -c -f "$SETUP_TMP/nftables.conf" || die "The firewall rules didn't pass nft -c, so $conf wasn't changed."
  if install_if_changed "$SETUP_TMP/nftables.conf" "$conf" 755; then
    if ! { systemctl enable --now --quiet nftables && systemctl reload nftables; }; then
      die "Loading the firewall failed. Check: systemctl status nftables"
    fi
    note_change "Turned on the firewall ($conf: SSH on $SSH_PORTS, 80, 443)"
  else
    systemctl enable --now --quiet nftables || die "Starting the firewall failed. Check: systemctl status nftables"
  fi
}

# SSH hardening needs both a key in the admin's authorized_keys and a key login for this session, so
# it can't lock out the person running it.
setup_ssh_hardening() {
  local home pids reason=''
  home=$(user_home "$ADMIN_USER")
  if [ ! -s "$home/.ssh/authorized_keys" ]; then
    reason="$ADMIN_USER has no SSH key in $home/.ssh/authorized_keys"
  else
    mapfile -t pids < <(ancestor_pids)
    journalctl -b -q --no-pager -o short -t sshd -t sshd-session 2>/dev/null | session_used_key "${pids[@]}" \
      || reason="this session didn't log in with an SSH key"
  fi
  if [ -n "$reason" ]; then
    note "Skipped SSH hardening: $reason. Fix that, then re-run sudo shipit setup."
    return 0
  fi

  render_sshd_conf >"$SETUP_TMP/sshd.conf" || exit 1
  sshd -t -f "$SETUP_TMP/sshd.conf" || die "The SSH drop-in didn't pass sshd -t, so it wasn't installed."
  if install_if_changed "$SETUP_TMP/sshd.conf" "$SSHD_DROPIN" 644; then
    systemctl reload ssh || die "Reloading ssh failed. Check: sshd -t"
    SSH_HARDENED=1
    note_change "Turned off SSH password logins ($SSHD_DROPIN)"
  fi
}

setup_caddy() {
  local conf=/etc/caddy/Caddyfile out
  install -d -m 755 /etc/caddy/sites
  render_caddyfile >"$SETUP_TMP/Caddyfile" || exit 1
  out=$(caddy validate --config "$SETUP_TMP/Caddyfile" --adapter caddyfile 2>&1) \
    || die "$out"$'\n'"The Caddyfile didn't pass caddy validate, so it wasn't installed."
  if is_replaceable "$conf" caddy; then
    if install_if_changed "$SETUP_TMP/Caddyfile" "$conf" 644; then
      if ! { systemctl enable --now --quiet caddy && systemctl reload caddy; }; then
        die "Reloading Caddy failed. Check: systemctl status caddy"
      fi
      note_change "Wrote $conf"
    fi
    return 0
  fi
  if install_if_changed "$SETUP_TMP/Caddyfile" "$conf.shipit" 644; then
    note_change "Wrote $conf.shipit"
  fi
  note "Left $conf alone, because shipit didn't write it, and wrote $conf.shipit instead. To switch:
  sudo mv $conf $conf.pre-shipit && sudo mv $conf.shipit $conf
  sudo caddy validate --config $conf && sudo systemctl reload caddy"
}

setup_folders() {
  local dir
  for dir in "$SHIPIT_VAR" /var/log/shipit /var/backups/shipit; do
    [ -d "$dir" ] || note_change "Created $dir"
  done
  install -d -m 755 "$SHIPIT_VAR"
  # 751: caddy (not in adm) must reach each app's access.log, but nobody else can list the folder.
  install -d -m 751 -o root -g adm /var/log/shipit
  # 711: postgres (and the state backup unit) must reach an app's own /var/backups/shipit/<app>, but
  # nobody can list the others.
  install -d -m 711 /var/backups/shipit
}

setup_rotation_and_backups() {
  local unit units_changed=''
  render "$SHIPIT_TEMPLATES/logrotate" LOG_KEEP_DAYS >"$SETUP_TMP/logrotate" || exit 1
  logrotate -d "$SETUP_TMP/logrotate" >/dev/null 2>&1 \
    || die "The logrotate config didn't pass logrotate -d, so it wasn't installed."
  if install_if_changed "$SETUP_TMP/logrotate" /etc/logrotate.d/shipit 644; then
    note_change "Wrote /etc/logrotate.d/shipit (logs kept $LOG_KEEP_DAYS days)"
  fi
  # Both backup services share one timer template: it starts the service with its own name.
  for unit in shipit-backup@.service shipit-backup@.timer shipit-state-backup@.service \
    shipit-state-backup@.timer; do
    render "$SHIPIT_TEMPLATES/${unit/state-backup@.timer/backup@.timer}" >"$SETUP_TMP/$unit" || exit 1
    if install_if_changed "$SETUP_TMP/$unit" "/etc/systemd/system/$unit" 644; then
      units_changed=1
      note_change "Wrote /etc/systemd/system/$unit"
    fi
  done
  [ -z "$units_changed" ] || systemctl daemon-reload
}

print_summary() {
  local note
  log ''
  if [ "${#SETUP_CHANGES[@]}" -gt 0 ]; then
    log 'Setup changed:'
    printf '  - %s\n' "${SETUP_CHANGES[@]}"
  else
    log 'Nothing to change: this VPS is already set up.'
  fi
  for note in "${SETUP_NOTES[@]}"; do log "$note"; done
  if low_memory /proc/meminfo; then
    log 'Warning: RAM plus swap is below 4 GB, so a Next.js build may run out of memory.'
  fi
  log 'Next: sudo shipit deploy https://github.com/<you>/<app>'
  if [ -n "$SSH_HARDENED" ]; then
    log "Open a NEW terminal and log in as $ADMIN_USER before closing this one. If that fails, use Hostinger's browser terminal and delete $SSHD_DROPIN."
  fi
}

cmd_setup() {
  [ "$#" -eq 0 ] || die "Usage: sudo shipit setup"
  is_debian13 /etc/os-release || die "shipit setup needs Debian 13. Nothing was changed."
  SETUP_TMP=$(mktemp -d)
  # shellcheck disable=SC2064 # expand SETUP_TMP now
  trap "rm -rf '$SETUP_TMP'" EXIT

  log '== Host config'
  setup_host_conf
  log '== Packages'
  setup_packages
  log '== Swap'
  setup_swap
  log '== Users'
  setup_users
  log '== GitHub host keys'
  setup_github_keys
  log '== Firewall'
  setup_firewall
  log '== SSH'
  setup_ssh_hardening
  log '== Caddy'
  setup_caddy
  log '== Folders, log rotation and backup units'
  setup_folders
  setup_rotation_and_backups
  print_summary
}
