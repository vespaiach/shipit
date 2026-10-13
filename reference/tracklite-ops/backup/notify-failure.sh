#!/usr/bin/env bash
# Emails OWNER_EMAIL through Resend when tracklite-backup.service fails (OPS-003.3).
# Run by tracklite-backup-failed.service through the backup unit's OnFailure=.
set -euo pipefail

log="$(journalctl --unit tracklite-backup.service --lines 20 --no-pager --output cat || true)"
# shellcheck disable=SC2016
body="$(node -e '
  const [from, to, host, log] = process.argv.slice(1);
  console.log(JSON.stringify({
    from,
    to: [to],
    subject: `Tracklite backup failed on ${host}`,
    text: `The 03:00 UTC database backup failed. There is no new backup until it is fixed.\n\n` +
      `Check: journalctl -u tracklite-backup.service\n\nLast log lines:\n${log}\n`,
  }));
' "$EMAIL_FROM" "$OWNER_EMAIL" "$(hostname)" "$log")"

curl --fail-with-body --silent --show-error \
  --header "Authorization: Bearer $RESEND_API_KEY" \
  --header "Content-Type: application/json" \
  --data "$body" \
  https://api.resend.com/emails
