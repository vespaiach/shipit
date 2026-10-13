# shipit

A small bash tool that turns a brand-new Hostinger VPS (Debian 13) into a host for several Next.js
apps, and deploys each app from its GitHub repo. Each app gets its own Linux user, port, systemd
units, Caddy site and PostgreSQL database, plus one-step rollback and daily local backups.

The design is [docs/plan.md](docs/plan.md).

> **Status:** milestone S3. `shipit setup` works, and `shipit deploy` deploys public or private
> GitHub repos, zero-config Next.js apps or apps with a `deploy.conf`, and asks for `.env.example`
> keys. No database, `MIGRATE`, `--ref` or rollback yet. Every other command except `help` says it
> isn't implemented yet. See the milestones in plan §8.

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

**Private repos.** If the repo can't be read anonymously over HTTPS (and always for `ssh://` URLs),
deploy fetches it over SSH with a read-only deploy key made for that app
(`/home/deployer/.ssh/shipit_<app>`). It prints the public key and the repo's GitHub page for adding
it (leave "Allow write access" unticked), then checks every 5 seconds until it works. Ctrl-C stops the
wait; the next deploy picks up with the same key. Host keys come only from `/etc/ssh/ssh_known_hosts`.

**`deploy.conf`** (optional, at the repo root; see [examples/deploy.conf](examples/deploy.conf)) sets
`INSTALL`, `BUILD`, one `PROCESS_<name>=` line per process and, optionally, `HEALTH_PATH` (then health
needs exactly `200`). It's sourced only by `deployer` during the build and by the app user in the
launcher. Root reads just two things from it, as text: process names from lines that start with
`PROCESS_<name>=`, and `HEALTH_PATH` from a line that starts with `HEALTH_PATH=` and holds a plain path
(like `/health`, optionally quoted or followed by a comment). So write those at the start of a line,
not indented, exported or computed. Each process gets an `<app>@<name>` unit. Only one process may
serve HTTP, on `$PORT`.

**`.env.example`** (optional, at the repo root). Every line that starts with `KEY=` (uppercase letters,
digits and `_`) names a key the app needs; comments, indented and `export` lines are ignored, and the
example values are never used. For each key `/etc/<app>/env` doesn't have yet (except `PORT` and
`NODE_ENV`, which the unit sets), deploy asks for a value with hidden input; blank is fine, and quotes,
backslashes and leading or trailing spaces are refused. Keys are only ever added, so a key is asked
once, and a key added in a later release is asked on that deploy. Without a terminal, deploy stops
before building and says to add them with `sudo shipit env <app>`.

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
