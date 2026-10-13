# Monitoring and email domain (M10.4)

One-time set-up before launch. Replace `tracklite.example.com` with the real domain and `mail.tracklite.example.com` with the sending subdomain.

## Uptime check (OPS-005)

A Google Apps Script outside the VPS calls two addresses every 5 minutes. When either fails twice in a row, it emails the Google account that owns the script. It sends one email per outage and address, and resets once that address answers `200` again.

| Address | Answers `503` when | Alert |
|---|---|---|
| `/health` | the database doesn't respond | "Tracklite is down" |
| `/health/worker` | `tracklite-worker` hasn't finished a pass in 2 minutes (or never has), or a due notification has waited more than 10 minutes | "Tracklite notifications are stuck" |

1. Sign in to the owner's Google account and create a new project at <https://script.google.com>.
2. Replace the editor's contents with [`uptime/health-check.gs`](uptime/health-check.gs), and set `baseUrl` to `https://tracklite.example.com`.
3. Choose `installTrigger` in the function menu and click **Run**. Grant the permissions it asks for: external requests, sending email as you, and managing triggers.
4. **Triggers** (the clock icon) should list one trigger: `checkHealth`, time-driven, every 5 minutes.

## Email domain (design §5.5)

Mail is sent from a subdomain, so the app's sending reputation is kept apart from the team's normal email.

1. In Resend, go to **Domains → Add domain** and add `mail.tracklite.example.com`.
2. At the DNS provider, add exactly the SPF and DKIM records Resend lists, plus a DMARC record:

   | Type | Name | Value |
   |---|---|---|
   | `TXT` | `_dmarc.mail.tracklite.example.com` | `v=DMARC1; p=none; rua=mailto:owner@example.com` |

3. Click **Verify** in Resend and wait until the domain shows **Verified**.
4. In Resend, go to **API Keys** and create a key with **Sending access** for this domain only.
5. Go to **Webhooks → Add endpoint**, enter `https://tracklite.example.com/webhooks/email` and select only `email.bounced`. Copy the signing secret (`whsec_…`).
6. Fill in `/etc/tracklite/env`, then restart both services:

   ```
   EMAIL_FROM=notifications@mail.tracklite.example.com
   RESEND_API_KEY=re_…
   RESEND_WEBHOOK_SECRET=whsec_…
   ```

   ```bash
   sudo systemctl restart tracklite-web tracklite-worker
   ```

## Checks by hand

- **The uptime check alerts (OPS-005.1).** Run `sudo systemctl stop tracklite-web`. Within about 10 minutes the owner gets "Tracklite is down". Run `sudo systemctl start tracklite-web` afterwards. To check the database case, stop `postgresql` instead: `/health` answers `503`, and the alert follows the same way.
- **The worker check alerts (OPS-005.6).** Run `sudo systemctl stop tracklite-worker`. Within 2 minutes `curl -s https://tracklite.example.com/health/worker` answers `unavailable`, and within about 15 minutes the owner gets "Tracklite notifications are stuck". Run `sudo systemctl start tracklite-worker` afterwards; the next check answers `ok`.
- **The worker logs its metrics.** `journalctl -u tracklite-worker --since "5 min ago" | grep '"event":"worker"'` shows about one line a minute with `pending`, `due`, `oldestDueSeconds` and the `sent`, `failed` and `dropped` counts since the previous line.
- **A test email passes SPF and DKIM.** As `deployer` on the VPS, send a password-reset email to a Gmail address you can read, with the same settings the services use:

  ```bash
  cd /opt/tracklite/current && (set -a; . /etc/tracklite/env; set +a; NODE_ENV=production node_modules/.bin/tsx --conditions=react-server scripts/send-dev-email.ts you@gmail.com)
  ```

  In Gmail, open the message and choose **⋮ → Show original**. `SPF`, `DKIM` and `DMARC` all read `PASS`.
- **The bounce webhook works.** Run the same command with `bounced@resend.dev`, Resend's address that always bounces. Within a minute, `journalctl -u tracklite-web | grep "email bounced"` shows `email bounced, untracked`. If nothing shows up, check the webhook's deliveries in Resend: a `401` means `RESEND_WEBHOOK_SECRET` doesn't match.