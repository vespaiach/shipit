#!/usr/bin/env bash
# The first setup on a fresh VM, run from an SSH session that logged in with a password. Everything is
# set up except SSH hardening, which is skipped with the reason given.
set -euo pipefail
# shellcheck source=test/e2e/helpers.sh
. "$(dirname "$0")/../helpers.sh"

[ ! -e /etc/shipit/host.conf ] || fail "expected a fresh VM without /etc/shipit/host.conf"
e2e_ssh_ready
# Allow password logins for this scenario only. 00- comes before 10-shipit.conf, so it's removed below.
printf '%s\n' 'PermitRootLogin yes' 'PasswordAuthentication yes' >/etc/ssh/sshd_config.d/00-e2e.conf
systemctl reload ssh
echo 'root:e2e-root-pw' | chpasswd

# Answers: blank email, default admin (root).
out=$(password_ssh root e2e-root-pw "printf '\n\n' | $SETUP_OVER_SSH" 2>&1) || {
  echo "$out"
  fail "setup failed"
}
echo "$out"
rm -f /etc/ssh/sshd_config.d/00-e2e.conf
passwd -l root >/dev/null
systemctl reload ssh

grep -qF "Skipped SSH hardening: this session didn't log in with an SSH key." <<<"$out" || fail "no skip reason"
[ ! -e /etc/ssh/sshd_config.d/10-shipit.conf ] || fail "hardening ran from a password session"
grep -qF 'Next: sudo shipit deploy https://github.com/<you>/<app>' <<<"$out" || fail "no next step"
grep -qF 'Open a NEW terminal' <<<"$out" && fail "warned about a new terminal without hardening"

# host.conf
conf=/etc/shipit/host.conf
[ "$(stat -c '%U %a' "$conf")" = 'root 644' ] || fail "host.conf must be root 644"
for line in ACME_EMAIL= ADMIN_USER=root BACKUP_KEEP=14 LOG_KEEP_DAYS=14 MIN_FREE_DISK_GB=3; do
  grep -qx "$line" "$conf" || fail "host.conf lacks $line"
done
major=$(sed -n 's/^NODE_MAJOR=//p' "$conf")
[ "$(node --version | sed 's/^v\([0-9]*\).*/\1/')" = "$major" ] || fail "node isn't major $major"
grep -Eqx 'SWAP_SIZE=[24]G' "$conf" || fail "SWAP_SIZE"

# Packages, swap, users
dpkg-query -W postgresql-18 caddy nodejs git jq gettext-base nftables unattended-upgrades >/dev/null \
  || fail "a package is missing"
[ -n "$(swapon --show --noheadings)" ] || fail "no swap"
grep -q '^/swapfile ' /etc/fstab || fail "/swapfile isn't in fstab"
[ "$(getent passwd deployer | cut -d: -f6,7)" = /home/deployer:/usr/sbin/nologin ] || fail "deployer account"
[ ! -e /etc/sudoers.d/shipit-admin ] || fail "wrote a sudoers file for root"

# GitHub keys, firewall, Caddy
grep -q '^github.com ssh-ed25519 ' /etc/ssh/ssh_known_hosts || fail "GitHub keys aren't pinned"
head -n 2 /etc/nftables.conf | grep -qx '# managed by shipit' || fail "nftables.conf isn't shipit's"
nft list ruleset | grep -q 'policy drop' || fail "the firewall isn't loaded"
systemctl is-enabled --quiet nftables || fail "nftables isn't enabled"
head -n 1 /etc/caddy/Caddyfile | grep -q '^# managed by shipit' || fail "the Caddyfile isn't shipit's"
grep -q email /etc/caddy/Caddyfile && fail "the Caddyfile has an email line with a blank ACME_EMAIL"
[ -d /etc/caddy/sites ] || fail "no /etc/caddy/sites"
systemctl is-active --quiet caddy || fail "caddy isn't running"

# Folders, rotation, backup units
[ "$(stat -c '%U %G %a' /var/log/shipit)" = 'root adm 751' ] || fail "/var/log/shipit"
[ "$(stat -c '%U %a' /var/backups/shipit)" = 'root 711' ] || fail "/var/backups/shipit"
[ -d /var/lib/shipit ] || fail "/var/lib/shipit"
grep -q 'rotate 14' /etc/logrotate.d/shipit || fail "logrotate"
systemctl cat shipit-backup@x.timer >/dev/null || fail "backup timer template"
systemctl cat shipit-backup@x.service >/dev/null || fail "backup service template"
echo "setup from a password session OK"
