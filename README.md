# shipit

A small bash tool that turns a brand-new Hostinger VPS (Debian 13) into a host for several Next.js
apps, and deploys each app from its GitHub repo. Each app gets its own Linux user, port, systemd
units, Caddy site and PostgreSQL database, plus one-step rollback and daily local backups.

The design is [docs/plan.md](docs/plan.md).

> **Status:** milestone S0 (skeleton). The dispatcher, shared library and checks exist; every
> command except `help` says it isn't implemented yet. See the milestones in plan §8.

## Quick start

On a fresh VPS, as root (or with `sudo`):

```bash
git clone https://github.com/vespaiach/shipit.git && sudo shipit/install.sh
sudo shipit setup                                     # once per VPS; asks at most three things
sudo shipit deploy https://github.com/<you>/<app>     # first deploy asks for the domain and secrets
```

`install.sh` copies the tool to `/usr/local/lib/shipit` and links `/usr/local/bin/shipit`. Re-run it
after a `git pull` to update.

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
