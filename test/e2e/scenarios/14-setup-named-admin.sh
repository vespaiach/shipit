#!/usr/bin/env bash
# setup with a named admin: the admin logs in with root's key and has password-less sudo, and root
# login is refused. Runs last among the setup scenarios, since root can't log in over SSH afterwards.
set -euo pipefail
# shellcheck source=test/e2e/helpers.sh
. "$(dirname "$0")/../helpers.sh"

e2e_ssh_ready
# Start again as if host.conf had never been written, without hardening.
rm -f /etc/shipit/host.conf /etc/ssh/sshd_config.d/10-shipit.conf
systemctl reload ssh
! id ops >/dev/null 2>&1 || fail "expected no ops user yet"

# Answers: blank email, admin ops.
out=$(key_ssh root "printf '\nops\n' | $SETUP_OVER_SSH" 2>&1) || {
  echo "$out"
  fail "setup failed"
}
echo "$out"
grep -qx 'ADMIN_USER=ops' /etc/shipit/host.conf || fail "host.conf doesn't name ops"
[ "$(getent passwd ops | cut -d: -f7)" = /bin/bash ] || fail "ops has no login shell"
[ "$(passwd -S ops | cut -d' ' -f2)" = L ] || fail "ops has a usable password"
cmp -s /root/.ssh/authorized_keys /home/ops/.ssh/authorized_keys || fail "root's keys weren't copied"
[ "$(stat -c '%U %a' /home/ops/.ssh/authorized_keys)" = 'ops 600' ] || fail "ops's authorized_keys perms"
[ "$(stat -c '%U %a' /etc/sudoers.d/shipit-admin)" = 'root 440' ] || fail "sudoers perms"
grep -qx 'ops ALL=(ALL:ALL) NOPASSWD: ALL' /etc/sudoers.d/shipit-admin || fail "sudoers content"
visudo -c >/dev/null || fail "visudo -c fails"
grep -qx 'PermitRootLogin no' /etc/ssh/sshd_config.d/10-shipit.conf || fail "root login isn't off"
grep -qF "Open a NEW terminal and log in as ops before closing this one." <<<"$out" || fail "no final warning"

key_ssh ops 'sudo -n true' || fail "ops can't log in with a key and sudo without a password"
key_ssh root true 2>/dev/null && fail "root can still log in over SSH"
echo "named admin OK"
