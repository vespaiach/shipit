# shipit

A small bash tool that turns a fresh Debian 13 VPS into a host for several Next.js apps, and deploys
each one from its GitHub repo.

## Why

I ran [Tracklite](reference/tracklite-ops/) on a VPS with a folder of hand-written deploy, rollback,
provision and backup scripts. They worked, but only for that one app, and they had sharp edges (a
non-atomic symlink switch, a health check that took redirects as healthy, Caddy restarts that could
take every site down). shipit keeps what proved itself there and generalises it, so the next app is
one command instead of another copy of the scripts. It's for one person running a few apps on a
cheap VPS without a PaaS, Docker or Kubernetes.

## How it works

```bash
git clone https://github.com/vespaiach/shipit.git && sudo shipit/install.sh
sudo shipit setup                                     # once per VPS
sudo shipit deploy https://github.com/<you>/<app>     # first deploy asks for the domain and secrets
```

- **`setup`** installs PostgreSQL, Caddy and Node.js LTS, adds swap, a firewall, log rotation, the
  `deployer` build account and SSH hardening. It never overwrites a config it didn't write, and a
  re-run changes nothing.
- **`deploy`** gives each app its own Linux user, port, systemd units, Caddy site (with HTTPS), a
  private state folder (`/var/lib/<app>`) that outlives releases and, optionally, its own PostgreSQL
  database. It builds the branch as `deployer`, runs migrations, then
  switches `/opt/<app>/current` to the new release atomically, restarts the app and checks its health.
  A failed build or migration switches nothing. Later deploys ask nothing.
- **Zero config** for a Next.js app with a `package-lock.json`. A `deploy.conf` in the repo sets custom
  install/build/migrate commands, several processes and a health path; a `.env.example` lists the
  secrets deploy should ask for. Private repos get a read-only deploy key per app.

| Command | What it does |
|---|---|
| `sudo shipit deploy <app> [--ref <sha>]` | Redeploy the branch, or one of its commits |
| `sudo shipit rollback <app>` | Switch back to the previous release (never touches the database) |
| `sudo shipit status [app]` | Releases, processes, health and backups |
| `sudo shipit logs <app> [name]` | Follow the app's log files |
| `sudo shipit env <app>` | Edit the app's secrets, then restart it |
| `sudo shipit backup <app>` | Take a backup now (database or state folder) |
| `sudo shipit restore <app> [file \| latest]` | Restore a backup |

Config examples are in [examples/](examples). The full design is [docs/plan.md](docs/plan.md).

## Platforms and stacks

| | |
|---|---|
| Host | A Debian 13 VPS |
| Apps | Next.js on the system Node.js LTS, zero config; any Node app with a `deploy.conf` |
| Source | GitHub, public (HTTPS) or private (deploy key) |
| Database | PostgreSQL 18 (PGDG), one shared cluster, one role and database per app |
| State on disk | `/var/lib/<app>` per app (systemd `StateDirectory=`), for SQLite files, uploads and snapshots; point the app at it in its env file, like `DATA_DIR=/var/lib/<app>` |
| Backups | Daily, local: `pg_dump` (`BACKUP=postgres`) or a `.tar.gz` of the state folder (`BACKUP=state`, `BACKUP_PATHS`) |
| Web server | Caddy, automatic HTTPS |
| Processes | systemd, one template unit and target per app |

## Limitations

- Builds run on the VPS, one at a time across all apps, so a big build can be slow on a small plan.
- One system Node version for every app, fixed when `setup` first runs.
- Rollback goes back one release only and never undoes migrations: the previous release must work
  with the newer schema.
- Backups (`pg_dump` files or state-folder archives) stay on the VPS's own disk, and logs are local
  files. There is no off-site copy and no alerting; use your provider's snapshots for that.
- Rollback doesn't undo changes to the state folder: whatever the newer release wrote stays. Apps that
  migrate their data when they start should set `HEALTH_FAIL=rollback`, and keep those migrations
  readable by the previous release.
- A state backup copies files as they are, so a live SQLite database (WAL mode) isn't safely backed up.
  Have the app write snapshots (`VACUUM INTO`) and list those in `BACKUP_PATHS`.
- Native modules that need compiling (better-sqlite3, sharp without a matching prebuilt binary) need
  `EXTRA_PACKAGES="build-essential python3"` in `/etc/shipit/host.conf`, then `sudo shipit setup`.
- Single host. No multi-server, load balancing or zero-downtime blue/green; a deploy restarts the app.

## Security notes

- **Anyone who can push to an app's deployed branch runs code on the VPS** as `deployer` (npm scripts,
  build, migrations) and sees that app's secrets during the build. `deployer` owns every app's code,
  so push access to any one app's repo can change every app. Only deploy repos you trust.
- Root never runs or sources repo content; it reads repo files only as data.
- Each app runs as its own user, can't read other apps' code, state folders or backups, or connect to
  their databases, and gets its secrets from systemd. Secrets live in `/etc/<app>/env` (`root:root` 600).
- `setup` turns off SSH password logins (only when you logged in with a key), pins GitHub's SSH host
  keys and enables a firewall. Every config is validated on a temp copy before it's installed.

See plan §5 in [docs/plan.md](docs/plan.md) for the full security model.

## Development

Engineering rules are in [CLAUDE.md](CLAUDE.md). `make lint` and `make test` (needs bash 4.3+, `bats`,
`shellcheck`, `shfmt`, `envsubst` and `flock`) run in CI on every push and PR and must pass before
merging; e2e scenarios run in an Incus
VM with `test/e2e/run.sh`.
