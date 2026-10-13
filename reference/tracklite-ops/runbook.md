# Production deployment runbook

How to ship a change to production, check that it worked and recover if it didn't. Replace `tracklite.example.com` with the real domain.

The scripts and the one-time server set-up are described in [README.md](README.md) (M10.1–M10.3) and [monitoring-and-email.md](monitoring-and-email.md) (M10.4). This page doesn't repeat them. It's the procedure to follow each time.

## At a glance

Run everything here as `deployer` (see [README.md → Accounts](README.md#accounts)). Only [Changing settings](#changing-settings) needs your admin account.

| What | Command (on the VPS, as `deployer`) |
|---|---|
| Deploy the latest `main` | `/opt/tracklite/current/ops/deploy.sh` |
| Roll back one release | `/opt/tracklite/current/ops/rollback.sh` |
| Which release is live | `readlink /opt/tracklite/current` |
| Which release rollback goes to | `readlink /opt/tracklite/previous` |
| Service state | `systemctl status tracklite-web tracklite-worker caddy postgresql` |
| App logs | `journalctl -u tracklite-web -u tracklite-worker --since "15 min ago"` |
| Access log | `journalctl -u caddy --since "15 min ago"` |
| Backup now | `sudo systemctl start tracklite-backup.service` |

The release layout is described in [How a deploy works](#how-a-deploy-works). A deploy always ships the tip of `main` on GitHub, never your local checkout or another branch.

## 1. Before you deploy

Check each item. If any fails, don't deploy.

1. **The change is merged to `main`, and CI is green on that `main` commit.** CI runs lint, typecheck and the tests against PostgreSQL 18.
2. **The migrations are safe to roll back (OPS-004).** Look at what's new in `migrations/` since the live commit:

   ```bash
   git diff --stat <live-sha>..origin/main -- migrations/
   ```

   The live commit is the part of `readlink /opt/tracklite/current` after the `-`. Migrations run while the old release is still serving, and a rollback keeps the new schema. So the previous release's code must work against the new schema:
   - **Safe:** new tables, new nullable columns, columns with defaults, new indexes, new enum values added at the end.
   - **Not safe in the same release that stops using it:** dropping or renaming a column, table or enum value, or adding `not null` without a default. Split these up: release 1 stops using the old thing, and a later release drops it.
   - **Enum order is the sort order** (status, priority). Inserting a value in the middle changes the UI ordering, so make sure that's intended.
3. **`/etc/tracklite/env` is unchanged, or the change is planned.** If the release needs a new setting, add it before deploying (see [Changing settings](#changing-settings)). Both processes refuse to start if a required setting is missing.
4. **Take a backup first if the release has a migration that changes or deletes data:**

   ```bash
   sudo systemctl start tracklite-backup.service && journalctl -u tracklite-backup.service -n 5
   ```

5. **Pick a quiet moment.** `tracklite-web` restarts during the switch, so requests fail for a few seconds. Pending notifications are safe: they stay in `notification_deliveries`, and the worker finishes its current batch before it stops.

## 2. Deploy

```bash
ssh -i ~/.ssh/tracklite-deployer deployer@tracklite.example.com
```

```bash
/opt/tracklite/current/ops/deploy.sh
```

It takes a few minutes, mostly `npm ci` and `next build`. The output goes through these stages in order:

1. `== Fetching main from …`
2. `== Installing and building <sha>`
3. `== Migrating the database`. All pending migrations run in one transaction.
4. `== Switching to <sha>`. `current` now points at the new release, and both services restart.
5. `== Removing releases older than the previous one`
6. `== Checking /health`

Success ends with `Deployed <sha>.` and exit code `0`.

## 3. Verify

Spend about 5 minutes on this right after the deploy.

1. **The right release is live:** `readlink /opt/tracklite/current` ends in `-<sha>` of the `main` commit you meant to ship.
2. **Health and headers through Caddy:**

   ```bash
   curl -sI https://tracklite.example.com/health
   ```

   It answers `200` with `strict-transport-security`, `x-content-type-options: nosniff` and `referrer-policy: same-origin`.

   ```bash
   curl -s https://tracklite.example.com/health/worker
   ```

   It answers `ok` once the new worker has finished a pass, within a few seconds of the switch.
3. **Both services are active and not restarting:** `systemctl status tracklite-web tracklite-worker` shows `active (running)`, and the "since" time doesn't keep moving.
4. **No errors in the logs:**

   ```bash
   journalctl -u tracklite-web -u tracklite-worker --since "10 min ago" -p warning
   ```

5. **Smoke test in a browser:** sign in, open a project board, open an issue, and try the changed feature.
6. **Emails still go out** if the release touched notifications: assign an issue to a second account, and check that the email arrives a couple of minutes later.

If any check fails, go to [section 4](#4-when-a-deploy-fails).

## 4. When a deploy fails

What to do depends on how far the deploy got. The last `==` line it printed tells you.

### Failed before or during "Migrating the database"

The deploy deletes the new release and exits non-zero. The old release keeps serving, so **production isn't affected** (OPS-002.2).

- **`npm ci` or `npm run build` failed.** Read the error. If the build was `Killed`, the VPS ran out of memory during `next build`. Stop other heavy processes or add swap, then deploy again.
- **Migrations failed** (`Migrations failed, so nothing was switched.`). The transaction rolled back, so the database is as it was. Fix the migration on `main`, through a normal PR, and deploy again. Never hand-edit the database or `migrations/meta/` to get past it.
- **`git fetch` failed.** Check that the VPS can reach GitHub (`curl -sI https://github.com`).

### Failed at "Checking /health"

The output says `Deployed <sha>, but /health doesn't answer 200.` **The new release is live and unhealthy.** Roll back straight away, then investigate:

```bash
/opt/tracklite/current/ops/rollback.sh
```

```bash
curl -fsS http://127.0.0.1:3000/health
```

After the rollback, `/health` should answer `ok`. Then find the cause in `journalctl -u tracklite-web -n 100`. Common causes:

- `Missing environment variables: …`: a setting the release needs isn't in `/etc/tracklite/env`.
- `/health` answers `503`: the app can't reach PostgreSQL. Check `systemctl status postgresql`.

### `/health/worker` answers `503`

The uptime check emails "Tracklite notifications are stuck".

- **The worker isn't running or keeps restarting.** Check `systemctl status tracklite-worker` and `journalctl -u tracklite-worker -n 100`, then `sudo systemctl restart tracklite-worker`.
- **The worker runs, but the queue doesn't drain.** The `event: "worker"` lines (`journalctl -u tracklite-worker | grep '"event":"worker"'`) show `due` and `oldestDueSeconds` growing. Look for `event: "notification"` errors nearby, such as a provider outage or a wrong `RESEND_API_KEY`.
- **Just after a rollback** to a release from before M13.5: that worker writes no heartbeat, so `/health/worker` keeps answering `503` until a release with M13.5 is deployed again. See [Rollback rules](#5-rollback-rules).

### Deployed fine, but the change is broken

Roll back if users are affected, then fix forward on `main`:

```bash
/opt/tracklite/current/ops/rollback.sh
```

The rollback finishes in seconds (OPS-004.1 allows 2 minutes) and doesn't touch the database.

## 5. Rollback rules

- **One step only.** `rollback.sh` switches `current` back to `previous` and removes the `previous` link. A second rollback in a row refuses with `No previous release to roll back to.` To go back further, revert the bad commits on `main` and deploy.
- **The database isn't rolled back.** That's why the [migration rule](#1-before-you-deploy) matters. If a release did make the schema unusable for the previous code, restoring a backup is the only way back, and it loses every change since that backup. See [Restore](README.md#restore).
- **Rolling back past M13.5 makes `/health/worker` fail.** Releases before M13.5 don't write the `worker_heartbeats` row, so once the last heartbeat is 2 minutes old `/health/worker` answers `503` and the uptime check emails "Tracklite notifications are stuck", even though notifications still go out. Check `journalctl -u tracklite-worker` to confirm the worker is sending, and expect the alert until you deploy a release with M13.5 again.
- **Deploying again after a rollback** builds a fresh release from `main`. If `main` still holds the bad change, revert it first.

## Changing settings

Only your admin account can change `/etc/tracklite/env`; `deployer` can read it but not write it. The file is read by systemd (for the services) and by bash (during `deploy.sh`). Keep each line as plain `NAME=value`, with no spaces, quotes or `export`. For `EMAIL_FROM`, use a bare address such as `notifications@mail.tracklite.example.com`.

```bash
sudo editor /etc/tracklite/env
```

```bash
sudo systemctl restart tracklite-web tracklite-worker
```

Then run the checks in [section 3](#3-verify). Never commit real values; `ops/env.example` is the template.

## First launch on a new server

Do these once, in order. Each step links to its details.

1. DNS `A`/`AAAA` records point at the VPS, and ports 80 and 443 are open.
2. Copy `ops/` to the VPS and, as your admin account, run `sudo ops/provision.sh tracklite.example.com` ([README.md → First set-up](README.md#first-set-up)). Then give `deployer` your SSH key ([README.md → Set up the deployer account](README.md#set-up-the-deployer-account)).
3. Set up the Resend domain, API key and webhook, then fill in `/etc/tracklite/env` ([monitoring-and-email.md → Email domain](monitoring-and-email.md#email-domain-design-55)).
4. As `deployer`, run the first deploy **from a copy of `ops/` in its home**, because `/opt/tracklite/current` doesn't exist yet: `ops/deploy.sh`. Later deploys use `/opt/tracklite/current/ops/deploy.sh`.
5. As `deployer`, create the first admin (OPS-001):

   ```bash
   cd /opt/tracklite/current && (set -a; . /etc/tracklite/env; set +a; npm run setup)
   ```

6. As your admin account, install backups, take the first one and restore it into a scratch database ([README.md → Backups](README.md#backups-m103)).
7. Set up the uptime check on `/health` and `/health/worker` ([monitoring-and-email.md → Uptime check](monitoring-and-email.md#uptime-check-ops-005)).
8. Run the checks by hand in both docs: HTTPS and the redirect, the token-free access log, SPF/DKIM/DMARC, the bounce webhook and both uptime alerts.

## How a deploy works

```
/opt/tracklite/                    owned by deployer; tracklite can only read it
├── repo/                          bare git repo; main is fetched here
├── releases/
│   ├── 20261001120000-abc1234/    ← previous
│   └── 20261008090000-def5678/    ← current
├── current  -> releases/…-def5678 what systemd runs (WorkingDirectory, ExecStart)
└── previous -> releases/…-abc1234 what rollback.sh switches to
```

`deploy.sh` builds the new release next to the live one, migrates, and only then moves `current`. Every deploy deletes all releases except `current` and `previous`. Settings live outside the releases, in `/etc/tracklite/env` (`root:deployer`, mode `640`), so a switch never changes them.
