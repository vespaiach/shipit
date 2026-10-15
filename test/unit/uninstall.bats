#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2034,SC2030,SC2031,SC2153,SC2154 # single-quoted stub bodies; tests set lib variables, each in its own @test subshell; deploy_helpers.bash sets calls, passwd...
# lib/uninstall.sh (plan §5.7): arguments, the confirmation and its refusals, then whole uninstalls in
# deploy.bats's temp root (deploy_helpers.bash): a real deploy and the files setup writes, then an
# uninstall.

bats_require_minimum_version 1.5.0

setup_file() {
  load deploy_helpers
  deploy_setup_file
}

setup() {
  load helpers
  load deploy_helpers
  deploy_setup
  # shellcheck source=lib/uninstall.sh
  . "$REPO_ROOT/lib/uninstall.sh"
  r=$BATS_TEST_TMPDIR
  STATE_ROOT=$r/state CACHE_ROOT=$r/cache APT_ETC=$r/apt SSH_ETC=$r/ssh FAIL2BAN_ETC=$r/fail2ban
  SUDOERS_DIR=$r/sudoers.d CI_HOME=$r/home/ci INSTALL_DIR=$r/lib/shipit INSTALL_LINK=$r/bin/shipit
  mkdir -p "$STATE_ROOT" "$CACHE_ROOT"
}

# installed: a host as setup and install.sh leave it (every file marked as shipit's), with the old ci
# user, and userdel, pkill and ufw stubbed: userdel drops the user from the fake passwd.
installed() {
  host
  local f
  for f in "$CADDY_ETC/Caddyfile" "$FAIL2BAN_ETC/jail.d/shipit-sshd.conf" \
    "$APT_ETC/apt.conf.d/52shipit-auto-upgrades" "$SSH_ETC/sshd_config.d/10-shipit.conf" \
    "$APT_ETC/sources.list.d/caddy-stable.list" "$APT_ETC/sources.list.d/nodesource.list" \
    "$APT_ETC/preferences.d/shipit-nodejs" "$SUDOERS_DIR/shipit-ci"; do
    mkdir -p "${f%/*}"
    echo '# managed by shipit' >"$f"
  done
  mkdir -p "$APT_ETC/keyrings" "$CI_HOME/.ssh" "$INSTALL_DIR/bin" "${INSTALL_LINK%/*}"
  : >"$APT_ETC/keyrings/caddy-stable-archive-keyring.gpg"
  : >"$APT_ETC/keyrings/nodesource.gpg"
  : >"$INSTALL_DIR/bin/shipit"
  ln -s "$INSTALL_DIR/bin/shipit" "$INSTALL_LINK"
  echo 'NODE_MAJOR=24' >"$SHIPIT_ETC/host.conf"
  echo 'ci:x:998:998:shipit ci:/home/ci:/bin/sh' >>"$passwd"
  stub pkill 'echo "pkill $*" >>"$STUB_CALLS"'
  stub userdel 'echo "userdel $*" >>"$STUB_CALLS"; grep -v "^$1:" "$STUB_PASSWD" >"$STUB_PASSWD.t"; cat "$STUB_PASSWD.t" >"$STUB_PASSWD"'
  stub ufw 'echo "ufw $*" >>"$STUB_CALLS"'
}

# deployed: installed, with blog deployed (static) and the calls log emptied.
deployed() {
  installed
  run cmd_deploy https://github.com/me/blog blog
  [ "$status" -eq 0 ] || {
    echo "$output"
    return 1
  }
  : >"$calls"
}

# ---- Arguments and refusals ----------------------------------------------------------------------

@test "uninstall takes no arguments" {
  run --separate-stderr cmd_uninstall blog
  [ "$status" -eq 1 ]
  [ "$stderr" = "$UNINSTALL_USAGE" ]
}

@test "with no answer (no terminal), or any answer but uninstall, nothing is removed" {
  deployed
  run --separate-stderr cmd_uninstall </dev/null
  [ "$status" -eq 1 ]
  [ "${stderr_lines[0]}" = "This uninstalls shipit. It deletes:" ]
  [[ ${stderr_lines[1]} == "- the sites blog, as shipit delete does: "* ]]
  [ "${stderr_lines[-1]}" = "Nothing was removed: there was no answer. Run it in a terminal (ssh -t), or pipe the answer: echo uninstall | shipit uninstall" ]
  for answer in yes y blog Uninstall ' uninstall'; do
    run --separate-stderr cmd_uninstall <<<"$answer"
    [ "$status" -eq 1 ]
    [ "${stderr_lines[-1]}" = "Type uninstall to go on: Nothing was removed: the answer wasn't uninstall." ] || {
      echo "$answer: $stderr"
      return 1
    }
  done
  [ -e "$SHIPIT_ETC/sites/blog.conf" ]
  [ -e "$CADDY_ETC/Caddyfile" ]
  [ -e "$INSTALL_LINK" ]
  [ ! -s "$calls" ]
}

