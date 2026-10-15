#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2034,SC2030,SC2031 # single-quoted stub bodies; tests set lib variables, each in its own @test subshell
# lib/setup.sh (plan §5.1): templates against golden files, the small parsers setup uses, and the
# file-writing steps run twice in a temp root with stubbed host commands.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  load_common
  # shellcheck source=lib/setup.sh
  . "$REPO_ROOT/lib/setup.sh"
  golden=$REPO_ROOT/test/golden
  fixtures=$REPO_ROOT/test/fixtures
  tpl=$REPO_ROOT/templates
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

# temp_root: points every host path setup writes at a temp dir, and stubs the host commands. Each
# stub appends its arguments to $calls.
temp_root() {
  local r=$BATS_TEST_TMPDIR/root
  CADDY_ETC=$r/etc/caddy LOG_ROOT=$r/var/log/shipit APT_ETC=$r/etc/apt SSH_ETC=$r/etc/ssh
  FAIL2BAN_ETC=$r/etc/fail2ban ROOT_HOME=$r/root OS_RELEASE=$r/etc/os-release
  SETUP_TMP=$BATS_TEST_TMPDIR/tmp
  mkdir -p "$SETUP_TMP" "$CADDY_ETC" "$ROOT_HOME/.ssh"
  calls=$BATS_TEST_TMPDIR/calls
  : >"$calls"
  local cmd
  for cmd in systemctl chown ufw apt-get npm curl gpg; do
    stub "$cmd" 'echo "'"$cmd"' $*" >>"'"$calls"'"'
  done
  stub runuser 'echo "runuser $*" >>"'"$calls"'"; while [ "$1" != -- ]; do shift; done; shift; exec "$@"'
  stub caddy 'echo "caddy $*" >>"'"$calls"'"'
  stub apt-config 'echo "apt-config $*" >>"'"$calls"'"'
  stub sshd 'echo "sshd $*" >>"'"$calls"'"; [ "$1" != -T ] || printf "port 22\nport 2222\naddressfamily any\n"'
  stub dpkg-query 'exit 1'
}

# ---- Templates against golden files --------------------------------------------------------------

@test "Caddyfile imports the site files" {
  need_envsubst
  CADDY_ETC=/etc/caddy
  matches Caddyfile render "$tpl/Caddyfile" CADDY_ETC
}

@test "sshd drop-in turns off password logins and keeps root key-only" {
  need_envsubst
  matches sshd.conf render "$tpl/sshd.conf"
}

@test "fail2ban enables the sshd jail with the systemd backend" {
  need_envsubst
  matches fail2ban-sshd.conf render "$tpl/fail2ban-sshd.conf"
}

@test "apt files: Caddy and NodeSource repos with signed-by keyrings, the nodejs pin, auto-upgrades" {
  need_envsubst
  APT_ETC=/etc/apt NODE_MAJOR=24
  matches apt-caddy.list render "$tpl/apt-caddy.list" APT_ETC
  matches apt-nodesource.list render "$tpl/apt-nodesource.list" APT_ETC NODE_MAJOR
  matches apt-nodejs.pref render "$tpl/apt-nodejs.pref"
  matches apt-auto-upgrades render "$tpl/apt-auto-upgrades"
}

@test "every template setup writes starts with the managed marker" {
  for f in Caddyfile sshd.conf fail2ban-sshd.conf apt-caddy.list apt-nodesource.list apt-nodejs.pref \
    apt-auto-upgrades; do
    is_shipit_file "$tpl/$f" || {
      echo "$f has no marker"
      return 1
    }
  done
}

# ---- Validators on the rendered files (skipped where the tool is missing) -------------------------

@test "the Caddyfile passes caddy validate" {
  need_envsubst
  command -v caddy >/dev/null || skip "caddy isn't installed"
  run caddy validate --config "$golden/Caddyfile" --adapter caddyfile
  [ "$status" -eq 0 ] || {
    echo "$output"
    return 1
  }
}

@test "the sshd drop-in passes sshd -t" {
  command -v sshd >/dev/null || skip "sshd isn't installed"
  [ "$(id -u)" -eq 0 ] || skip "sshd -t needs root to read the host keys"
  run sshd -t -f "$golden/sshd.conf"
  [ "$status" -eq 0 ]
}

@test "the auto-upgrades file passes apt-config" {
  command -v apt-config >/dev/null || skip "apt-config (apt) isn't installed"
  run apt-config -c "$golden/apt-auto-upgrades" dump
  [ "$status" -eq 0 ]
  [[ $output == *'APT::Periodic::Unattended-Upgrade "1";'* ]]
}

