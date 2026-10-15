# shellcheck shell=bash
# shipit setup: prepares the VPS (plan §5.1). Every step checks before it acts, so a re-run changes no
# file whose content is already right. Sourcing this file only defines constants and functions.
# Needs lib/common.sh.

# Not followed: config.sh's locals (an array named keys) confuse shellcheck's scoping here (SC2178).
# shellcheck source=/dev/null
. "${BASH_SOURCE[0]%/*}/config.sh"

NODE_INDEX_URL=https://nodejs.org/dist/index.json
CADDY_KEY_URL=https://dl.cloudsmith.io/public/caddy/stable/gpg.key
NODESOURCE_KEY_URL=https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key

# corepack isn't bundled from Node 25 on, so setup installs this version with npm (plan §2, §9).
COREPACK_VERSION=0.36.0

# What setup needs before it can add the Caddy and NodeSource repos and look up the Node LTS major.
BOOTSTRAP_PACKAGES=(ca-certificates curl gnupg jq)
# Plan §2.
PACKAGES=(caddy nodejs jq curl git ca-certificates gnupg gettext-base acl ufw unattended-upgrades
  fail2ban sudo)

SETUP_USAGE='Usage: shipit setup [--ci-key <name> <public key file | ->]...'
# Where install.sh links shipit: the path in the ci user's forced commands and sudoers rule.
# shellcheck disable=SC2034 # read by render
SHIPIT_BIN=/usr/local/bin/shipit
# The ci user (plan §4): how setup recognises the user it made (its GECOS field), and its shell, which
# sshd runs the forced command with.
CI_COMMENT='shipit ci'
CI_SHELL=/bin/sh
# The first line of the ci user's authorized_keys.
CI_KEYS_HEADER='# managed by shipit: one line per site, written by shipit setup --ci-key <name> <key>.'
# The key types --ci-key accepts.
CI_KEY_TYPES='ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com|ssh-rsa'

# The --ci-key arguments, validated by setup_args: site names and their keys (`<type> <base64>`).
CI_NAMES=() CI_KEYS=()

# ---- Small parsers and checks (unit-tested) ------------------------------------------------------

