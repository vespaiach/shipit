# shipit

A small bash tool that turns a brand-new Hostinger VPS (Debian 13) into a host for several Next.js
apps, and deploys each app from its GitHub repo. Each app gets its own Linux user, port, systemd
units, Caddy site and PostgreSQL database, plus one-step rollback and daily local backups.

The design is [docs/plan.md](docs/plan.md).

> **Status:** milestone S2. `shipit setup` works, and `shipit deploy` deploys a public, zero-config
> Next.js app without a database (no private repos, `deploy.conf`, `.env.example` prompts, database,
> `--ref` or rollback yet). Every other command except `help` says it isn't implemented yet. See the
> milestones in plan §8.

## Quick start

On a fresh VPS, as root (or with `sudo`):

```bash
git clone https://github.com/vespaiach/shipit.git && sudo shipit/install.sh
sudo shipit setup                                     # once per VPS; asks at most three things
sudo shipit deploy https://github.com/<you>/<app>     # first deploy asks for the domain and secrets
```

`install.sh` copies the tool to `/usr/local/lib/shipit` and links `/usr/local/bin/shipit`. Re-run it
after a `git pull` to update.

`setup` asks for an email for TLS notices (may be blank) and the admin username (default `root`),
then installs PostgreSQL 18, Caddy and Node.js LTS, adds swap, the `deployer` account, GitHub's SSH
host keys, a firewall, log rotation and the backup timer template. It turns off SSH password logins
only when this session logged in with a key and the admin has one. It never overwrites a Caddyfile
or `nftables.conf` it didn't write, and a re-run changes nothing.

`deploy <url>` on a new repo asks for the domain (and an app name only if the one derived from the
repo can't be used), picks the next free port from 3001, and writes `/etc/shipit/apps/<app>.conf`.
Then, on every deploy, it creates the app's user, folders, env file (`/etc/<app>/env`), systemd units
and Caddy site; builds the branch as `deployer` (`npm ci`, `npm run build`, one build at a time);
switches `/opt/<app>/current` atomically; restarts `<app>.target`; and checks `/` answers below 500.
Without a `deploy.conf`, the repo needs `next` in `package.json` and a `package-lock.json`. Logs are in
`/var/log/shipit/<app>/` (`web.log`, `web.error.log`, `access.log`, `deploy.log`, and the last 10
build logs in `builds/`).

## Day to day

| Command | What it does |
|---|---|
| `sudo shipit deploy <app>` | Redeploy the app's branch. A changed `/etc/shipit/apps/<app>.conf` takes effect here. |
| `sudo shipit rollback <app>` | Switch back to the previous release. Never touches the database. |
| `sudo shipit status [app]` | Releases, processes, health and backups |
| `sudo shipit logs <app> [process \| access \| deploy]` | Follow the app's log files |
| `sudo shipit env <app>` | Edit the app's secrets, then restart it |
| `sudo shipit backup <app>` | Take a database backup now |
| `sudo shipit restore <app> [file \| latest]` | Restore a backup |
| `shipit help` | List the commands |

Config examples are in [examples/](examples): `app.conf` (per app, in `/etc/shipit/apps/`),
`deploy.conf` (optional, in the app's repo) and `host.conf` (`/etc/shipit/host.conf`).

## Development

See [CLAUDE.md](CLAUDE.md) for the engineering rules. Checks run with `make` (needs `bash` 4.3+,
`bats`, `shellcheck`, `shfmt`, `envsubst` and `flock`):

```bash
make lint   # bash -n, shellcheck, shfmt -i 2 -ci -bn -d
make test   # bats test/unit
```

There's no hosted CI: run `make` before every merge. End-to-end scenarios run in an Incus VM by hand
with `test/e2e/run.sh`.