# ---- OS check ------------------------------------------------------------------------------------

@test "version_ge compares dotted versions number by number" {
  version_ge 13 13
  version_ge 14 13
  version_ge 26.04 26.04
  version_ge 26.10 26.04
  version_ge 27.04 26.10
  version_ge 100 13
  run ! version_ge 12 13
  run ! version_ge 24.04 26.04
  run ! version_ge 26.03 26.04
  run ! version_ge 9 13
  run ! version_ge 13a 13
  run ! version_ge '' 13
}

@test "os_supported accepts Debian 13+ and Ubuntu 26.04+" {
  f=$BATS_TEST_TMPDIR/os-release
  for release in 'ID=debian\nVERSION_ID="13"' 'ID=debian\nVERSION_ID="14"' \
    'ID=ubuntu\nID_LIKE=debian\nVERSION_ID="26.04"' "ID=ubuntu\nVERSION_ID='26.10'" \
    'ID=ubuntu\nVERSION_ID=27.04'; do
    printf 'PRETTY_NAME="x"\n%b\n' "$release" >"$f"
    os_supported "$f" || {
      echo "refused $release"
      return 1
    }
  done
}

@test "os_supported refuses older releases and other systems, saying why" {
  f=$BATS_TEST_TMPDIR/os-release
  for release in 'ID=debian\nVERSION_ID="12"' 'ID=ubuntu\nVERSION_ID="24.04"' \
    'ID=ubuntu\nVERSION_ID="25.10"' 'ID=fedora\nVERSION_ID="42"' 'ID=debian' \
    'ID=linuxmint\nID_LIKE="ubuntu debian"\nVERSION_ID="26.04"' 'ID=debian\nVERSION_ID="13.1"' \
    'ID=ubuntu\nVERSION_ID="26"'; do
    printf '%b\n' "$release" >"$f"
    run --separate-stderr os_supported "$f"
    [ "$status" -eq 1 ] || {
      echo "accepted $release"
      return 1
    }
    [[ $stderr == *"shipit needs Debian 13 or later, or Ubuntu 26.04 or later. Nothing was changed." ]]
  done
  printf 'ID=debian\nVERSION_ID="12"\n' >"$f"
  run --separate-stderr os_supported "$f"
  [ "$stderr" = "This system is debian 12, but shipit needs Debian 13 or later, or Ubuntu 26.04 or later. Nothing was changed." ]
  run ! os_supported "$BATS_TEST_TMPDIR/missing"
}

@test "os_supported reads os-release as data, never runs it" {
  f=$BATS_TEST_TMPDIR/os-release
  printf 'ID=debian\nVERSION_ID="13"\n$(touch %s/ran)\n' "$BATS_TEST_TMPDIR" >"$f"
  os_supported "$f"
  [ ! -e "$BATS_TEST_TMPDIR/ran" ]
}

@test "setup refuses arguments, and an unsupported OS, before changing anything" {
  stub id '[ "$1" = -u ] && echo 0 || exec /usr/bin/id "$@"'
  run "$REPO_ROOT/bin/shipit" setup --ci-key blog -
  [ "$status" -eq 1 ]
  [ "$output" = "shipit setup takes no arguments yet (--ci-key comes with CI support). Run: sudo shipit setup" ]

  temp_root
  printf 'ID=debian\nVERSION_ID="12"\n' >"$OS_RELEASE"
  run cmd_setup
  [ "$status" -eq 1 ]
  [[ $output == *"This system is debian 12"* ]]
  [ ! -s "$calls" ]
}

# ---- Node.js LTS and host.conf -------------------------------------------------------------------

@test "node_lts_major picks the newest LTS major from index.json" {
  run node_lts_major <"$fixtures/node-index.json"
  [ "$status" -eq 0 ]
  [ "$output" = 24 ]
}

@test "node_lts_major fails when no release is LTS, or on bad input" {
  run node_lts_major <<<'[{"version":"v25.0.0","lts":false}]'
  [ "$status" -ne 0 ]
  run node_lts_major <<<'not json'
  [ "$status" -ne 0 ]
}

@test "host.conf is written once from the LTS lookup, then kept" {
  temp_root
  stub curl 'echo "curl $*" >>"'"$calls"'"; cat "'"$fixtures"'/node-index.json"'
  setup_host_conf
  [ "$NODE_MAJOR" = 24 ]
  grep -qx 'NODE_MAJOR=24' "$SHIPIT_ETC/host.conf"

  # A later LTS doesn't move it: re-runs keep NODE_MAJOR and don't look it up again.
  printf '%s\n' '# kept' 'NODE_MAJOR=22' >"$SHIPIT_ETC/host.conf"
  : >"$calls"
  NODE_MAJOR=''
  setup_host_conf
  [ "$NODE_MAJOR" = 22 ]
  [ ! -s "$calls" ]
  grep -qx 'NODE_MAJOR=22' "$SHIPIT_ETC/host.conf"
}

