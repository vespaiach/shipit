# Server set-up (M10.1)

One Debian 13 VPS runs Caddy, `tracklite-web`, `tracklite-worker` and PostgreSQL 18, all under systemd (design §1.1).

| File in `ops/` | Installed as | What it does |
|---|---|---|
| `Caddyfile` | `/etc/caddy/Caddyfile` | TLS, HTTP→HTTPS redirect, HSTS and the §4.9 headers, `X-Forwarded-For`, access log without `token` |
| `systemd/tracklite-web.service` | `/etc/systemd/system/` | `next start` on `127.0.0.1:3000`, from `/opt/tracklite/current` |
| `systemd/tracklite-worker.service` | `/etc/systemd/system/` | `scripts/worker.ts`, from `/opt/tracklite/current` |
| `journald/tracklite.conf` | `/etc/systemd/journald.conf.d/` | journald keeps 14 days (OPS-006) |
| `logrotate/postgresql-common` | `/etc/logrotate.d/` | PostgreSQL's own log files keep 14 days (OPS-006) |
| `env.example` | `/etc/tracklite/env` (`root:deployer`, mode 640) | secrets and settings (§1.6); real values never go in the repository |
| `sudoers/tracklite-deployer` | `/etc/sudoers.d/` (mode 440) | the only root commands `deployer` may run: restart web and worker, start a backup |

`/opt/tracklite/current` points at the live release. `ops/deploy.sh` creates releases and switches that link (M10.2).

For the step-by-step procedure for each production deploy, see [runbook.md](runbook.md).

## Accounts

Root is used only to set the server up and to change secrets. Deploys and the app run without it.

| Account | Logs in? | What it does | Root? |
|---|---|---|---|
| your admin account | SSH | runs `provision.sh` and `backup/install.sh`, edits `/etc/tracklite/*` | full `sudo` |
| `deployer` | SSH, key only | owns `/opt/tracklite`, runs `deploy.sh`, `rollback.sh` and `npm run setup`, reads the logs | only the commands in `sudoers/tracklite-deployer` |
| `tracklite` | no | runs `tracklite-web` and `tracklite-worker`; can read the releases but not change them | no |
| `postgres` | no | runs PostgreSQL and the daily backup | no |
| `caddy` | no | runs Caddy (from its Debian package) | no |

`deployer` can read `/etc/tracklite/env`, because builds and migrations need `DATABASE_URL`, but only root can change it. `deployer` can't read `/etc/tracklite/backup.env`, so it never sees the R2 token.

`tracklite` doesn't own its code, so a bug in the web process can't rewrite the app it runs.

### Folders and who creates them

You don't make these by hand: the scripts create them with the right owner and mode, and fix them again on a re-run. The only exception is `/home/deployer/.ssh`, which you make when you add your key.

```
/etc/tracklite/                   root:deployer      750  provision.sh
├── env                           root:deployer      640  provision.sh
└── backup.env                    root:root          600  backup/install.sh

/opt/tracklite/                   deployer:deployer  755  provision.sh
├── repo/                         deployer                deploy.sh (first run)
├── releases/                     deployer                provision.sh
│   └── <UTC time>-<commit>/      deployer                deploy.sh (each run)
├── current  -> releases/…        deployer                deploy.sh
└── previous -> releases/…        deployer                deploy.sh (from the second deploy)

/usr/local/lib/tracklite-backup/  root:root          755  backup/install.sh
/home/deployer/.ssh/              deployer:deployer  700  you (see below)
```

### Set up the deployer account

`provision.sh` creates `deployer` with no password, so it can only log in with an SSH key.

