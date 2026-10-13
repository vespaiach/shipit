#!/usr/bin/env bash
# A Caddyfile and an nftables.conf that shipit didn't write are left alone, and Caddyfile.shipit is
# written instead.
set -euo pipefail
# shellcheck source=test/e2e/helpers.sh
. "$(dirname "$0")/../helpers.sh"

saved=$(mktemp -d)
cp -a /etc/caddy/Caddyfile /etc/nftables.conf "$saved/"
restore() {
  cp -a "$saved/Caddyfile" /etc/caddy/Caddyfile
  cp -a "$saved/nftables.conf" /etc/nftables.conf
  rm -f /etc/caddy/Caddyfile.shipit
  systemctl reload caddy nftables
  rm -rf "$saved"
}
trap restore EXIT

printf '%s\n' ':8080 {' '	respond "not shipit"' '}' >/etc/caddy/Caddyfile
printf '%s\n' '#!/usr/sbin/nft -f' 'flush ruleset' 'table inet filter {' '	chain input {' \
  '		type filter hook input priority 0; policy accept;' '	}' '}' >/etc/nftables.conf
systemctl reload caddy nftables
caddy_sum=$(sha256sum /etc/caddy/Caddyfile)
nft_sum=$(sha256sum /etc/nftables.conf)

out=$(shipit setup </dev/null 2>&1) || {
  echo "$out"
  fail "setup failed"
}
echo "$out"
[ "$(sha256sum /etc/caddy/Caddyfile)" = "$caddy_sum" ] || fail "the foreign Caddyfile was changed"
[ "$(sha256sum /etc/nftables.conf)" = "$nft_sum" ] || fail "the foreign nftables.conf was changed"
head -n 1 /etc/caddy/Caddyfile.shipit | grep -q '^# managed by shipit' || fail "no Caddyfile.shipit"
grep -qF "Left /etc/caddy/Caddyfile alone" <<<"$out" || fail "didn't say it left the Caddyfile alone"
grep -qF "sudo mv /etc/caddy/Caddyfile.shipit /etc/caddy/Caddyfile" <<<"$out" || fail "didn't say how to switch"
grep -qF "Left /etc/nftables.conf alone" <<<"$out" || fail "didn't say it left nftables.conf alone"
nft list ruleset | grep -q 'policy accept' || fail "the foreign ruleset was replaced"
echo "foreign files OK"