@test "host.conf: a failed lookup writes nothing" {
  temp_root
  stub curl 'exit 22'
  run setup_host_conf
  [ "$status" -eq 1 ]
  [[ $output == *"Couldn't find the current Node.js LTS version"* ]]
  [ ! -e "$SHIPIT_ETC/host.conf" ]
}

@test "host_conf_read refuses anything but one NODE_MAJOR line, comments and blanks" {
  f=$BATS_TEST_TMPDIR/host.conf
  printf '# c\n\nNODE_MAJOR=24\n' >"$f"
  host_conf_read "$f"
  [ "$NODE_MAJOR" = 24 ]
  for body in 'NODE_MAJOR=v24' 'NODE_MAJOR=' 'NODE_MAJOR=24\nNODE_MAJOR=22' 'NODE_MAJOR=24 ' \
    'NODE_MAJOR=$(id)' 'OTHER=1\nNODE_MAJOR=24' '# only a comment' 'NODE_MAJOR=024'; do
    printf '%b\n' "$body" >"$f"
    run host_conf_read "$f"
    [ "$status" -eq 1 ] || {
      echo "accepted $body"
      return 1
    }
  done
  run host_conf_read "$BATS_TEST_TMPDIR/missing"
  [ "$status" -eq 1 ]
}

@test "corepack is installed only when the pinned version isn't" {
  temp_root
  stub corepack 'echo "corepack $*" >>"'"$calls"'"; [ "$1" != --version ] || echo 0.31.0'
  run setup_corepack
  [ "$status" -eq 0 ]
  grep -qx "npm install -g --no-fund --no-audit corepack@$COREPACK_VERSION" "$calls"
  grep -qx 'corepack enable' "$calls"

  stub corepack 'echo "corepack $*" >>"'"$calls"'"; [ "$1" != --version ] || echo '"$COREPACK_VERSION"
  : >"$calls"
  run setup_corepack
  [ "$status" -eq 0 ]
  run ! grep -q '^npm' "$calls"
  grep -qx 'corepack enable' "$calls"
}

# ---- Firewall ------------------------------------------------------------------------------------

@test "sshd_ports reads one or several ports from sshd -T" {
  run sshd_ports <<<$'port 22\naddressfamily any\nlistenaddress 0.0.0.0:22'
  [ "$output" = 22 ]
  run sshd_ports <<<$'port 22\nport 2222'
  [ "$output" = $'22\n2222' ]
  run sshd_ports <<<'addressfamily any'
  [ "$status" -ne 0 ]
  for bad in 'port 22 23' 'port abc' 'port 70000' 'port 0' 'port -1'; do
    run sshd_ports <<<"$bad"
    [ "$status" -ne 0 ] || {
      echo "accepted $bad"
      return 1
    }
  done
}

@test "the firewall allows sshd's ports, 80, 443/tcp and 443/udp before it's enabled" {
  temp_root
  run setup_firewall
  [ "$status" -eq 0 ]
  diff "$calls" - <<'EOF'
sshd -T
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 2222/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw --force enable
EOF
  [[ $output == *"SSH (port 22, 2222)"* ]]
}

@test "the firewall isn't touched when sshd -T fails" {
  temp_root
  stub sshd 'exit 255'
  run setup_firewall
  [ "$status" -eq 1 ]
  [[ $output == *"Couldn't read the ports sshd listens on"* ]]
  run ! grep -q '^ufw' "$calls"
}

# ---- SSH key-login check -------------------------------------------------------------------------

@test "session_used_key finds this session's publickey login" {
  session_used_key 4321 1400 1 <"$fixtures/journal-sshd.txt"
  session_used_key 1500 <"$fixtures/journal-sshd.txt" # older sshd[pid] lines
}

@test "session_used_key refuses password, keyboard-interactive and other sessions' logins" {
  run ! session_used_key 1300 <"$fixtures/journal-sshd.txt"    # password
  run ! session_used_key 1600 <"$fixtures/journal-sshd.txt"    # failed key, then keyboard-interactive
  run ! session_used_key 1200 <"$fixtures/journal-sshd.txt"    # never logged in
  run ! session_used_key 140 400 <"$fixtures/journal-sshd.txt" # pid fragments don't match 1400/11400
  run ! session_used_key <"$fixtures/journal-sshd.txt"
}