1. On your own machine, make a key for deploying if you don't have one:

   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/tracklite-deployer -C tracklite-deployer
   ```

2. On the VPS, as your admin account, give `deployer` that public key. Paste the contents of `~/.ssh/tracklite-deployer.pub` when `tee` waits for input, then press Ctrl-D:

   ```bash
   sudo install -d -m 700 -o deployer -g deployer /home/deployer/.ssh
   ```

   ```bash
   sudo tee -a /home/deployer/.ssh/authorized_keys
   ```

   ```bash
   sudo chown deployer:deployer /home/deployer/.ssh/authorized_keys && sudo chmod 600 /home/deployer/.ssh/authorized_keys
   ```

3. From your machine, check that the login and the sudo rule work. The last command lists the two allowed commands and nothing else:

   ```bash
   ssh -i ~/.ssh/tracklite-deployer deployer@tracklite.example.com
   ```

   ```bash
   sudo -n -l
   ```

4. Optional but recommended: turn off root and password logins over SSH. **Keep your current SSH session open** until a new admin login works, so a mistake can't lock you out:

   ```bash
   printf 'PermitRootLogin no\nPasswordAuthentication no\n' | sudo tee /etc/ssh/sshd_config.d/10-tracklite.conf
   ```

   ```bash
   sudo sshd -t && sudo systemctl reload ssh
   ```

### Moving an existing server off root deploys

Pull the new `ops/` folder onto the VPS and re-run, as your admin account:

```bash
sudo ops/provision.sh tracklite.example.com
```

```bash
sudo ops/backup/install.sh
```

`provision.sh` creates `deployer`, gives it `/opt/tracklite` and makes `/etc/tracklite/env` readable by it. `backup/install.sh` moves the backup scripts from `/opt/tracklite/backup` to `/usr/local/lib/tracklite-backup`, out of the directory `deployer` owns. Then set up the SSH key as above and deploy once as `deployer` to check it.

## First set-up

1. Point the domain's `A`/`AAAA` records at the VPS and open ports 80 and 443.
2. Copy this repository's `ops/` folder to the VPS and run it as your admin account:

   ```bash
   sudo ops/provision.sh tracklite.example.com
   ```

3. Fill in `EMAIL_FROM`, `RESEND_API_KEY` and `RESEND_WEBHOOK_SECRET` in `/etc/tracklite/env`:

   ```bash
   sudo editor /etc/tracklite/env
   ```

4. Give `deployer` your SSH key: see [Set up the deployer account](#set-up-the-deployer-account).
5. Check the Caddy config:

   ```bash
   sudo TRACKLITE_DOMAIN=tracklite.example.com caddy validate --config /etc/caddy/Caddyfile
   ```

6. As `deployer`, deploy the first release from a copy of `ops/`, because `/opt/tracklite/current` doesn't exist yet. From your machine:

   ```bash
   scp -r -i ~/.ssh/tracklite-deployer ops deployer@tracklite.example.com:
   ```

   ```bash
   ssh -i ~/.ssh/tracklite-deployer deployer@tracklite.example.com ops/deploy.sh
   ```

7. Still as `deployer` on the VPS, create the first admin (OPS-001):

   ```bash
   cd /opt/tracklite/current && (set -a; . /etc/tracklite/env; set +a; npm run setup)
   ```

8. Set up the uptime check and the email domain: see [monitoring-and-email.md](monitoring-and-email.md) (M10.4).

## Checks by hand

Replace `tracklite.example.com` with the real domain.

- **The app serves over HTTPS.** `curl -sI https://tracklite.example.com/health` answers `200` with `strict-transport-security: max-age=31536000`, `x-content-type-options: nosniff` and `referrer-policy: same-origin`.
- **SEC-005.1.** `curl -sI http://tracklite.example.com/my-issues` answers a `308` redirect with `location: https://tracklite.example.com/my-issues`.
- **SEC-007.2.** Open `https://tracklite.example.com/reset-password?token=abc`, then run `sudo journalctl -u caddy -n 5`. The logged `uri` is `/reset-password` with no `token`.
- **Logs.** `systemctl status tracklite-web tracklite-worker` shows both as active. `journalctl -u tracklite-web` shows the app's log lines.

# Deploy and rollback (M10.2)

Each release lives in `/opt/tracklite/releases/<UTC time>-<commit>`. `current` points at the live one and `previous` at the one before. Older releases are deleted on each deploy.

## Deploy

As `deployer`, without `sudo` (the script refuses to run as root):

```bash
/opt/tracklite/current/ops/deploy.sh
```

It fetches `main` from GitHub, runs `npm ci` and `npm run build` in a new release directory, then runs `npm run db:migrate`. All pending migrations run in one transaction. If they fail, the command deletes the new release, prints the error and exits non-zero, and the old release keeps running (OPS-002.2). If they succeed, it switches `current`, restarts `tracklite-web` and `tracklite-worker` through the `sudo` rule, and waits for `/health` to answer `200` (OPS-002.1).

`/etc/tracklite/env` is read both by systemd and, during a deploy, by the shell, so keep each line as plain `NAME=value` with no spaces or quotes.

## Rollback

As `deployer`:

```bash
/opt/tracklite/current/ops/rollback.sh
```

It points `current` back at `previous` and restarts web and worker, without touching the database (OPS-004). That only works because every release's migrations must also work with the previous release's code: add columns and tables, don't drop or rename them in the same release that stops using them. A second rollback in a row refuses, because the previous release is gone once you've switched back to it.

