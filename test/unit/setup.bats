#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2034,SC2030,SC2031 # single-quoted stub bodies; tests set lib variables, each in its own @test subshell
# lib/setup.sh: templates against golden files, their validators, and the small parsers setup uses.

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

# ---- Templates against golden files --------------------------------------------------------------

@test "Caddyfile with an email has the email line" {
  need_envsubst
  ACME_EMAIL=owner@example.com
  matches Caddyfile render_caddyfile
}

@test "Caddyfile without an email has no global options block" {
  need_envsubst
  ACME_EMAIL=''
  matches Caddyfile.no-email render_caddyfile
  [[ $output != *email* ]]
}

@test "nftables.conf allows the SSH ports" {
  need_envsubst
  SSH_PORTS='22, 2222'
  matches nftables.conf render "$tpl/nftables.conf" SSH_PORTS
}

@test "sshd drop-in keeps root key-only when root is the admin" {
  need_envsubst
  ADMIN_USER=root
  matches sshd.root.conf render_sshd_conf
  [[ $output == *"PermitRootLogin prohibit-password"* ]]
}

@test "sshd drop-in turns root login off for a named admin" {
  need_envsubst
  ADMIN_USER=ops
  matches sshd.named.conf render_sshd_conf
  [[ $output == *"PermitRootLogin no"* ]]
}

@test "sudoers gives the named admin password-less sudo" {
  need_envsubst
  ADMIN_USER=ops
  matches sudoers render "$tpl/sudoers" ADMIN_USER
}

@test "logrotate keeps LOG_KEEP_DAYS days" {
  need_envsubst
  LOG_KEEP_DAYS=14
  matches logrotate render "$tpl/logrotate" LOG_KEEP_DAYS
}

@test "backup units render unchanged" {
  need_envsubst
  matches shipit-backup@.service render "$tpl/shipit-backup@.service"
  matches shipit-backup@.timer render "$tpl/shipit-backup@.timer"
  matches shipit-state-backup@.service render "$tpl/shipit-state-backup@.service"
}