@test "ssh_key_login_ok needs a key in authorized_keys and a key login for this session" {
  keys=$BATS_TEST_TMPDIR/authorized_keys
  run ssh_key_login_ok "$keys" 1400 <"$fixtures/journal-sshd.txt"
  [ "$status" -eq 1 ]
  [ "$output" = "root has no SSH key in $keys" ]

  printf '# just a comment\n' >"$keys"
  run ssh_key_login_ok "$keys" 1400 <"$fixtures/journal-sshd.txt"
  [ "$status" -eq 1 ]

  printf 'restrict ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAexample me@laptop\n' >"$keys"
  run ssh_key_login_ok "$keys" 1300 <"$fixtures/journal-sshd.txt"
  [ "$status" -eq 1 ]
  [ "$output" = "this session didn't log in with an SSH key" ]
  run ssh_key_login_ok "$keys" 1300 </dev/null
  [ "$status" -eq 1 ]

  run ssh_key_login_ok "$keys" 4321 1400 <"$fixtures/journal-sshd.txt"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ancestor_pids starts with this shell and walks up" {
  run ancestor_pids
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$$" ]
  [ "${#lines[@]}" -ge 2 ]
}

@test "SSH hardening is skipped, saying why, when this session used a password" {
  temp_root
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAexample me@laptop\n' >"$ROOT_HOME/.ssh/authorized_keys"
  stub journalctl 'cat "'"$fixtures"'/journal-sshd.txt"'
  run setup_ssh
  [ "$status" -eq 0 ]
  [[ $output == "Skipped SSH hardening: this session didn't log in with an SSH key, so password logins stay on."* ]]
  [ ! -e "$SSH_ETC/sshd_config.d/10-shipit.conf" ]
  run ! grep -q 'reload ssh' "$calls"
}

@test "SSH hardening is skipped when the journal can't be read" {
  temp_root
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAexample me@laptop\n' >"$ROOT_HOME/.ssh/authorized_keys"
  stub journalctl "echo 'Oct 13 10:00:02 vps sshd-session[$$]: Accepted publickey for root from 203.0.113.8 port 50300 ssh2'; exit 1"
  run setup_ssh
  [ "$status" -eq 0 ]
  [[ $output == "Skipped SSH hardening: sshd's journal couldn't be read"* ]]
  [ ! -e "$SSH_ETC/sshd_config.d/10-shipit.conf" ]
}

# ---- Host keys -----------------------------------------------------------------------------------

@test "known_hosts_lines prints one <host> line per host key, without comments" {
  run known_hosts_lines "$fixtures/ssh"
  [ "$status" -eq 0 ]
  diff <(printf '%s\n' "$output") - <<'EOF'
<host> ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYExample=
<host> ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleEd25519HostKeyForShipitTests00000
<host> ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQExample==
EOF
  run known_hosts_lines "$BATS_TEST_TMPDIR"
  [ "$status" -eq 1 ]
}

@test "print_known_hosts ends with the plan's sentence" {
  SSH_ETC=$fixtures/ssh
  run print_known_hosts
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "Replace <host> with the address CI connects to (use [host]:port if SSH isn't on 22), and save these lines as the GitHub secret VPS_KNOWN_HOSTS." ]
  [ "${lines[0]}" = '<host> ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYExample=' ]
}

# ---- Which files setup may overwrite -------------------------------------------------------------

@test "may_replace: missing, marked (# or //) or the package's untouched default" {
  stub dpkg-query 'echo; echo " /etc/other 0123"; echo " $FILE $SUM"'
  f=$BATS_TEST_TMPDIR/conf
  may_replace "$f" pkg
  printf '# managed by shipit\nx\n' >"$f"
  may_replace "$f"
  printf '// managed by shipit\nx\n' >"$f"
  may_replace "$f"
  printf 'foreign\n' >"$f"
  FILE=$f SUM=nope
  export FILE SUM
  run ! may_replace "$f" pkg
  run ! may_replace "$f"
  SUM=$(md5sum <"$f" | cut -d' ' -f1)
  may_replace "$f" pkg
  run ! may_replace "$f"
  printf 'a\nb\nc\n# managed by shipit\n' >"$f"
  run ! may_replace "$f"
}