## Checks by hand

- **OPS-002.1.** Merge a change to `main` and deploy. The command ends with `Deployed <commit>.`, `readlink /opt/tracklite/current` names that commit and the change is live.
- **OPS-002.2.** On a scratch branch, add a migration containing `select 1/0;`, push it to `main` on a test VPS and deploy. The command prints `division by zero` and `Migrations failed, so nothing was switched.`, exits non-zero, and `current` still names the old commit.
- **OPS-004.1.** Right after a deploy, run the rollback and time it. It finishes well within 2 minutes, `readlink /opt/tracklite/current` names the earlier commit and `/health` answers `200`.

# Backups (M10.3)

Every day at 03:00 UTC a systemd timer dumps the database, encrypts the dump with [age](https://age-encryption.org) and uploads it to a Cloudflare R2 bucket with rclone, keeping the newest 14 (OPS-003). If the backup fails, the owner gets an email through Resend.

| File in `ops/backup/` | Installed as | What it does |
|---|---|---|
| `backup.sh` | `/usr/local/lib/tracklite-backup/` | `pg_dump` → `age` → R2, then deletes all but the newest 14 |
| `notify-failure.sh` | `/usr/local/lib/tracklite-backup/` | emails `OWNER_EMAIL` with the last log lines (OPS-003.3) |
| `restore.sh` | `/usr/local/lib/tracklite-backup/` | downloads, decrypts and restores a backup into a database (OPS-003.1) |
| `tracklite-backup.service` | `/etc/systemd/system/` | runs `backup.sh` as `postgres`; `OnFailure=` starts the unit below |
| `tracklite-backup-failed.service` | `/etc/systemd/system/` | runs `notify-failure.sh` as a throwaway user (`DynamicUser=`) that can read the journal |
| `tracklite-backup.timer` | `/etc/systemd/system/` | `03:00 UTC` daily; `Persistent=` catches up after downtime |
| `backup.env.example` | `/etc/tracklite/backup.env` (mode 600) | owner email, age public key, R2 bucket and token |

Backups are encrypted to an age public key. The private key never goes on the VPS, so a stolen VPS or a leaked R2 token can't read old backups. Losing the private key means losing every backup, so keep it in two places (for example, the team password manager and an offline copy).

## Set-up

1. On your own machine, make the key pair. Store `tracklite-backup.key` safely, and copy the `age1…` public key it prints:

   ```bash
   age-keygen -o tracklite-backup.key
   ```

2. In Cloudflare, create an R2 bucket (for example `tracklite-backups`) and an R2 API token with **Object Read & Write** on that bucket only. Note the account ID, access key ID and secret.
3. On the VPS, as your admin account, after `ops/provision.sh`:

   ```bash
   sudo ops/backup/install.sh
   ```

4. Fill in `/etc/tracklite/backup.env`:

   ```bash
   sudo editor /etc/tracklite/backup.env
   ```

5. Take the first backup now, then check it worked:

   ```bash
   sudo systemctl start tracklite-backup.service
   ```

   ```bash
   sudo journalctl -u tracklite-backup.service -n 5
   ```

## Restore

On any machine with `rclone`, `age` and PostgreSQL 18's `pg_restore`, export the R2 lines from `backup.env` into the shell, create an empty database, and restore into it. Leave out the backup name to restore the newest one.

```bash
createdb tracklite_restore
```

```bash
ops/backup/restore.sh tracklite-backup.key postgres://localhost/tracklite_restore
```

After losing the VPS (OPS-003.1): provision a new one, deploy, stop `tracklite-web` and `tracklite-worker`, restore into the empty `tracklite` database as its owner, then start them again.

## Checks by hand

- **A backup restores into a scratch database (M10.3 Done, and the pre-launch restore test).** Run the two restore commands above, then `psql tracklite_restore -c 'select count(*) from issues'` matches the live count from the time of the backup.
- **OPS-003.2.** `rclone lsf r2:$R2_BUCKET` lists at most 14 `tracklite-*.dump.age` files once the timer has run 15 times. To check sooner, run `sudo systemctl start tracklite-backup.service` 15 times and count again.
- **OPS-003.3.** Set `R2_BUCKET` to a bucket that doesn't exist, run `sudo systemctl start tracklite-backup.service`, and check that `OWNER_EMAIL` gets "Tracklite backup failed". Then put the right value back.
- **Timer.** `systemctl list-timers tracklite-backup.timer` shows the next run at 03:00 UTC.