@test "the prompt names the sites' data" {
  deployed
  mkdir -p "$STATE_ROOT/shipit-blog"
  run --separate-stderr cmd_uninstall </dev/null
  [[ $stderr == *"Site data goes too: $STATE_ROOT/shipit-blog. shipit keeps no backup: copy it first if you may need it."* ]]
}

# ---- Whole uninstalls ----------------------------------------------------------------------------

@test "uninstall deletes every site, what setup wrote, the ci user and shipit itself" {
  deployed
  echo '# managed by shipit' >"$CADDY_ETC/sites/other.caddy"
  run --separate-stderr cmd_uninstall <<<uninstall
  [ "$status" -eq 0 ] || {
    echo "$stderr"
    return 1
  }
  [[ ${lines[-1]} == "Uninstalled shipit. The packages setup installed "* ]]
  for path in "$SRV_ROOT/blog" "$CADDY_ETC/Caddyfile" "$CADDY_ETC/sites" "$FAIL2BAN_ETC/jail.d/shipit-sshd.conf" \
    "$APT_ETC/apt.conf.d/52shipit-auto-upgrades" "$SSH_ETC/sshd_config.d/10-shipit.conf" \
    "$APT_ETC/sources.list.d/caddy-stable.list" "$APT_ETC/sources.list.d/nodesource.list" \
    "$APT_ETC/preferences.d/shipit-nodejs" "$APT_ETC/keyrings/caddy-stable-archive-keyring.gpg" \
    "$APT_ETC/keyrings/nodesource.gpg" "$SUDOERS_DIR/shipit-ci" "$CI_HOME" "$SHIPIT_ETC" "$SHIPIT_VAR" \
    "$LOG_ROOT" "$INSTALL_DIR" "$INSTALL_LINK"; do
    [ ! -e "$path" ] && [ ! -L "$path" ] || {
      echo "still there: $path"
      return 1
    }
  done
  [ ! -s "$passwd" ]
  # The site as delete does it, then the host; ufw itself is never turned off.
  diff "$calls" - <<'EOF'
systemctl reload caddy
pkill -KILL -u blog-build
pkill -KILL -u blog
userdel blog-build
userdel blog
systemctl disable --now --quiet caddy
systemctl reload fail2ban
systemctl reload ssh
ufw delete allow 80/tcp
ufw delete allow 443/tcp
ufw delete allow 443/udp
pkill -KILL -u ci
userdel ci
EOF
}

@test "files and users shipit didn't make are left alone, and said so" {
  installed
  echo 'admin config' >"$CADDY_ETC/Caddyfile"
  echo 'mine.example.com' >"$CADDY_ETC/sites/mine.caddy"
  echo 'PasswordAuthentication no' >"$SSH_ETC/sshd_config.d/10-shipit.conf"
  echo 'deb https://example.com stable main' >"$APT_ETC/sources.list.d/nodesource.list"
  sed -i.bak 's/^ci:\(.*\):shipit ci:/ci:\1:someone:/' "$passwd"
  run --separate-stderr cmd_uninstall <<<uninstall
  [ "$status" -eq 0 ]
  for f in "$CADDY_ETC/Caddyfile" "$SSH_ETC/sshd_config.d/10-shipit.conf" \
    "$APT_ETC/sources.list.d/nodesource.list"; do
    [[ $stderr == *"$f wasn't written by shipit, so it was left alone."* ]]
    [ -e "$f" ]
  done
  [ -e "$CADDY_ETC/sites/mine.caddy" ]
  [ -e "$APT_ETC/keyrings/nodesource.gpg" ]
  [ ! -e "$APT_ETC/keyrings/caddy-stable-archive-keyring.gpg" ]
  grep -q '^ci:' "$passwd"
  run ! grep -Eq '^(userdel|systemctl disable|systemctl reload ssh)' "$calls"
}

@test "a link that isn't install.sh's is kept" {
  installed
  rm "$INSTALL_LINK"
  ln -s /elsewhere/shipit "$INSTALL_LINK"
  run cmd_uninstall <<<uninstall
  [ "$status" -eq 0 ]
  [ -L "$INSTALL_LINK" ]
  [ ! -e "$INSTALL_DIR" ]
}

@test "uninstall run again, on a host it already cleaned, succeeds and changes nothing" {
  deployed
  run cmd_uninstall <<<uninstall
  [ "$status" -eq 0 ]
  : >"$calls"
  run --separate-stderr cmd_uninstall <<<uninstall
  [ "$status" -eq 0 ]
  [[ $stderr != *"- the sites"* ]]
  # Only ufw's rule deletes, which ufw skips when the rule is gone.
  run ! grep -v '^ufw delete allow' "$calls"
}

@test "an uninstall that stopped half-way finishes the sites when run again" {
  deployed
  # As if a delete had stopped after the folders: the conf and the users are still there.
  rm -rf "${SRV_ROOT:?}/blog" "$CADDY_ETC/sites/blog.caddy"
  run cmd_uninstall <<<uninstall
  [ "$status" -eq 0 ]
  [ ! -e "$SHIPIT_ETC" ]
  [ ! -s "$passwd" ]
}