@test "Caddy's untouched default Caddyfile is replaced; a changed one is refused" {
  need_envsubst
  temp_root
  conf=$CADDY_ETC/Caddyfile
  printf ':80 {\n\troot * /usr/share/caddy\n\tfile_server\n}\n' >"$conf"
  sum=$(md5sum <"$conf" | cut -d' ' -f1)
  stub dpkg-query 'echo " '"$conf"' '"$sum"'"'
  run setup_caddy
  [ "$status" -eq 0 ]
  is_shipit_file "$conf"
  grep -qx 'systemctl reload caddy' "$calls"

  printf ':80 {\n\trespond "mine"\n}\n' >"$conf"
  : >"$calls"
  run setup_caddy
  [ "$status" -eq 1 ]
  [[ $output == "$conf wasn't written by shipit and was changed after Caddy was installed, so setup left it alone."* ]]
  grep -q mine "$conf"
  [ ! -s "$calls" ]
}

@test "a Caddyfile that fails caddy validate isn't installed" {
  need_envsubst
  temp_root
  stub caddy 'echo "Error: bad config" >&2; exit 1'
  run setup_caddy
  [ "$status" -eq 1 ]
  [[ $output == *"Error: bad config"* ]]
  [[ $output == *"didn't pass caddy validate"* ]]
  [ ! -e "$CADDY_ETC/Caddyfile" ]
}

@test "apt sources shipit didn't write are left alone" {
  need_envsubst
  temp_root
  NODE_MAJOR=24
  mkdir -p "$APT_ETC/keyrings" "$APT_ETC/sources.list.d"
  echo key >"$APT_ETC/keyrings/caddy-stable-archive-keyring.gpg"
  echo key >"$APT_ETC/keyrings/nodesource.gpg"
  printf 'deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main\n' \
    >"$APT_ETC/sources.list.d/caddy-stable.list"
  run setup_apt_repos
  [ "$status" -eq 0 ] # nodesource.list was added
  [[ $output == *"Left $APT_ETC/sources.list.d/caddy-stable.list alone"* ]]
  grep -q '/usr/share/keyrings' "$APT_ETC/sources.list.d/caddy-stable.list"
  run ! grep -q '^curl' "$calls"
}

# ---- Idempotence ---------------------------------------------------------------------------------

@test "the file-writing steps run twice: the second run changes no file and reloads nothing" {
  need_envsubst
  temp_root
  NODE_MAJOR=24
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAexample me@laptop\n' >"$ROOT_HOME/.ssh/authorized_keys"
  stub journalctl "echo 'Oct 13 10:00:02 vps sshd-session[$$]: Accepted publickey for root from 203.0.113.8 port 50300 ssh2: ED25519 SHA256:x'"
  # The keys are downloaded once; here they're already there.
  mkdir -p "$APT_ETC/keyrings"
  echo key >"$APT_ETC/keyrings/caddy-stable-archive-keyring.gpg"
  echo key >"$APT_ETC/keyrings/nodesource.gpg"
  steps() {
    setup_apt_repos || true
    setup_dirs && setup_caddy && setup_fail2ban && setup_auto_upgrades && setup_ssh
  }
  snapshot() { (cd "$BATS_TEST_TMPDIR" && find root etc var srv -type f -exec cksum {} + | sort); }

  run steps
  [ "$status" -eq 0 ]
  [[ $output == *"Wrote $CADDY_ETC/Caddyfile and reloaded Caddy."* ]]
  [[ $output == *"SSH password logins are off."* ]]
  for f in "$CADDY_ETC/Caddyfile" "$FAIL2BAN_ETC/jail.d/shipit-sshd.conf" \
    "$APT_ETC/apt.conf.d/52shipit-auto-upgrades" "$SSH_ETC/sshd_config.d/10-shipit.conf" \
    "$APT_ETC/sources.list.d/caddy-stable.list" "$APT_ETC/sources.list.d/nodesource.list" \
    "$APT_ETC/preferences.d/shipit-nodejs"; do
    is_shipit_file "$f"
  done
  diff "$CADDY_ETC/Caddyfile" <(render "$tpl/Caddyfile" CADDY_ETC)
  diff "$SSH_ETC/sshd_config.d/10-shipit.conf" "$golden/sshd.conf"
  for d in "$SHIPIT_ETC/sites" "$CADDY_ETC/sites" "$SHIPIT_VAR" "$SRV_ROOT" "$LOG_ROOT"; do
    [ -d "$d" ]
  done
  grep -qx 'systemctl reload caddy' "$calls"
  grep -qx 'systemctl reload fail2ban' "$calls"
  grep -qx 'systemctl reload ssh' "$calls"
  grep -q "^runuser -u caddy -- caddy validate --config $SETUP_TMP/Caddyfile --adapter caddyfile" "$calls"
  grep -q "^sshd -t -f $SETUP_TMP/sshd.conf" "$calls"
  before=$(snapshot)

  : >"$calls"
  run steps
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(snapshot)" = "$before" ]
  run ! grep -q reload "$calls"
}