@test "every template starts with the managed marker" {
  for f in "$tpl"/*; do
    head -n 2 "$f" | grep -q "^$MANAGED_MARKER" || {
      echo "$f has no marker"
      return 1
    }
  done
}

# ---- Validators on the rendered files (skipped where the tool is missing) -------------------------

@test "both Caddyfiles pass caddy validate" {
  need_envsubst
  command -v caddy >/dev/null || skip "caddy isn't installed"
  for ACME_EMAIL in owner@example.com ''; do
    render_caddyfile >"$BATS_TEST_TMPDIR/Caddyfile"
    run caddy validate --config "$BATS_TEST_TMPDIR/Caddyfile" --adapter caddyfile
    [ "$status" -eq 0 ] || {
      echo "$output"
      return 1
    }
  done
}

@test "the sudoers file passes visudo -cf" {
  need_envsubst
  command -v visudo >/dev/null || skip "visudo (sudo) isn't installed"
  ADMIN_USER=ops
  render "$tpl/sudoers" ADMIN_USER >"$BATS_TEST_TMPDIR/sudoers"
  run visudo -cf "$BATS_TEST_TMPDIR/sudoers"
  [ "$status" -eq 0 ]
}

@test "nftables.conf passes nft -c" {
  need_envsubst
  command -v nft >/dev/null || skip "nft (nftables) isn't installed"
  [ "$(id -u)" -eq 0 ] || skip "nft -c needs root"
  SSH_PORTS=22
  render "$tpl/nftables.conf" SSH_PORTS >"$BATS_TEST_TMPDIR/nftables.conf"
  run nft -c -f "$BATS_TEST_TMPDIR/nftables.conf"
  [ "$status" -eq 0 ]
}

@test "the sshd drop-in passes sshd -t" {
  need_envsubst
  command -v sshd >/dev/null || skip "sshd isn't installed"
  [ "$(id -u)" -eq 0 ] || skip "sshd -t needs root to read the host keys"
  ADMIN_USER=root
  render_sshd_conf >"$BATS_TEST_TMPDIR/sshd.conf"
  run sshd -t -f "$BATS_TEST_TMPDIR/sshd.conf"
  [ "$status" -eq 0 ]
}

@test "logrotate config passes logrotate -d" {
  need_envsubst
  command -v logrotate >/dev/null || skip "logrotate isn't installed"
  LOG_KEEP_DAYS=14
  render "$tpl/logrotate" LOG_KEEP_DAYS >"$BATS_TEST_TMPDIR/logrotate"
  chmod 644 "$BATS_TEST_TMPDIR/logrotate"
  run logrotate -d "$BATS_TEST_TMPDIR/logrotate"
  [ "$status" -eq 0 ]
}

@test "backup units pass systemd-analyze verify" {
  command -v systemd-analyze >/dev/null || skip "systemd-analyze isn't installed"
  # The checkout's libexec/backup stands in for the installed one.
  d=$BATS_TEST_TMPDIR/units
  mkdir -p "$d"
  sed "s|/usr/local/lib/shipit/libexec/|$REPO_ROOT/libexec/|" "$tpl/shipit-backup@.service" \
    >"$d/shipit-backup@.service"
  sed "s|/usr/local/lib/shipit/libexec/|$REPO_ROOT/libexec/|" "$tpl/shipit-state-backup@.service" \
    >"$d/shipit-state-backup@.service"
  cp "$tpl/shipit-backup@.timer" "$d/"
  # setup installs the one timer template under both names.
  cp "$tpl/shipit-backup@.timer" "$d/shipit-state-backup@.timer"
  run systemd-analyze verify "$d/shipit-backup@.service" "$d/shipit-backup@.timer" \
    "$d/shipit-state-backup@.service" "$d/shipit-state-backup@.timer"
  [ "$status" -eq 0 ] || {
    echo "$output"
    return 1
  }
}

# ---- Parsers and checks --------------------------------------------------------------------------

@test "swap is 4G below 6 GB of RAM and 2G otherwise" {
  [ "$(swap_size_for_ram 3995000)" = 4G ]  # KVM 1: 4 GB
  [ "$(swap_size_for_ram 6291455)" = 4G ]  # just under 6 GiB
  [ "$(swap_size_for_ram 6291456)" = 2G ]  # 6 GiB
  [ "$(swap_size_for_ram 8100000)" = 2G ]  # KVM 2: 8 GB
  [ "$(swap_size_for_ram 16300000)" = 2G ] # KVM 4: 16 GB
}

@test "meminfo_kb and low_memory read /proc/meminfo's format" {
  m=$BATS_TEST_TMPDIR/meminfo
  printf 'MemTotal:        3995000 kB\nMemFree:          100000 kB\nSwapTotal:             0 kB\n' >"$m"
  [ "$(meminfo_kb MemTotal "$m")" = 3995000 ]
  low_memory "$m"
  printf 'MemTotal:        3995000 kB\nSwapTotal:       4194300 kB\n' >"$m"
  run ! low_memory "$m"
  run meminfo_kb Nope "$m"
  [ "$status" -ne 0 ]
}

@test "node_lts_major picks the newest LTS major from index.json" {
  run node_lts_major <"$fixtures/node-index.json"
  [ "$status" -eq 0 ]
  [ "$output" = 24 ]
}

@test "node_lts_major fails when no release is LTS" {
  run node_lts_major <<<'[{"version":"v25.0.0","lts":false}]'
  [ "$status" -ne 0 ]
  run node_lts_major <<<'not json'
  [ "$status" -ne 0 ]
}

@test "sshd_ports reads one or several ports from sshd -T" {
  run sshd_ports <<<$'port 22\naddressfamily any\nlistenaddress 0.0.0.0:22'
  [ "$output" = 22 ]
  run sshd_ports <<<$'port 22\nport 2222'
  [ "$output" = "22, 2222" ]
  run sshd_ports <<<'addressfamily any'
  [ "$status" -ne 0 ]
}

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

@test "ancestor_pids starts with this shell and walks up" {
  run ancestor_pids
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$$" ]
  [ "${#lines[@]}" -ge 2 ]
}

@test "github_known_hosts refuses a bad key line" {
  run github_known_hosts <"$fixtures/github-meta.json"
  [ "$status" -ne 0 ]
}

@test "github_known_hosts and merge_known_hosts pin GitHub's keys, keeping other hosts" {
  jq 'del(.ssh_keys[3])' "$fixtures/github-meta.json" >"$BATS_TEST_TMPDIR/meta.json"
  github_known_hosts <"$BATS_TEST_TMPDIR/meta.json" >"$BATS_TEST_TMPDIR/keys"
  [ "$(wc -l <"$BATS_TEST_TMPDIR/keys")" -eq 3 ]
  grep -q '^github.com ssh-ed25519 AAAAC3' "$BATS_TEST_TMPDIR/keys"

  printf '%s\n' 'example.org ssh-ed25519 AAAAexample' 'github.com ssh-rsa AAAAold' >"$BATS_TEST_TMPDIR/kh"
  run merge_known_hosts "$BATS_TEST_TMPDIR/kh" "$BATS_TEST_TMPDIR/keys"
  [ "${lines[0]}" = 'example.org ssh-ed25519 AAAAexample' ]
  [ "${#lines[@]}" -eq 4 ]
  [[ $output != *AAAAold* ]]

  run merge_known_hosts "$BATS_TEST_TMPDIR/missing" "$BATS_TEST_TMPDIR/keys"
  [ "${#lines[@]}" -eq 3 ]
}

@test "is_debian13 accepts Debian 13 only" {
  f=$BATS_TEST_TMPDIR/os-release
  printf 'PRETTY_NAME="Debian GNU/Linux 13 (trixie)"\nVERSION_ID="13"\nID=debian\n' >"$f"
  is_debian13 "$f"
  printf 'VERSION_ID="12"\nID=debian\n' >"$f"
  run ! is_debian13 "$f"
  printf 'VERSION_ID="13"\nID=ubuntu\nID_LIKE=debian\n' >"$f"
  run ! is_debian13 "$f"
}

@test "is_replaceable: missing, marked or the package's untouched default" {
  stub dpkg-query 'echo; echo " /etc/other 0123"; echo " $FILE $SUM"'
  f=$BATS_TEST_TMPDIR/conf
  is_replaceable "$f" pkg
  printf '#!/usr/sbin/nft -f\n%s\nflush ruleset\n' "$MANAGED_MARKER" >"$f"
  is_replaceable "$f" pkg
  printf 'foreign\n' >"$f"
  FILE=$f SUM=nope
  export FILE SUM
  run ! is_replaceable "$f" pkg
  SUM=$(md5sum <"$f" | cut -d' ' -f1)
  is_replaceable "$f" pkg
}

@test "a foreign file with the marker further down isn't shipit's" {
  stub dpkg-query 'exit 1'
  f=$BATS_TEST_TMPDIR/conf
  printf 'a\nb\nc\n%s\n' "$MANAGED_MARKER" >"$f"
  run ! is_replaceable "$f" pkg
}

# ---- host.conf -----------------------------------------------------------------------------------

@test "host.conf round-trips through load_host_conf" {
  ACME_EMAIL='' ADMIN_USER=ops NODE_MAJOR=24 SWAP_SIZE=4G
  host_conf_text >"$SHIPIT_ETC/host.conf"
  chmod 644 "$SHIPIT_ETC/host.conf"
  unset ACME_EMAIL ADMIN_USER NODE_MAJOR SWAP_SIZE LOG_KEEP_DAYS
  load_host_conf "$SHIPIT_ETC/host.conf"
  [ -z "$ACME_EMAIL" ]
  [ "$ADMIN_USER" = ops ]
  [ "$NODE_MAJOR" = 24 ]
  [ "$SWAP_SIZE" = 4G ]
  [ "$LOG_KEEP_DAYS" = 14 ]
  grep -qx 'BACKUP_KEEP=14' "$SHIPIT_ETC/host.conf"
  grep -qx 'MIN_FREE_DISK_GB=3' "$SHIPIT_ETC/host.conf"
  grep -qx 'EXTRA_PACKAGES=' "$SHIPIT_ETC/host.conf"
  [ -z "$EXTRA_PACKAGES" ]
}

@test "load_host_conf: EXTRA_PACKAGES is optional, and a quoted list of names is read as one value" {
  f=$SHIPIT_ETC/host.conf
  printf '%s\n' ACME_EMAIL= ADMIN_USER=root NODE_MAJOR=24 SWAP_SIZE=2G LOG_KEEP_DAYS=14 >"$f"
  chmod 644 "$f"
  EXTRA_PACKAGES=stale
  load_host_conf "$f"
  [ -z "$EXTRA_PACKAGES" ]
  printf '%s\n' 'EXTRA_PACKAGES="build-essential python3"' >>"$f"
  load_host_conf "$f"
  [ "$EXTRA_PACKAGES" = 'build-essential python3' ]
}

@test "load_host_conf refuses bad values and unsafe files" {
  f=$SHIPIT_ETC/host.conf
  for line in 'ADMIN_USER=Bad' 'NODE_MAJOR=v24' 'SWAP_SIZE=4' 'ACME_EMAIL=no-at-sign' \
    'EXTRA_PACKAGES="gcc;id"' 'EXTRA_PACKAGES="-y gcc"'; do
    printf '%s\n' ACME_EMAIL= ADMIN_USER=root NODE_MAJOR=24 SWAP_SIZE=2G LOG_KEEP_DAYS=14 "$line" >"$f"
    chmod 644 "$f"
    run load_host_conf "$f"
    [ "$status" -eq 1 ] || {
      echo "accepted $line"
      return 1
    }
  done
  chmod 666 "$f"
  run load_host_conf "$f"
  [ "$status" -eq 1 ]
}

@test "ask_host_questions takes a blank email and the default admin" {
  ask_host_questions <<<$'\n\n'
  [ -z "$ACME_EMAIL" ]
  [ "$ADMIN_USER" = root ]
}

@test "ask_host_questions asks again after an invalid answer" {
  ask_host_questions 2>/dev/null <<<$'not an email\nme@example.com\nBad Name\nops'
  [ "$ACME_EMAIL" = me@example.com ]
  [ "$ADMIN_USER" = ops ]
}

@test "ask_host_questions fails when input runs out" {
  run ask_host_questions </dev/null
  [ "$status" -eq 1 ]
  run ask_host_questions <<<'me@example.com'
  [ "$status" -eq 1 ]
}

@test "install_if_changed installs new content and reports no change otherwise" {
  printf 'a\n' >"$BATS_TEST_TMPDIR/new"
  install_if_changed "$BATS_TEST_TMPDIR/new" "$BATS_TEST_TMPDIR/dest" 640
  [ "$(cat "$BATS_TEST_TMPDIR/dest")" = a ]
  run ! install_if_changed "$BATS_TEST_TMPDIR/new" "$BATS_TEST_TMPDIR/dest" 640
  printf 'b\n' >"$BATS_TEST_TMPDIR/new"
  install_if_changed "$BATS_TEST_TMPDIR/new" "$BATS_TEST_TMPDIR/dest" 640
  [ "$(cat "$BATS_TEST_TMPDIR/dest")" = b ]
}

@test "install_packages installs only what's missing, so a re-run changes nothing" {
  # dpkg-query: the packages listed in $BATS_TEST_TMPDIR/installed are installed.
  printf 'build-essential\n' >"$BATS_TEST_TMPDIR/installed"
  stub dpkg-query 'grep -qx "${!#}" "'"$BATS_TEST_TMPDIR"'/installed" && printf installed'
  stub apt-get 'echo "$*" >>"'"$BATS_TEST_TMPDIR"'/apt.calls"
[ "$5" != install ] || { shift 5; printf "%s\n" "$@" >>"'"$BATS_TEST_TMPDIR"'/installed"; }'
  SETUP_CHANGES=()
  install_packages build-essential python3
  [ "$(grep -c ' install ' "$BATS_TEST_TMPDIR/apt.calls")" = 1 ]
  grep -q ' install python3$' "$BATS_TEST_TMPDIR/apt.calls"
  [ "${SETUP_CHANGES[*]}" = 'Installed python3' ]
  : >"$BATS_TEST_TMPDIR/apt.calls"
  SETUP_CHANGES=()
  install_packages build-essential python3
  [ ! -s "$BATS_TEST_TMPDIR/apt.calls" ]
  [ "${#SETUP_CHANGES[@]}" -eq 0 ]
}