# version_ge <a> <b>: succeeds when dotted version a >= b, compared number by number (26.10 >= 26.04,
# 27.04 >= 26.10). Both must be digits and dots.
version_ge() {
  local LC_ALL=C i x y
  local -a a b
  [[ $1 =~ ^[0-9]+(\.[0-9]+)*$ && $2 =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 1
  IFS=. read -ra a <<<"$1"
  IFS=. read -ra b <<<"$2"
  for ((i = 0; i < ${#a[@]} || i < ${#b[@]}; i++)); do
    x=$((10#${a[i]:-0})) y=$((10#${b[i]:-0}))
    [ "$x" -eq "$y" ] || {
      [ "$x" -gt "$y" ]
      return
    }
  done
}

# os_supported <os-release file>: Debian 13+ or Ubuntu 26.04+ (plan §1). The file is read as data,
# never sourced. Prints why on stderr and fails otherwise.
os_supported() {
  local LC_ALL=C line key value id='' version=''
  if [ ! -r "$1" ]; then
    err "Can't read $1, so this system can't be checked. shipit needs Debian 13 or later, or Ubuntu 26.04 or later. Nothing was changed."
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    [[ $line =~ ^(ID|VERSION_ID)=(.*)$ ]] || continue
    key=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
    if [[ $value =~ ^\"(.*)\"$ || $value =~ ^\'(.*)\'$ ]]; then value=${BASH_REMATCH[1]}; fi
    if [ "$key" = ID ]; then id=$value; else version=$value; fi
  done <"$1"
  case "$id" in
    debian) [[ $version =~ ^[0-9]+$ ]] && version_ge "$version" 13 && return 0 ;;
    ubuntu) [[ $version =~ ^[0-9]+\.[0-9]+$ ]] && version_ge "$version" 26.04 && return 0 ;;
  esac
  [[ $id =~ ^[a-z0-9._-]+$ ]] || id=unknown
  [[ $version =~ ^[0-9.]+$ ]] || version='(no version)'
  err "This system is $id $version, but shipit needs Debian 13 or later, or Ubuntu 26.04 or later. Nothing was changed."
  return 1
}

# node_lts_major: reads nodejs.org's dist/index.json on stdin and prints the newest LTS major.
node_lts_major() {
  local LC_ALL=C major
  major=$(jq -r '[.[] | select(.lts) | .version | ltrimstr("v") | split(".")[0] | tonumber] | max' \
    2>/dev/null) || return 1
  [[ $major =~ ^[1-9][0-9]{0,2}$ ]] || return 1
  printf '%s\n' "$major"
}

# host_conf_read <file>: sets NODE_MAJOR from host.conf (plan §4), read as data: NODE_MAJOR=<number>
# once, blank lines and # comments; anything else is refused.
host_conf_read() {
  local LC_ALL=C line n=0
  NODE_MAJOR=''
  if [ ! -f "$1" ] || [ ! -r "$1" ]; then
    err "Can't read $1."
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [ -z "$line" ] || [[ $line == '#'* ]] && continue
    if [[ ! $line =~ ^NODE_MAJOR=([1-9][0-9]{0,2})$ ]] || [ -n "$NODE_MAJOR" ]; then
      err "Line $n of $1 isn't valid: it should hold one line NODE_MAJOR=<number>, like NODE_MAJOR=24."
      return 1
    fi
    NODE_MAJOR=${BASH_REMATCH[1]}
  done <"$1"
  if [ -z "$NODE_MAJOR" ]; then
    err "$1 has no NODE_MAJOR line."
    return 1
  fi
}

# sshd_ports: reads `sshd -T` on stdin and prints each port sshd listens on, one per line. Fails when
# there is none, or a port line isn't a plain port number.
sshd_ports() {
  local LC_ALL=C line found=''
  while IFS= read -r line || [ -n "$line" ]; do
    [[ $line == 'port '* ]] || continue
    if [[ ! $line =~ ^port\ ([1-9][0-9]{0,4})$ ]] || [ "${BASH_REMATCH[1]}" -gt 65535 ]; then
      return 1
    fi
    printf '%s\n' "${BASH_REMATCH[1]}"
    found=1
  done
  [ -n "$found" ]
}

# has_authorized_key <file>: the file has at least one public key line.
has_authorized_key() {
  [ -f "$1" ] && grep -E '(^|[ ,])(ssh-(ed25519|rsa|dss)|ecdsa-sha2-nistp[0-9]+|sk-[a-z0-9@.-]+) AAAA' \
    -- "$1" >/dev/null
}

# session_used_key <pid>...: reads sshd's journal on stdin. Succeeds if one of the pids (this
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

# ssh_key_login_ok <authorized_keys> <pid>...: reads sshd's journal on stdin. Succeeds when SSH
# hardening can't lock anyone out (plan §5.1 step 7): root has a key in authorized_keys and this
# session (one of the pids) logged in with a key. Otherwise prints why and fails.
ssh_key_login_ok() {
  local keys=$1
  shift
  if ! has_authorized_key "$keys"; then
    cat >/dev/null
    printf 'root has no SSH key in %s\n' "$keys"
    return 1
  fi
  if ! session_used_key "$@"; then
    printf "this session didn't log in with an SSH key\n"
    return 1
  fi
}

# ancestor_pids: this process and every parent up to (not including) init, one per line.
ancestor_pids() {
  local pid=$$
  while [[ $pid =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ]; do
    printf '%s\n' "$pid"
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') || return 0
  done
}

# known_hosts_lines <dir>: one `<host> <type> <base64>` line per <dir>/ssh_host_*_key.pub (plan §5.1
# step 8). Fails when there is no valid key file.
known_hosts_lines() {
  local LC_ALL=C f line found=''
  for f in "$1"/ssh_host_*_key.pub; do
    [ -f "$f" ] || continue
    IFS= read -r line <"$f" || [ -n "$line" ] || continue
    [[ $line =~ ^(ssh-[a-z0-9]+|ecdsa-sha2-nistp[0-9]+|sk-[a-z0-9@.-]+)\ (AAAA[A-Za-z0-9+/]*=*)(\ .*)?$ ]] \
      || continue
    printf '<host> %s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    found=1
  done
  [ -n "$found" ]
}

# is_package_default <file> <package>: the file is the package's conffile, unmodified (dpkg's md5).
is_package_default() {
  local sum
  sum=$(dpkg-query -W -f='${Conffiles}\n' "$2" 2>/dev/null | awk -v f="$1" '$1 == f { print $2 }')
  [ -n "$sum" ] && [ "$(md5sum <"$1" | cut -d' ' -f1)" = "$sum" ]
}

# may_replace <file> [package]: shipit may write the file if it's missing, marked as shipit's, or
# still the package's untouched default (a fresh VPS ships Caddy's stock Caddyfile).
may_replace() {
  [ ! -e "$1" ] || is_shipit_file "$1" || { [ -n "${2-}" ] && is_package_default "$1" "$2"; }
}

# ci_key_parse <file | ->: prints the public key in the file (or on stdin) as `<type> <base64>`. The
# file must be exactly one line (one trailing newline is fine): a key type, the base64 key and an
# optional comment, which is dropped, so it can't add a line or options of its own (plan §5.1 step 6).
# ssh-keygen -l must accept what's kept.
ci_key_parse() {
  local LC_ALL=C label=$1 content tmp ok=''
  local re="^($CI_KEY_TYPES) ([A-Za-z0-9+/]+={0,2})( [ -~]*)?$"
  [ "$1" != - ] || label='The key on stdin'
  if ! content=$(cat -- "$1" 2>/dev/null && printf x); then
    err "Can't read $1."
    return 1
  fi
  content=${content%x}
  content=${content%$'\n'}
  if [[ ! $content =~ $re ]]; then
    err "$label isn't a single public key line. It must be one line: the key type (ssh-ed25519, ecdsa-sha2-nistp256/384/521, sk-ssh-ed25519@openssh.com, sk-ecdsa-sha2-nistp256@openssh.com or ssh-rsa), the key, and an optional comment, with no options before it. Use the .pub file ssh-keygen wrote."
    return 1
  fi
  content="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
  tmp=$(mktemp) || return 1
  printf '%s\n' "$content" >"$tmp"
  ssh-keygen -l -f "$tmp" >/dev/null 2>&1 && ok=1
  rm -f -- "$tmp"
  if [ -z "$ok" ]; then
    err "$label isn't a valid public key: ssh-keygen -l refused it."
    return 1
  fi
  printf '%s\n' "$content"
}

# setup_args <arg>...: only `--ci-key <name> <file | ->`, repeated. Validates every name and key before
# setup changes anything, and sets CI_NAMES and CI_KEYS. A site may be named once, and only one key may
# come from stdin.
setup_args() {
  local name file key stdin=''
  CI_NAMES=() CI_KEYS=()
  while [ "$#" -gt 0 ]; do
    if [ "$1" != --ci-key ] || [ "$#" -lt 3 ]; then
      err "$SETUP_USAGE"
      return 1
    fi
    name=$2 file=$3
    shift 3
    check_site_name "$name" || return 1
    if in_list "$name" "${CI_NAMES[@]}"; then
      err "--ci-key $name is given twice. Give each site one key."
      return 1
    fi
    if [ "$file" = - ]; then
      if [ -n "$stdin" ]; then
        err "Only one --ci-key can read its key from stdin (-)."
        return 1
      fi
      stdin=1
    fi
    key=$(ci_key_parse "$file") || return 1
    CI_NAMES+=("$name") CI_KEYS+=("$key")
  done
}

# ci_keys_merge <authorized_keys> <name> <line>: prints the ci user's authorized_keys with <line> as
# the site's key: the marker first, then every other line as it was, with the line ending in
# ` shipit:<name>` replaced in place (or the new line added last). The file may be missing.
ci_keys_merge() {
  local line done=''
  printf '%s\n' "$CI_KEYS_HEADER"
  if [ -f "$1" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      if [[ $line == '# managed by shipit'* ]]; then
        continue
      elif [[ $line == *" shipit:$2" ]]; then
        [ -n "$done" ] || printf '%s\n' "$3"
        done=1
      else
        printf '%s\n' "$line"
      fi
    done <"$1"
  fi
  [ -n "$done" ] || printf '%s\n' "$3"
}

# ---- Host helpers --------------------------------------------------------------------------------

apt_get() {
  DEBIAN_FRONTEND=noninteractive apt-get -q -y -o Dpkg::Options::=--force-confold "$@"
}

# fetch_keyring <url> <dest>: downloads an armored apt signing key and stores it dearmored, once.
fetch_keyring() {
  [ ! -s "$2" ] || return 0
  curl -fsSL "$1" | gpg --batch --yes --dearmor -o "$SETUP_TMP/keyring" \
    || die "Couldn't download the apt key from $1. Check the network, then re-run sudo shipit setup."
  install -m 644 "$SETUP_TMP/keyring" "$2"
  log "Added the apt key $2."
}

# write_apt_file <template> <dest> <VAR>...: renders and installs an apt file. Succeeds only when it
# changed. A file shipit didn't write is left alone.
write_apt_file() {
  local tpl=$1 dest=$2
  shift 2
  if ! may_replace "$dest"; then
    log "Left $dest alone, because shipit didn't write it."
    return 1
  fi
  render "$SHIPIT_TEMPLATES/$tpl" "$@" >"$SETUP_TMP/$tpl" || exit 1
  install_if_changed "$SETUP_TMP/$tpl" "$dest" 644 || return 1
  log "Wrote $dest."
}

# ufw_run <argument>...: runs ufw quietly; stops setup if it fails.
ufw_run() {
  ufw "$@" >/dev/null \
    || die "ufw $* failed, so the firewall may be only partly set up. Check: ufw status verbose, then re-run sudo shipit setup."
}

# ---- Steps ---------------------------------------------------------------------------------------

# Step 2a: NODE_MAJOR, looked up once and kept in host.conf (plan §1).
setup_host_conf() {
  local conf=$SHIPIT_ETC/host.conf
  install -d -m 755 "$SHIPIT_ETC"
  if [ ! -e "$conf" ]; then
    NODE_MAJOR=$(curl -fsSL "$NODE_INDEX_URL" | node_lts_major) \
      || die "Couldn't find the current Node.js LTS version at $NODE_INDEX_URL. Check the network, then re-run sudo shipit setup."
    printf '%s\n' '# Written by the first shipit setup; re-runs keep it. The Node.js major for every site.' \
      "NODE_MAJOR=$NODE_MAJOR" >"$SETUP_TMP/host.conf"
    install -m 644 "$SETUP_TMP/host.conf" "$conf"
    log "Wrote $conf: Node.js $NODE_MAJOR (the current LTS)."
  fi
  host_conf_read "$conf" || die "Fix $conf, then re-run sudo shipit setup."
}

# Step 2b: the Caddy and NodeSource apt repos. Succeeds when a source changed (apt-get update needed).
setup_apt_repos() {
  local changed=''
  install -d -m 755 "$APT_ETC/keyrings" "$APT_ETC/sources.list.d" "$APT_ETC/preferences.d"
  fetch_keyring "$CADDY_KEY_URL" "$APT_ETC/keyrings/caddy-stable-archive-keyring.gpg"
  fetch_keyring "$NODESOURCE_KEY_URL" "$APT_ETC/keyrings/nodesource.gpg"
  write_apt_file apt-caddy.list "$APT_ETC/sources.list.d/caddy-stable.list" APT_ETC && changed=1
  write_apt_file apt-nodesource.list "$APT_ETC/sources.list.d/nodesource.list" APT_ETC NODE_MAJOR \
    && changed=1
  write_apt_file apt-nodejs.pref "$APT_ETC/preferences.d/shipit-nodejs" || true
  [ -n "$changed" ]
}

# Step 2c: corepack (for pnpm and yarn), pinned. Skipped when that version is already installed.
setup_corepack() {
  if [ "$(corepack --version 2>/dev/null)" != "$COREPACK_VERSION" ]; then
    npm install -g --no-fund --no-audit "corepack@$COREPACK_VERSION" >/dev/null \
      || die "Installing corepack $COREPACK_VERSION with npm failed. Re-run sudo shipit setup to continue."
    log "Installed corepack $COREPACK_VERSION."
  fi
  corepack enable || die "corepack enable failed. Re-run sudo shipit setup to continue."
}

# Step 2.
setup_packages() {
  apt_get update >/dev/null \
    || die "apt-get update failed. Fix the network or apt sources, then re-run sudo shipit setup."
  apt_get install "${BOOTSTRAP_PACKAGES[@]}" >/dev/null \
    || die "Installing ${BOOTSTRAP_PACKAGES[*]} failed. Re-run sudo shipit setup to continue."
  setup_host_conf
  if setup_apt_repos; then
    apt_get update >/dev/null || die "apt-get update failed. Re-run sudo shipit setup to continue."
  fi
  apt_get install "${PACKAGES[@]}" >/dev/null \
    || die "Installing ${PACKAGES[*]} failed. Re-run sudo shipit setup to continue."
  setup_corepack
}

# Step 3.
setup_dirs() {
  local dirs=("$SHIPIT_ETC" "$SHIPIT_ETC/sites" "$CADDY_ETC/sites" "$SHIPIT_VAR" "$SRV_ROOT" "$LOG_ROOT")
  install -d -m 755 "${dirs[@]}"
  chown root:root "${dirs[@]}"
}

# Step 3: the ci user (plan §4), which logs in only with a site's key and only runs its forced command.
# Its password field is `*`, which no password matches; `!` would make sshd refuse key logins too
# when UsePAM is off. Its home and .ssh are root's, so ci can change nothing there.
setup_ci_user() {
  case "$(user_state ci "$CI_COMMENT")" in
    other)
      die "A user named ci already exists, and shipit didn't create it, so setup can't use it for CI. Remove or rename that user, then re-run sudo shipit setup."
      ;;
    missing)
      useradd --system --user-group --no-create-home --home-dir "$CI_HOME" --shell "$CI_SHELL" \
        --password '*' --comment "$CI_COMMENT" ci || die "Creating the user ci failed."
      log "Created the user ci."
      ;;
  esac
  install -d -m 755 "$CI_HOME" "$CI_HOME/.ssh"
  chown root:root "$CI_HOME" "$CI_HOME/.ssh"
}

# Step 4: the root Caddyfile, validated as caddy, then reloaded (never restarted) if it changed.
setup_caddy() {
  local conf=$CADDY_ETC/Caddyfile out
  may_replace "$conf" caddy \
    || die "$conf wasn't written by shipit and was changed after Caddy was installed, so setup left it alone. Move it away (mv $conf $conf.old), then re-run sudo shipit setup."
  render "$SHIPIT_TEMPLATES/Caddyfile" CADDY_ETC >"$SETUP_TMP/Caddyfile" || exit 1
  chmod 644 "$SETUP_TMP/Caddyfile"
  out=$(runuser -u caddy -- caddy validate --config "$SETUP_TMP/Caddyfile" --adapter caddyfile 2>&1) \
    || die "$out"$'\n'"The Caddyfile didn't pass caddy validate, so $conf wasn't changed."
  systemctl enable --now --quiet caddy || die "Starting Caddy failed. Check: systemctl status caddy"
  if install_if_changed "$SETUP_TMP/Caddyfile" "$conf" 644; then
    systemctl reload caddy || die "Reloading Caddy failed. Check: systemctl status caddy"
    log "Wrote $conf and reloaded Caddy."
  fi
}

# Step 5a: ufw allows sshd's ports, 80/tcp, 443/tcp and 443/udp, and denies other incoming traffic.
setup_firewall() {
  local ports port
  ports=$(sshd -T 2>/dev/null | sshd_ports) \
    || die "Couldn't read the ports sshd listens on from sshd -T, so the firewall wasn't changed. Check sshd's config with sshd -t, then re-run sudo shipit setup."
  ufw_run default deny incoming
  ufw_run default allow outgoing
  for port in $ports; do ufw_run allow "$port/tcp"; done
  ufw_run allow 80/tcp
  ufw_run allow 443/tcp
  ufw_run allow 443/udp
  ufw_run --force enable
  log "Firewall on: SSH (port ${ports//$'\n'/, }), 80/tcp, 443/tcp and 443/udp are allowed; other incoming traffic is denied."
}

# Step 5b: fail2ban's sshd jail, reading the journal.
setup_fail2ban() {
  local conf=$FAIL2BAN_ETC/jail.d/shipit-sshd.conf
  may_replace "$conf" \
    || die "$conf wasn't written by shipit, so setup left it alone. Move it away, then re-run sudo shipit setup."
  render "$SHIPIT_TEMPLATES/fail2ban-sshd.conf" >"$SETUP_TMP/fail2ban-sshd.conf" || exit 1
  install -d -m 755 "$FAIL2BAN_ETC/jail.d"
  systemctl enable --now --quiet fail2ban || die "Starting fail2ban failed. Check: systemctl status fail2ban"
  if install_if_changed "$SETUP_TMP/fail2ban-sshd.conf" "$conf" 644; then
    systemctl reload fail2ban || die "Reloading fail2ban failed. Check: systemctl status fail2ban"
    log "Wrote $conf and reloaded fail2ban."
  fi
}

# Step 5c: unattended-upgrades on. A file of shipit's own, read after Debian's 20auto-upgrades, so
# it wins without touching that one.
setup_auto_upgrades() {
  local conf=$APT_ETC/apt.conf.d/52shipit-auto-upgrades
  may_replace "$conf" \
    || die "$conf wasn't written by shipit, so setup left it alone. Move it away, then re-run sudo shipit setup."
  render "$SHIPIT_TEMPLATES/apt-auto-upgrades" >"$SETUP_TMP/auto-upgrades" || exit 1
  apt-config -c "$SETUP_TMP/auto-upgrades" dump >/dev/null \
    || die "The unattended-upgrades config didn't pass apt-config, so $conf wasn't changed."
  install -d -m 755 "$APT_ETC/apt.conf.d"
  if install_if_changed "$SETUP_TMP/auto-upgrades" "$conf" 644; then
    log "Wrote $conf: security updates install automatically."
  fi
}

# Step 6a: ci's one sudoers rule, checked with visudo on a temp copy.
setup_sudoers() {
  local conf=$SUDOERS_DIR/shipit-ci
  may_replace "$conf" \
    || die "$conf wasn't written by shipit, so setup left it alone. Move it away, then re-run sudo shipit setup."
  render "$SHIPIT_TEMPLATES/sudoers-ci" SHIPIT_BIN >"$SETUP_TMP/sudoers-ci" || exit 1
  visudo -cqf "$SETUP_TMP/sudoers-ci" >/dev/null \
    || die "The ci user's sudoers rule didn't pass visudo -c, so $conf wasn't changed."
  install -d -m 755 "$SUDOERS_DIR"
  if install_if_changed "$SETUP_TMP/sudoers-ci" "$conf" 440; then
    log "Wrote $conf: ci may run only shipit remote."
  fi
}

# Step 6b: each --ci-key's line in ci's authorized_keys, replacing that site's old line.
setup_ci_keys() {
  local conf=$CI_HOME/.ssh/authorized_keys i CI_SITE CI_KEY
  [ "${#CI_NAMES[@]}" -gt 0 ] || return 0
  may_replace "$conf" \
    || die "$conf wasn't written by shipit, so setup left it alone. Move it away, then re-run sudo shipit setup."
  if [ -f "$conf" ]; then cp -- "$conf" "$SETUP_TMP/ci-keys"; else : >"$SETUP_TMP/ci-keys"; fi
  for i in "${!CI_NAMES[@]}"; do
    # shellcheck disable=SC2034 # CI_KEY is read by render
    CI_SITE=${CI_NAMES[i]} CI_KEY=${CI_KEYS[i]}
    render "$SHIPIT_TEMPLATES/authorized_keys" SHIPIT_BIN CI_SITE CI_KEY >"$SETUP_TMP/ci-key" || exit 1
    ci_keys_merge "$SETUP_TMP/ci-keys" "$CI_SITE" "$(cat "$SETUP_TMP/ci-key")" >"$SETUP_TMP/ci-keys.new"
    mv -- "$SETUP_TMP/ci-keys.new" "$SETUP_TMP/ci-keys"
  done
  if install_if_changed "$SETUP_TMP/ci-keys" "$conf" 644; then
    log "Wrote $conf: the CI key of ${CI_NAMES[*]}."
  fi
}

# Step 7: key-only SSH, only when it can't lock out the person running setup.
setup_ssh() {
  local conf=$SSH_ETC/sshd_config.d/10-shipit.conf journal reason
  local -a pids
  mapfile -t pids < <(ancestor_pids)
  if ! journal=$(journalctl -b -q --no-pager -o short -t sshd -t sshd-session 2>/dev/null); then
    reason="sshd's journal couldn't be read"
  elif reason=$(ssh_key_login_ok "$ROOT_HOME/.ssh/authorized_keys" "${pids[@]}" <<<"$journal"); then
    reason=''
  fi
  if [ -n "$reason" ]; then
    log "Skipped SSH hardening: $reason, so password logins stay on. Add your key to $ROOT_HOME/.ssh/authorized_keys, log in with it, then re-run sudo shipit setup."
    return 0
  fi
  may_replace "$conf" \
    || die "$conf wasn't written by shipit, so setup left it alone. Move it away, then re-run sudo shipit setup."
  render "$SHIPIT_TEMPLATES/sshd.conf" >"$SETUP_TMP/sshd.conf" || exit 1
  sshd -t -f "$SETUP_TMP/sshd.conf" || die "The SSH drop-in didn't pass sshd -t, so $conf wasn't changed."
  install -d -m 755 "$SSH_ETC/sshd_config.d"
  if install_if_changed "$SETUP_TMP/sshd.conf" "$conf" 644; then
    systemctl reload ssh || die "Reloading ssh failed. Check: sshd -t"
    log "Wrote $conf and reloaded ssh: SSH password logins are off. Before closing this session, check that you can log in from a new terminal."
  fi
}

# Step 8.
print_known_hosts() {
  local lines
  lines=$(known_hosts_lines "$SSH_ETC") \
    || die "Found no SSH host keys ($SSH_ETC/ssh_host_*_key.pub), so there's nothing to save as VPS_KNOWN_HOSTS. Check that openssh-server is installed."
  log ''
  log "$lines"
  log "Replace <host> with the address CI connects to (use [host]:port if SSH isn't on 22), and save these lines as the GitHub secret VPS_KNOWN_HOSTS."
}

cmd_setup() {
  setup_args "$@" || exit 1
  os_supported "$OS_RELEASE" || exit 1
  SETUP_TMP=$(mktemp -d)
  # shellcheck disable=SC2064 # expand SETUP_TMP now
  trap "rm -rf '$SETUP_TMP'" EXIT
  # caddy validates the Caddyfile from here as the caddy user. Nothing in it is secret.
  chmod 755 "$SETUP_TMP"

  setup_packages
  setup_dirs
  setup_ci_user
  setup_caddy
  setup_firewall
  setup_fail2ban
  setup_auto_upgrades
  setup_sudoers
  setup_ci_keys
  setup_ssh
  print_known_hosts
}
