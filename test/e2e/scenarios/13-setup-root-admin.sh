#!/usr/bin/env bash
# setup from a key session with the default root admin: password logins are off for everyone, and
# root can still log in with a key.
set -euo pipefail
# shellcheck source=test/e2e/helpers.sh
. "$(dirname "$0")/../helpers.sh"

grep -qx 'ADMIN_USER=root' /etc/shipit/host.conf || fail "expected ADMIN_USER=root"
e2e_ssh_ready
out=$(key_ssh root "$SETUP_OVER_SSH </dev/null" 2>&1) || {
  echo "$out"
  fail "setup failed"
}
echo "$out"
dropin=/etc/ssh/sshd_config.d/10-shipit.conf
grep -qx 'PermitRootLogin prohibit-password' "$dropin" || fail "root isn't key-only"
grep -qx 'PasswordAuthentication no' "$dropin" || fail "passwords aren't off"
grep -qF "Open a NEW terminal and log in as root before closing this one." <<<"$out" || fail "no final warning"
sshd -T | grep -qx 'passwordauthentication no' || fail "sshd still allows passwords"

key_ssh root true || fail "root can't log in with a key"
useradd --create-home e2epw
echo 'e2epw:e2e-user-pw' | chpasswd
echo 'root:e2e-root-pw' | chpasswd
password_ssh root e2e-root-pw true 2>/dev/null && fail "root logged in with a password"
password_ssh e2epw e2e-user-pw true 2>/dev/null && fail "a user logged in with a password"
userdel --remove e2epw 2>/dev/null
passwd -l root >/dev/null

# A re-run from the same kind of session changes nothing.
out=$(key_ssh root "$SETUP_OVER_SSH </dev/null" 2>&1) || fail "the re-run failed"
grep -qF 'Nothing to change' <<<"$out" || fail "the re-run changed something: $out"
echo "root admin OK"
