#!/usr/bin/env bash
# One-time set-up of a fresh Debian 13 VPS (M10.1). Safe to re-run.
# Usage: sudo ops/provision.sh tracklite.example.com
set -euo pipefail

domain="${1:?Usage: sudo ops/provision.sh <domain>}"
here="$(cd "$(dirname "$0")" && pwd)"

echo "== Packages: PostgreSQL 18 (PGDG), Caddy, Node 24"
apt-get update
apt-get install -y sudo curl gnupg openssl debian-keyring debian-archive-keyring apt-transport-https postgresql-common
/usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
  | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt > /etc/apt/sources.list.d/caddy-stable.list
curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
apt-get install -y postgresql-18 caddy nodejs

echo "== Logs kept 14 days"
install -D -m 644 "$here/journald/tracklite.conf" /etc/systemd/journald.conf.d/tracklite.conf
install -m 644 "$here/logrotate/postgresql-common" /etc/logrotate.d/postgresql-common
systemctl restart systemd-journald

echo "== Users: tracklite runs the app, deployer owns and deploys the releases"
id tracklite >/dev/null 2>&1 \
  || useradd --system --home-dir /opt/tracklite --shell /usr/sbin/nologin tracklite
id deployer >/dev/null 2>&1 || useradd --create-home --shell /bin/bash deployer
usermod -aG systemd-journal deployer
install -m 440 "$here/sudoers/tracklite-deployer" /etc/sudoers.d/tracklite-deployer
visudo -cf /etc/sudoers.d/tracklite-deployer

echo "== Release directory, owned by deployer and read-only to tracklite"
install -d -m 755 -o deployer -g deployer /opt/tracklite /opt/tracklite/releases
chown -R deployer:deployer /opt/tracklite/releases
[ ! -d /opt/tracklite/repo ] || chown -R deployer:deployer /opt/tracklite/repo
for link in /opt/tracklite/current /opt/tracklite/previous; do
  [ ! -L "$link" ] || chown -h deployer:deployer "$link"
done

echo "== Database and /etc/tracklite/env (deployer reads it to build and migrate; only root edits it)"
install -d -m 750 -o root -g deployer /etc/tracklite
if [ ! -f /etc/tracklite/env ]; then
  password="$(openssl rand -hex 24)"
  sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
create role tracklite login password '$password';
create database tracklite owner tracklite;
SQL
  (umask 077 && sed -e "s|^DATABASE_URL=.*|DATABASE_URL=postgres://tracklite:$password@localhost:5432/tracklite|" \
      -e "s|^APP_URL=.*|APP_URL=https://$domain|" \
      "$here/env.example" > /etc/tracklite/env)
  echo "Wrote /etc/tracklite/env. Fill in EMAIL_FROM, RESEND_API_KEY and RESEND_WEBHOOK_SECRET."
fi
chown root:deployer /etc/tracklite/env
chmod 640 /etc/tracklite/env

echo "== Caddy for $domain"
install -m 644 "$here/Caddyfile" /etc/caddy/Caddyfile
install -d /etc/systemd/system/caddy.service.d
printf '[Service]\nEnvironment=TRACKLITE_DOMAIN=%s\n' "$domain" > /etc/systemd/system/caddy.service.d/tracklite.conf

echo "== systemd units"
install -m 644 "$here/systemd/tracklite-web.service" "$here/systemd/tracklite-worker.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable postgresql caddy tracklite-web tracklite-worker
systemctl restart caddy
if [ -e /opt/tracklite/current ]; then
  systemctl restart tracklite-web tracklite-worker
else
  echo "No release in /opt/tracklite/current yet; web and worker start after the first deploy."
fi
