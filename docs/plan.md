# shipit — plan

A small bash tool that turns a brand-new Hostinger VPS into a host for several Next.js apps, and deploys each app from its GitHub repo. It has two parts:

1. **`sudo shipit setup`**, run once on a fresh VPS. It asks for at most three things.
2. **`sudo shipit deploy <github-url | app>`**, run as often as you like, for as many apps as you like. The first deploy of an app asks for its domain and secrets. Every later deploy asks nothing.

Each app has its own deploy and rollback, and no app can overwrite another app's files, port, units or database.

It generalises Tracklite's `ops/` folder (`reference/tracklite-ops/`) and keeps its proven ideas:

- `releases/<UTC time>-<sha>`, with `current` and `previous` symlinks;
- build, then migrate, then switch only on success;
- one-step rollback that never touches the database;
- the deploy account owns the code, and the runtime user only runs it;
- systemd hardening;
- daily `pg_dump` backups.

## Scope

| Constraint | Consequence |
|---|---|
| Hostinger KVM 1, 2 or 4 (1/2/4 vCPU, 4/8/16 GB RAM, 50/100/200 GB NVMe) | `setup` sizes swap from the RAM it finds: 4 GB of swap below 6 GB of RAM, 2 GB otherwise. There's one build at a time on every plan. |
| Debian 13 only | No distro detection. `setup` refuses anything else. |
| Apps come from GitHub, public or private | Public repos are fetched over HTTPS without credentials. Private repos use one read-only deploy key per app. |
| Node.js LTS, Next.js latest | One system Node: the LTS major version current when `setup` first runs, recorded in `host.conf`. Zero-config deploys assume Next.js. |
| PostgreSQL 18 | Comes from PGDG. One shared cluster, with one role and one database per app. |
| Backups: a local dump folder named by date and time, with no remote copy and no email | `/var/backups/shipit/<app>/<app>-<UTC>.dump`. No R2, no `age`, no `rclone`, no alert unit. |
| Logs: files on the VPS, with no remote copy | `/var/log/shipit/<app>/`, rotated by logrotate and kept 14 days |

## Decisions

| # | Decision | Choice |
|---|---|---|
| 1 | Where builds run | **On the VPS for now**, behind a build lock shared by all apps (`flock /var/lib/shipit/build.lock`), plus swap. Deploy is split at a *release directory* boundary, so a later "CI artifact" mode only changes how that directory gets filled. |
| 2 | Who runs commands | **The admin: `root` by default, or a named user with password-less `sudo`.** Every command except `help` needs root. Root runs the host-level steps itself and runs repo code (`INSTALL`, `BUILD`, `MIGRATE`) as `deployer` with `runuser`. The only sudoers file shipit writes is the named admin's (section 4). |
| 3 | Build account | **One shared `deployer`** system account with no login. See R1. Its name lives in one variable (`DEPLOY_USER`), so per-app build users can be added later. |
| 4 | Process units | **One template unit per app plus a launcher.** `<app>@.service` runs `/usr/local/lib/shipit/libexec/run <app> %i`, which reads `PROCESS_%i` from `current/deploy.conf` when the process starts. If the process isn't defined in that release, the launcher exits 78, and the unit sets `RestartPreventExitStatus=78`. `<app>.target` groups the processes with `PartOf=`. |
| 5 | Node version | **One system Node LTS.** Its major version is fixed in `host.conf` when `setup` first runs and is never changed automatically. The launcher and the build find `node` through a single `PATH` they build themselves, which is the hook for per-app Node later. |
| 6 | App set-up | **Folded into `deploy`.** The first deploy of an app creates its user, folders, database, env file, units and site. Every deploy re-applies them idempotently, and that's also how a changed app config takes effect. There's no separate `app-add` or `app-sync` command. |
| 7 | `deploy.conf` | **Optional.** Without it, a Next.js app deploys with zero config (section 2). With it, the app can set its own commands, several processes and a strict health path. |
| 8 | Private repos | **Deploy key, then wait.** `deploy` prints the public key and the GitHub URL to paste it into, then retries `git ls-remote` every 5 seconds until GitHub accepts it. The tool is never given a GitHub token. |
| 9 | SSH hardening | **On**, in `setup`, but only when the current session was a key login (section 3). Password logins are turned off for everyone. If the admin is `root`, root may still log in, but only with a key (`PermitRootLogin prohibit-password`). If the admin is a named user, root login is turned off (`PermitRootLogin no`) and the admin uses `sudo` without a password. |
| 10 | Root never runs or sources repo content | Root reads repo files only as data, with strict `grep -E` patterns, `jq`, or `git show` run as `deployer`. `deploy.conf` is sourced only by `deployer` (during a build) and by the app user (in the launcher). |

## Fixes to bugs in today's `ops/`, carried into shipit

| Today | Problem | shipit |
|---|---|---|
| `ln -sfn "$release" current` | Not atomic: it unlinks, then creates the link. A crash-restart in that gap finds no `current`. | `ln -s "$release" current.new && mv -T current.new current` |
| `curl -fsS …/health` | `-f` fails only on status 400 or above, so a `301`/`308` counts as healthy. | Read the status with `-w '%{http_code}'` and send `Host: $DOMAIN`. With `HEALTH_PATH` set, require exactly `200`. |
| `provision.sh` installs the sudoers file, *then* runs `visudo -c` | A bad file in `sudoers.d` breaks **all** `sudo` on the host. | The admin's sudoers file is rendered to a temp path, checked with `visudo -cf`, then installed (mode 440). Every other config file is validated on a temp copy the same way. |
| `rollback.sh` takes no lock | A rollback can race a deploy of the same app. | Rollback takes the app's lock. |
| Caddy changes followed by `systemctl restart caddy` | A restart with a broken config takes every site down. | `caddy validate`, then `systemctl reload caddy`, never restart. A failed reload keeps the old config running. |
| The env file is sourced by bash during the build | A value with spaces, quotes or `$` means one thing to bash and another to systemd. | The build reads the env file line by line as literal `KEY=value`, the way systemd does. The prompt refuses quotes, backslashes and newlines. |

---

## 1. Repo layout

```
shipit/
├── README.md                    what it is, the two-step quick start, the day-to-day commands
├── CLAUDE.md                    engineering rules and how to work, for later sessions
├── install.sh                   root: copies lib/ libexec/ templates/ to /usr/local/lib/shipit, links /usr/local/bin/shipit
├── bin/shipit                   dispatcher: parses the command, requires root, sources lib/common.sh
├── lib/
│   ├── common.sh                log/die, validators, config loading, locks, render()
│   ├── setup.sh
│   ├── deploy.sh                new-app questions, then set-up steps, then the release steps
│   ├── rollback.sh
│   ├── status.sh
│   ├── logs.sh
│   ├── env.sh
│   └── restore.sh               (`shipit backup` is one line in bin/shipit)
├── libexec/                     run by systemd, never by people
│   ├── run                      process launcher
│   └── backup                   pg_dump to /var/backups/shipit/<app>, then prune
├── templates/
│   ├── Caddyfile                root: global options plus `import /etc/caddy/sites/*.caddy`
│   ├── site.caddy
│   ├── app@.service
│   ├── app.target
│   ├── shipit-backup@.service
│   ├── shipit-backup@.timer
│   ├── nftables.conf
│   ├── sshd.conf                drop-in: no passwords; root key-only or off
│   ├── sudoers                  password-less sudo for a named admin
│   └── logrotate
├── examples/
│   ├── app.conf  deploy.conf  host.conf
├── docs/
│   ├── plan.md
│   ├── security.md              the security model below
│   ├── runbook.md               a generic version of Tracklite's runbook
│   └── adopting-a-host.md       moving a server that runs a hand-made app (Tracklite) onto shipit
└── test/
    ├── unit/*.bats              validators, parsers, render() against golden files
    ├── golden/                  expected rendered units, site file, nftables, sshd drop-in
    ├── fixtures/next-app/       the smallest real Next.js app (zero-config path)
    ├── fixtures/node-app/       tiny Node HTTP server + worker + SQL migration, with deploy.conf; a flag makes the migration fail
    └── e2e/run.sh               full scenarios inside an Incus VM (section 7)
```

Templates are rendered with `render <template> <VAR>...`, which calls `envsubst` with an explicit variable list. Caddy's `{remote_host}` and any other `$` in a template then pass through untouched, and there's no `sed` escaping to get wrong. **`render` fails if any listed variable is unset or empty**, naming the variable, and then writes nothing. Without that, `envsubst` would quietly turn `reverse_proxy 127.0.0.1:$PORT` into a broken but valid-looking config. `render` writes to stdout, and callers redirect to a temp file.

## 2. Inputs

### What a person types

| Command | Asks | Only when |
|---|---|---|
| `setup` | The email for TLS certificate notices (may be blank) | `host.conf` doesn't exist yet |
| `setup` | Admin username (default `root`). No password is ever asked for. | `host.conf` doesn't exist yet |
| `deploy <url>` | Domain | First deploy of this app |
| `deploy <url>` | App name | The name derived from the repo is invalid or already taken by a different repo |
| `deploy <url>` | "Create a PostgreSQL database? [Y/n]", with the default from `package.json` | First deploy of this app |
| `deploy <url>` | "Add this deploy key to GitHub…", then waits | Private repo and no working key yet |
| `deploy` | A value for each `.env.example` key that the env file doesn't have yet (input hidden, blank allowed) | A key is missing. Asked again on a later deploy only if a new key appears. With no terminal attached, deploy fails and points to `shipit env <app>`. |

### What the tool works out

| Value | How |
|---|---|
| App name | The repo name, lowercased, with `-` and `.` turned into `_`: `my-app` becomes `my_app` |
| `BRANCH` | The repo's default branch, from `git ls-remote --symref <repo> HEAD` |
| Public or private | An anonymous `git ls-remote` over HTTPS (`GIT_TERMINAL_PROMPT=0`). If it fails, the repo is private, and the tool uses the SSH URL and a deploy key. `ssh://` URLs always use a deploy key. A private repo's default branch is read once the key works, after the other new-app questions. |
| `PORT` | The lowest port from 3001 up that no app config uses and nothing is listening on. It's chosen once and stored. |
| Database | Asked with "yes" as the default if `package.json` lists `pg`, `postgres`, `drizzle-orm`, `prisma` or `@prisma/client` |
| `DATABASE_URL`, `APP_URL` | Written into the env file. `PORT` and `NODE_ENV` come from the unit instead. |
| Swap, Node major version | From the RAM, and from `https://nodejs.org/dist/index.json` (the newest release with `lts` set), on the first `setup` run |

### `deploy.conf` (optional, in the app's repo)

It's sourced by bash, as `deployer` during a deploy and as the app user by the launcher. `PORT` is already set when it's sourced.

```bash
INSTALL="npm ci --no-audit --no-fund"
BUILD="npm run build"
MIGRATE="npm run db:migrate"            # optional
HEALTH_PATH=/health                     # optional; if set, health requires exactly 200
PROCESS_web="next start --hostname 127.0.0.1 --port $PORT"
PROCESS_worker="tsx --conditions=react-server scripts/worker.ts"
```

**Without `deploy.conf` (zero config).** `package.json` must list `next` and the repo must have `package-lock.json`. Otherwise deploy refuses and says which file to add. The defaults are then:

- `INSTALL="npm ci --no-audit --no-fund"`
- `BUILD="npm run build"`
- `MIGRATE="npm run db:migrate"`, only if `package.json` has that script
- one process, `PROCESS_web="next start --hostname 127.0.0.1 --port $PORT"`
- health is a request to `/` that counts as healthy if the status is **below 500**. Many apps redirect `/` to a login page, so the zero-config check can't demand 200.

Other package managers (`pnpm`, `yarn`) are supported only through `deploy.conf`, for example `INSTALL="npx --yes pnpm@9 install --frozen-lockfile"`.

Only one process per app can serve HTTP, because an app has one `PORT`.

### `/etc/shipit/apps/<app>.conf` (`root:root`, 644, no secrets)

`deploy` writes it on an app's first deploy. You can edit it, and the next `deploy` applies the change. You can also write it by hand before the first deploy (Tracklite's adoption does this), and then that deploy asks nothing.

```bash
REPO=git@github.com:vespaiach/tracklite.git
BRANCH=main
DOMAIN=tracklite.example.com
PORT=3001
DATABASE=tracklite          # optional; empty means no database
HEALTH_FAIL=report          # report (default) | rollback
LOG_REDACT_QUERY="token"    # optional; query parameters removed from the access log
```

### `/etc/<app>/env` (`root:root`, 600)

The app's secrets. `deploy` creates it with `DATABASE_URL` and `APP_URL` plus your answers to the `.env.example` prompts, and only ever adds keys afterwards. systemd reads it for the app. During a deploy, root reads it and passes it to the `deployer` build, so `deployer` can't read any app's env file at rest. Edit it with `sudo shipit env <app>`.

### `/etc/shipit/host.conf` (`root:root`, 644, no secrets)

`setup` writes it on its first run: `ACME_EMAIL`, `ADMIN_USER` (default `root`), `NODE_MAJOR`, `SWAP_SIZE`, `BACKUP_KEEP=14`, `LOG_KEEP_DAYS=14` and `MIN_FREE_DISK_GB=3`. Later runs read it and never rewrite it.

### Validation (in `common.sh`, used by every command)

| Value | Rule | Why |
|---|---|---|
| app name | `^[a-z][a-z0-9_]{0,30}$`. Not an existing system user unless that user's GECOS field is `shipit app`. Not an existing `<app>@.service` or `<app>.target` unit file unless it's marked `# managed by shipit` (checked in `deploy`, because it needs systemd). | The name becomes a Linux user, a systemd unit and a Postgres name. A dot in the name would put a dot in unit and file names. An unmarked unit check stops an app called `postgresql`, `user` or `getty` from writing `/etc/systemd/system/<name>@.service`, which would override Debian's own template. |
| process name | `^[a-z][a-z0-9_]*$` | It becomes a systemd instance name and a shell variable name. |
| `DOMAIN` | A lowercase hostname with at least one dot. Each label is 1–63 characters of `[a-z0-9-]` and doesn't start or end with `-`. No trailing dot, no wildcard. Unique across all app configs (another app using it is refused; the same app is fine). | It's written into a Caddyfile. |
| `PORT` | `^[1-9][0-9]*$`, from 1024 to 65535, and unique across all app configs except the app's own. **When an app gets a new port** (a first deploy, or an edited config), also check that it's not listening (`ss -ltnH`). The listening check is skipped when the app's installed `<app>@.service` already sets that same `PORT`, because a running app is always listening on its own port. | Two apps on one port is the main multi-app failure. Without the own-port exception, every redeploy would refuse. |
| `REPO` | A GitHub URL (`https://github.com/<owner>/<repo>[.git]` or `git@github.com:<owner>/<repo>.git`), or any `ssh://` or `file://` URL (the e2e tests use these) | It's passed to git as `deployer`. |
| `--ref` | Must resolve to a commit reachable from the fetched `BRANCH` | Keeps today's rule that only the deployed branch ships, and still allows redeploying an older commit from it. Added with redeploys (S5). |
| env value | No newline, no quote or backslash, no leading or trailing whitespace | systemd and the build read the file literally, so these characters would mean different things to them. |
| any file the tool sources from `/etc/shipit` | Owned by root and not writable by group or others | Root sources these files. A writable one would run someone else's code as root. |

**Test seams.** `common.sh` sets plain constants (`DEPLOY_USER=deployer`, `SHIPIT_ETC=/etc/shipit`, `SHIPIT_VAR=/var/lib/shipit`, `SHIPIT_OPT=/opt`). Unit tests source `common.sh` and reassign them. They aren't read from the environment and there are no flags for them. The lock helpers take the lock file's path as an argument. Tests stub `getent`, `ss` and `systemctl` through `PATH`.

## 3. Commands

Every command except `help` must run as root, and refuses with `Run this as root, or with sudo: sudo shipit <command> …` otherwise. Every deploy and rollback appends one line (time, app, sha, admin user, result) to `/var/log/shipit/<app>/deploy.log`. The full build output is also written to `builds/deploy-<UTC>.log` beside it, with only the newest 10 kept. They're in a subfolder so logrotate's `/var/log/shipit/*/*.log` doesn't rotate them; deploy prunes them instead.

### `shipit setup` — once per VPS, idempotent

| Step | What it does | If it fails or is skipped |
|---|---|---|
| 1. Guards | Requires Debian 13 and root. | Stops before changing anything. |
| 2. Host config | If `host.conf` is missing, asks for the ACME email, picks the Node LTS major version and the swap size, and writes the file. | |
| 3. Packages | PostgreSQL 18 (PGDG), Caddy (Cloudsmith), Node `$NODE_MAJOR` (NodeSource), `git`, `curl`, `jq`, `gettext-base`, `nftables` and `unattended-upgrades` (security updates only, Debian's default). | Stops at the first failing step. A re-run continues. |
| 4. Swap | Creates `/swapfile` of `SWAP_SIZE` if there's no swap. | |
| 5. Users | **`deployer`**: `useradd --system --create-home --home-dir /home/deployer --shell /usr/sbin/nologin`. **The admin**: nothing to do if `ADMIN_USER` is `root`. For a named user that doesn't exist yet, it creates the user with a locked password (`useradd --create-home --shell /bin/bash`, so key login only), copies root's `~/.ssh/authorized_keys` to it, and installs `/etc/sudoers.d/shipit-admin` (rendered, `visudo -cf`, then `install -m 440`). | |
| 6. GitHub host keys | Writes GitHub's published SSH host keys (from `https://api.github.com/meta`) into `/etc/ssh/ssh_known_hosts`, so the first fetch doesn't trust on first use. | |
| 7. Firewall | Renders `/etc/nftables.conf` (drop inbound except established, loopback, ICMP, the SSH port read from `sshd -T`, 80 and 443 over TCP and 443 over UDP). Validates it with `nft -c -f`, installs it, and enables and reloads `nftables`. **Only if the file is missing, marked `# managed by shipit`, or still Debian's unmodified packaged default** (its md5 matches the package's conffile entry). Otherwise it leaves the file alone and says so. | The current SSH session survives, because established connections are accepted first. |
| 8. SSH hardening | Only if **both** of these hold: the admin has a non-empty `authorized_keys`, and this session logged in with a key (the journal line `sshd-session[<pid>]: Accepted publickey for …`, where `<pid>` is one of this process's ancestors; `SSH_CLIENT` isn't used because `sudo` drops it). Then it writes `/etc/ssh/sshd_config.d/10-shipit.conf` (`PasswordAuthentication no`, `KbdInteractiveAuthentication no`, and `PermitRootLogin prohibit-password` when the admin is `root` or `no` otherwise), runs `sshd -t` and reloads `ssh`. The `10-` prefix wins over Hostinger's `50-cloud-init.conf`, because sshd uses the first value it reads. | If a condition fails, it skips this step and says which one. It ends with: `Open a NEW terminal and log in as <admin> before closing this one. If that fails, use Hostinger's browser terminal and delete /etc/ssh/sshd_config.d/10-shipit.conf.` |
| 9. Caddy | Writes `/etc/caddy/Caddyfile` **only if it's missing, marked `# managed by shipit`, or the caddy package's unmodified default**, creates `/etc/caddy/sites/`, validates, and reloads. | If it finds a Caddyfile it didn't write, it writes `/etc/caddy/Caddyfile.shipit` instead and says how to switch (section 6). |
| 10. Folders | `/var/lib/shipit/` (root, holds the locks), `/var/log/shipit/` (`root:adm` 751, so `caddy`, which isn't in `adm`, can reach each `access.log` but nobody can list the folder), `/var/backups/shipit/` (root 711, so `postgres` can reach its own `<app>/` folder but can't list the others) | |
| 11. Rotation and backups | `/etc/logrotate.d/shipit` (daily, `LOG_KEEP_DAYS`, `copytruncate`, `compress`) and the `shipit-backup@.{service,timer}` templates | |

Output: a summary of what changed, a warning if RAM plus swap is below 4 GB, and the next step, `sudo shipit deploy https://github.com/<you>/<app>`.

### `shipit deploy <github-url | app> [--ref <sha>]`

`<app>` redeploys an existing app. A URL redeploys the app whose `REPO` matches it, or else starts a new app.

**A. New app only: questions.** Derive the name, then ask for the domain. Check DNS (`getent ahosts`) against the VPS's public IP. If they don't match, print `Point an A record for <domain> at <ip>. Caddy will get the certificate once it does.` and carry on. Detect public or private, pick the port, ask about the database, then write `apps/<app>.conf`.

**B. Every deploy: guards.** Load `apps/<app>.conf` after the ownership check, and validate every value. Check there's at least `MIN_FREE_DISK_GB` free under `/opt`. Take `flock -n /var/lib/shipit/<app>.lock`. If it's held, print `Another deploy or rollback of <app> is running.` and exit 1.

**C. Every deploy: set-up that doesn't depend on the release** (each step checks before acting):

| Step | What it does |
|---|---|
| Runtime user | `useradd --system --shell /usr/sbin/nologin --comment 'shipit app' <app>`. Refuses if the user exists without that marker. |
| Folders | `/opt/<app>` is `deployer:<app>` with mode **750**, so other apps' users can't read it. `releases/` and `repo/` inside it belong to `deployer`. `/var/log/shipit/<app>/` is `root:adm` 751 (for `caddy`, as above), and `access.log` there is pre-created as `caddy:adm` 640. Step D7 pre-creates each process's `<process>.log` and `<process>.error.log` as `root:adm` 640 before systemd first opens them, so they're never world-readable. |
| Repo access | Private repos only. Creates `~deployer/.ssh/shipit_<app>` (ed25519) if it's missing. If `git ls-remote` fails, it prints the public key and `https://github.com/<owner>/<repo>/settings/keys/new` ("Allow write access" left unticked), then retries every 5 seconds until it works. Ctrl-C stops it, and the next deploy picks up from there. Fetches use `GIT_SSH_COMMAND="ssh -i … -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/dev/null"`, so only the host keys in `/etc/ssh/ssh_known_hosts` are trusted. |
| Database | Only if `DATABASE` is set. Creates the role with a random password and the database owned by it, then runs `revoke connect … from public` and `grant connect … to <role>`. If the role exists but `/etc/<app>/env` doesn't, the password can't be recovered, so it refuses and prints the `alter role … password` fix. |

**D. Every deploy: the release.**

1. **Fetch** `BRANCH` into the bare repo as `deployer`, resolve `--ref` or `FETCH_HEAD`, and check the ref is reachable from the branch.
2. **Extract** with `git archive` into `releases/<UTC>-<sha>`, as `deployer`. From here until the switch, a `trap` deletes that folder on any exit.
3. **Resolve the commands.** Use `deploy.conf` if the release has one, or the zero-config defaults otherwise. Root reads the process names with `grep -E '^PROCESS_[a-z][a-z0-9_]*='` only, and `HEALTH_PATH` from the last line that starts with `HEALTH_PATH=`, whose value must be a plain path (`/[A-Za-z0-9._~/-]*`, optionally quoted or followed by a `#` comment; anything else is refused). Indented, `export`ed or computed lines are ignored. Root reads release files as `deployer` (`cat`), so a symlink in the repo can't point it elsewhere. A `deployer` subshell sources `deploy.conf` and requires `INSTALL`, `BUILD` and at least one `PROCESS_*`.
4. **Env file.** Read the key names from the release's `.env.example` (`grep -E '^[A-Z_][A-Z0-9_]*='`; comments, indented and `export` lines are ignored, and example values are never used). Ask for any key that `/etc/<app>/env` doesn't have, except `PORT` and `NODE_ENV` (the unit sets them, and the env file would override it), then write the file (render to a temp file, then `install -m 600`).
5. **Build**, holding the shared build lock: `flock /var/lib/shipit/build.lock`. If it has to wait, it prints `Waiting for another app's build…`. Runs `INSTALL` then `BUILD` as `deployer`, with the env file and `PORT` exported. The build log records when the lock was taken and released.
6. **Migrate**, if there's a `MIGRATE` command. On failure, print `Migrations failed, so nothing was switched. Still serving <old>.`, delete the release, and exit 1.
7. **Units and site.** Render `<app>@.service`, `<app>.target` (whose `Wants=` lists the release's processes) and `sites/<app>.caddy` to temp files. Create an empty `sites/<app>.extra` if it's missing (it's never overwritten). Validate with `systemd-analyze verify` and `caddy validate`, with the new site in place. Install only the files that changed, then run `daemon-reload` and `enable <app>.target`. Reload Caddy if the site changed and the root Caddyfile is shipit's. Enable `shipit-backup@<app>.timer` if `DATABASE` is set. If any validation fails, the old files stay, the release is deleted, and the command exits 1.
8. **Switch.** Point `current` and then `previous` at their releases, each atomically with `mv -T`.
9. **Restart** `<app>.target`. `PartOf=` passes the restart on to every process. Instances the release no longer lists are stopped.
10. **Prune** every release except `current` and `previous`.
11. **Check health.** Poll `http://127.0.0.1:$PORT$HEALTH_PATH` with `Host: $DOMAIN` for up to 60 seconds. With `HEALTH_PATH` set, require `200`. Without it, poll `/` and require a status below 500.
    - On success, print `Deployed <sha>. https://<domain>` and exit 0.
    - On failure with `HEALTH_FAIL=report`, print `Deployed <sha>, but <path> answered <code>. Switch back with: sudo shipit rollback <app>` and exit 1.
    - On failure with `HEALTH_FAIL=rollback`, run the rollback steps (the lock is already held) and exit 1 with `Rolled back to <previous>; the database keeps <sha>'s migrations.`

Adding a process to `deploy.conf` needs no extra step: step 7 creates its unit on the next deploy.

The seam for "CI builds later": steps D1–D5 produce a release folder. A later `--artifact <url>` mode downloads a tarball and unpacks it instead. Steps D6–D11 don't change.

### `shipit rollback <app>`

Takes the app lock. Refuses with `No previous release to roll back to.` if `previous` is missing. Otherwise it:

1. re-renders `<app>.target` from `previous/deploy.conf`'s process names (using `grep`);
2. switches `current` to `previous` atomically and removes `previous`;
3. restarts `<app>.target`, which stops the instances that release doesn't list;
4. runs the health check and reports the result.

It doesn't roll forward or touch the database. Because the launcher reads `current/deploy.conf`, the previous release's commands come back automatically.

### `shipit status [app]`

For each app, or the one named: the `current` and `previous` releases (time and sha), `systemctl is-active` for each instance, the health check's status code, the last line of `deploy.log`, and the last backup's file name and result. It also runs `caddy validate` once and reports the result. It's read-only.

### `shipit logs <app> [process | access | deploy]`

Runs `tail -n 100 -F` on the chosen file, or on all of the app's current log files when nothing is named.

### `shipit env <app>`

Opens a copy of `/etc/<app>/env` in `$EDITOR` (falling back to `nano`), validates every line against the env-value rule, installs it with mode 600, then restarts `<app>.target`.

### `shipit backup <app>`

Runs `systemctl start shipit-backup@<app>.service`, then prints the new file's name and size.

### `shipit restore <app> [file | latest]`

Asks you to type the app name to confirm. Then it takes a fresh backup first, stops `<app>.target`, runs `pg_restore --clean --if-exists --no-owner --role=<app> --dbname <db>` from the chosen file in `/var/backups/shipit/<app>/`, and starts the target again.

### `libexec/run <app> <process>` — the launcher, run by systemd as `<app>`

1. Validates both arguments.
2. Sets `PATH=/opt/<app>/current/node_modules/.bin:/usr/bin:/bin`. This is the hook for per-app Node later.
3. Sources `/opt/<app>/current/deploy.conf` if it exists. Otherwise it uses the zero-config `PROCESS_web`.
4. If `PROCESS_<process>` is unset, prints `<process> isn't defined in this release` and **exits 78**. `RestartPreventExitStatus=78` stops systemd restarting it in a loop.
5. Otherwise runs `exec bash -c "exec $cmd"`. Both `exec`s matter: they make the app the unit's main process, so `SIGTERM` reaches it directly. Tracklite's worker relies on that to finish its batch before stopping.

### `libexec/backup <app>` — run by `shipit-backup@<app>.service` as `postgres`

Reads `DATABASE` from the app config and writes `pg_dump --format=custom` to a temp file in `/var/backups/shipit/<app>/`. It then renames the file to `<app>-<YYYYmmddTHHMMSSZ>.dump`, so a half-written dump never has a real name, and deletes all but the newest `BACKUP_KEEP`. A failed backup shows up in `shipit status`. No email is sent.

## 4. Generated files

Example values: app `tracklite`, port `3001`.

**`/etc/caddy/Caddyfile`** (written by `setup`):

```caddy
# managed by shipit — one site per file in /etc/caddy/sites
{
	email owner@example.com
}

import /etc/caddy/sites/*.caddy
```

The `email` line is left out when `ACME_EMAIL` is blank.

**`/etc/caddy/sites/tracklite.caddy`** (written by `deploy`):

```caddy
# managed by shipit — edit /etc/shipit/apps/tracklite.conf or tracklite.extra instead
tracklite.example.com {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000"
		X-Content-Type-Options "nosniff"
		-Server
	}

	reverse_proxy 127.0.0.1:3001 {
		header_up X-Forwarded-For {remote_host}
	}

	log {
		output file /var/log/shipit/tracklite/access.log {
			roll_disabled
		}
		format filter {
			request>uri query {
				delete token
			}
		}
	}

	import /etc/caddy/sites/tracklite.extra
}
```

The `delete` lines come from `LOG_REDACT_QUERY`. With nothing to redact, the `format filter` block is left out. Rotation is done by logrotate (`copytruncate`), not Caddy, so every log file under `/var/log/shipit` is kept for the same time. Tracklite's `tracklite.extra` holds `header Referrer-Policy "same-origin"`. The root file imports `*.caddy` only, so `.extra` files are never loaded as sites of their own.

**`/etc/systemd/system/tracklite@.service`**:

```ini
# managed by shipit
[Unit]
Description=tracklite %i
PartOf=tracklite.target
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=simple
User=tracklite
Group=tracklite
WorkingDirectory=/opt/tracklite/current
Environment=NODE_ENV=production PORT=3001
EnvironmentFile=/etc/tracklite/env
ExecStart=/usr/local/lib/shipit/libexec/run tracklite %i
StandardOutput=append:/var/log/shipit/tracklite/%i.log
StandardError=append:/var/log/shipit/tracklite/%i.error.log
KillSignal=SIGTERM
TimeoutStopSec=30
Restart=always
RestartSec=2
RestartPreventExitStatus=78
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
```

systemd opens the log files as root before it drops to the app user, so the app user never needs write access to `/var/log`.

**`/etc/systemd/system/tracklite.target`**:

```ini
# managed by shipit — Wants= lists the release's processes
[Unit]
Description=tracklite (all processes)
Wants=tracklite@web.service tracklite@worker.service

[Install]
WantedBy=multi-user.target
```

**`shipit-backup@.service` and `shipit-backup@.timer`** (written by `setup`):

```ini
# managed by shipit
[Unit]
Description=Database backup of %i
After=postgresql.service

[Service]
Type=oneshot
User=postgres
Group=postgres
EnvironmentFile=/etc/shipit/host.conf
ExecStart=/usr/local/lib/shipit/libexec/backup %i
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=/var/backups/shipit/%i
```

```ini
# managed by shipit
[Timer]
OnCalendar=*-*-* 03:00:00 UTC
RandomizedDelaySec=45min
FixedRandomDelay=true
Persistent=true

[Install]
WantedBy=timers.target
```

`/var/backups/shipit/<app>/` is `postgres:postgres` with mode 700.

**`/etc/nftables.conf`**:

```
#!/usr/sbin/nft -f
# managed by shipit
flush ruleset
table inet filter {
	chain input {
		type filter hook input priority 0; policy drop;
		ct state established,related accept
		iif lo accept
		meta l4proto { icmp, ipv6-icmp } accept
		tcp dport { 22, 80, 443 } accept
		udp dport 443 accept
	}
	chain forward {
		type filter hook forward priority 0; policy drop;
	}
}
```

`22` is the port `sshd -T` reports.

**`/etc/ssh/sshd_config.d/10-shipit.conf`**:

```
# managed by shipit
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
```

`PermitRootLogin` is `prohibit-password` when `ADMIN_USER` is `root` (the default), and `no` for a named admin.

**`/etc/sudoers.d/shipit-admin`** (mode 440, written only for a named admin):

```
# managed by shipit
ops ALL=(ALL:ALL) NOPASSWD: ALL
```

**`/etc/logrotate.d/shipit`**:

```
# managed by shipit
/var/log/shipit/*/*.log {
	daily
	rotate 14
	compress
	delaycompress
	missingok
	notifempty
	copytruncate
}
```

## 5. Security model

| Account | Logs in | Can | Can't |
|---|---|---|---|
| admin (yours): `root` by default | SSH, key only | Everything. Runs every shipit command, as root or through password-less `sudo`. | Log in with a password |
| root, when a named admin is used | no (after `setup`) | Runs shipit through `sudo` | Log in over SSH |
| `deployer` (shared) | no | Write every app's `/opt/<app>`. Run builds and migrations, with each app's env passed in by root for that build only. | Read any `/etc/<app>/env` at rest, use `sudo`, edit `/etc`, units or the tool, or connect to Postgres as a superuser |
| `<app>` (one per app) | no | Read its own `/opt/<app>` (group `<app>`, mode 750). Connect to its own database. Receive its env vars from systemd. | Read other apps' code, connect to other apps' databases (`revoke connect … from public`), read its env file, write its own code, or write its log files directly (systemd holds them open) |
| `postgres` | no | Run PostgreSQL and the backups. Write `/var/backups/shipit/*`. | — |
| `caddy` | no | Bind 80 and 443, read `/etc/caddy`, write each `access.log` | — |

**Trust boundaries:**

- **Anyone who can push to an app's deployed branch runs code as `deployer`** (npm lifecycle scripts, `BUILD`, `MIGRATE`). `deployer` owns every app's code, so **push access to any app's repo can change every app's code on the next restart** (R1). While a build runs, it also sees that app's secrets.
- Root never runs or sources repo content. It reads process names and `.env.example` keys with `grep`, and `package.json` with `jq`.
- GitHub's SSH host keys are pinned at `setup`, so deploy-key fetches don't trust on first use.

## 6. Moving the Tracklite VPS onto shipit

Requirements: no data loss, and no downtime longer than a normal deploy's restart blip. The database is never touched, apart from an idempotent `revoke connect`. Every step up to step 7 can be undone. The step-by-step version goes in `docs/adopting-a-host.md`.

The cutover is zero-downtime because Tracklite moves from port **3000 to 3001**. The new units start next to the old ones, and a graceful Caddy reload moves traffic over. Running two workers for a moment is safe: the worker claims deliveries with `for update … skip locked` (`src/server/worker.ts:138`), and Resend dedupes by `Idempotency-Key`.

0. **Rehearse first** on a snapshot of the production VPS.
1. **Tracklite PR: add `deploy.conf`** (the example in section 2). Merge it, then **deploy twice with the old `deploy.sh`**. After that, both `current` and `previous` contain `deploy.conf`, so a rollback after the cutover still has commands for the launcher to read.
2. **Backup** the old way (`sudo systemctl start tracklite-backup.service`). Note `readlink /opt/tracklite/current`.
3. **Install the tool.** `install.sh` only writes `/usr/local/lib/shipit` and `/usr/local/bin/shipit`.
4. **`sudo shipit setup`.** Give the existing admin account's name if it isn't `root`. It finds a Caddyfile it didn't write, so it writes `Caddyfile.shipit` and leaves Caddy alone. If `/etc/nftables.conf` isn't shipit's, it's left alone too. The existing `deployer` account keeps its shell and keys. The SSH hardening step runs only if this session logged in with a key.
5. **Mark the existing user and pre-write the app config**, so the first deploy asks nothing:

   ```bash
   sudo usermod -c 'shipit app' tracklite
   ```

   Then write `/etc/shipit/apps/tracklite.conf` with `PORT=3001`, `DATABASE=tracklite` and `LOG_REDACT_QUERY=token`.
6. **Cut over.** Run `sudo shipit deploy tracklite`. It keeps the existing env file (the password is already there), changes it to `root:root` 600, makes `/opt/tracklite` `deployer:tracklite` 750, builds a release, and starts `tracklite.target` on 3001. The old units keep serving on 3000, because Caddy still uses the old Caddyfile.

   Wait until `curl -H 'Host: tracklite.example.com' localhost:3001/health` returns 200. Then switch Caddy:

   ```bash
   sudo mv /etc/caddy/Caddyfile /etc/caddy/Caddyfile.pre-shipit && sudo mv /etc/caddy/Caddyfile.shipit /etc/caddy/Caddyfile
   ```

   ```bash
   sudo caddy validate --config /etc/caddy/Caddyfile && sudo systemctl reload caddy
   ```

   Then stop the old units:

   ```bash
   sudo systemctl disable --now tracklite-web tracklite-worker
   ```

   **To undo:** run `systemctl enable --now tracklite-web tracklite-worker`, restore `Caddyfile.pre-shipit`, reload Caddy, run `systemctl stop tracklite.target`, and set `/etc/tracklite/env` back to `root:deployer` 640.
7. **Check it.** Repeat runbook section 3, then `sudo shipit deploy tracklite` again and `sudo shipit rollback tracklite` (OPS-004.1).
8. **Backups.** `sudo shipit backup tracklite` writes the first local dump. Check the file is there, then discard the R2 set-up: `sudo systemctl disable --now tracklite-backup.timer`. Tracklite follows the tool's design like every other app, so from now on its only backups are shipit's local dumps (R9). The objects already in the R2 bucket, and the bucket itself, are outside the VPS: delete them from the Cloudflare dashboard when you're ready.
9. **Clean up.** Remove the old `tracklite-*` units (web, worker, backup, backup-failed and the timer), `/usr/local/lib/tracklite-backup`, `/etc/tracklite/backup.env`, `/etc/sudoers.d/tracklite-deployer`, the `caddy.service.d/tracklite.conf` drop-in and `journald.conf.d/tracklite.conf`, then run `daemon-reload`.
10. **Tracklite PR: remove** `ops/deploy.sh`, `rollback.sh`, `provision.sh`, `systemd/`, `sudoers/`, `backup/`, `journald/`, `logrotate/` and `Caddyfile`. Keep `deploy.conf`, `ops/env.example` (renamed to `.env.example` at the repo root, so `deploy` can prompt from it), and the Tracklite-specific parts of `monitoring-and-email.md`. Rewrite `runbook.md` around `shipit deploy|rollback|status tracklite`, keeping its OPS-* checks.

Steps 1–7 can ship as soon as redeploys work in shipit (S5). Steps 8–10 wait for backups (S7).

## 7. Testing

- **Static checks in CI:** `bash -n`, `shellcheck` and `shfmt -i 2 -ci -bn -d` on `bin`, `lib`, `libexec`, `install.sh` and `test`.
- **Unit tests with bats-core in CI** (`ubuntu-latest`, with `shellcheck`, `shfmt`, `bats`, `caddy`, `systemd` and `gettext-base` installed). Tests that need GNU tools, `flock` or root skip with a stated reason elsewhere, so CI is the real result. The tests cover:
  - the validators, with good and bad app, process, domain, port, repo, env-value and sourced-file values;
  - app-name derivation from a repo URL, and port allocation;
  - the `deploy.conf` process-name parser and the `.env.example` key parser (both must ignore `$(...)`, comments and indentation tricks);
  - zero-config detection from a fixture `package.json`;
  - the lock helpers;
  - `render()` against golden files, including failing on an unset variable;
  - every rendered site passes `caddy validate`, every rendered unit passes `systemd-analyze verify`, and the rendered admin sudoers file passes `visudo -cf`;
  - the sshd drop-in renders `prohibit-password` for `root` and `no` for a named admin;
  - the dispatcher's root check and its unknown-command message.
- **End-to-end in a throwaway VM.** Use `incus launch images:debian/13 --vm`, which has real systemd, so not Docker. `test/e2e/run.sh` builds the VM, installs the tool and runs the scenarios below, using:
  - local bare repos as `REPO` (`file://` for public repos, and `ssh://git@localhost/…` with a local sshd for the deploy-key flow);
  - `*.localhost` domains, so Caddy issues its own certificates;
  - answers piped to the prompts.

  | Scenario | Asserts |
  |---|---|
  | `setup` runs twice | The second run changes no file (checksums of `/etc` before and after) |
  | `setup` with a foreign Caddyfile or nftables file | Both are left alone, and `Caddyfile.shipit` is written |
  | `setup` from a password session | SSH hardening is skipped, with the reason given |
  | `setup` with the default `root` admin | Root can still log in with a key, and password login is refused for every user |
  | `setup` with a named admin | The admin logs in with a key and runs `sudo -n true`. Root login is refused. |
  | Zero-config Next app, first deploy | One domain answer is enough. It ends `Deployed <sha>`, `current` is that sha, `/` is served through Caddy, and `web.log` has lines in it. |
  | Second app deployed after the first | It gets port 3002. The first app's site file and units are unchanged, and its `MainPID` is the same. |
  | Private repo | Deploy prints a key and waits. When the key is authorized (by the test), it continues without being re-run. |
  | `.env.example` prompts | Missing keys are asked once. A key added in a later release is asked on that deploy. With no terminal, deploy fails and names `shipit env`. |
  | Redeploy is idempotent | A second deploy of the same sha changes no file in `/etc` |
  | Failing migration | Exit 1, the new release is deleted, `current` is unchanged (OPS-002.2) |
  | Rollback | Finishes in under 2 minutes and serves the previous sha (OPS-004.1). A second rollback refuses. |
  | Health answers 308 with `HEALTH_PATH` set | Counted as unhealthy. With `HEALTH_FAIL=rollback`, it switches back. |
  | Deploy one app twice at once | The second exits with the lock message |
  | Deploy two apps at once | Builds run one after the other (timestamps from the build lock), and both succeed |
  | Process added, then rolled back past | The new instance runs after deploy. After rollback it's stopped and not restarted. |
  | Isolation | The `a` user can't read `/opt/b` or connect to b's database, and `deployer` can't read `/etc/a/env` |
  | Backup and restore | A backup file appears with the right name. Restore brings back matching row counts. Only `BACKUP_KEEP` files are kept. |
- **Real host:** step 0 of the migration, a rehearsal on a snapshot.

## 8. Milestones

Each one is small enough to review and merge on its own, and each ends with CI green and the listed e2e scenarios passing.

| # | Milestone | Done when |
|---|---|---|
| S0 | Repo skeleton: `install.sh`, the `bin/shipit` dispatcher (every command name, root check, "not implemented yet" stubs), `common.sh` (log, die, validators, `render`, locks), `examples/`, CI, README, CLAUDE.md | The validator, render, lock and dispatcher unit tests pass in CI |
| S1 | `setup` | Works on a fresh VM, a re-run is a no-op, foreign Caddyfile and nftables files are left alone, and hardening is skipped from a password session |
| S2 | First deploy of a public, zero-config Next app with no database: the questions, name and port, user, folders, units, launcher, site, logs, build, switch and health | The zero-config and second-app scenarios pass, and golden files match |
| S3 | Private repos (deploy key and wait), `deploy.conf` (commands, several processes, `HEALTH_PATH`), and `.env.example` prompts | The private-repo and prompt scenarios pass |
| S4 | Database: detection, creation, `revoke connect`, and the migrate step | The isolation and failing-migration scenarios pass |
| S5 | Redeploy and `rollback`: idempotent re-runs, config changes applied, locks, `--ref`, `HEALTH_FAIL`, adding and removing processes | The redeploy, rollback, 308, lock and process scenarios pass |
| **S5.5** | **Move Tracklite deploys onto shipit (section 6, steps 0–7)**, done by hand | Production runs on `tracklite.target`, and runbook section 3 passes |
| S6 | `status`, `logs` and `env` | Show both fixture apps correctly, including a failed instance |
| S7 | Backups: `libexec/backup`, the timer, `backup` and `restore` | The backup-and-restore scenario passes |
| **S7.5** | **Tracklite backups and clean-up (steps 8–10)**, done by hand | The old units are gone, and the Tracklite `ops/` PR is merged |
| Later | `deploy --artifact` (CI builds) · per-app Node via mise · `app-remove` · per-app build users (R1) · zero-downtime deploys (R6) · off-site backups · DNS records through the Hostinger API | — |

## 9. Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | **The shared `deployer` turns push access to any one repo into control of every app's code.** | Accepted for now. Env files are no longer readable by `deployer` at rest, which narrows it. The deploy user's name is one variable, so per-app build users later are a small change. |
| R2 | **Memory.** One `next build` takes 1–2 GB. On a KVM 1 (4 GB of RAM plus 4 GB of swap), a build can push running apps into swap. | The build lock allows one build at a time. Size by measurement. As a rough guide, a KVM 1 holds 2–4 small apps, a KVM 2 holds 5–8, and a KVM 4 holds more. CI-artifact builds remove the problem. |
| R3 | **One Node version** for every app. | `NODE_MAJOR` is fixed in `host.conf`. An upgrade is a deliberate edit followed by redeploying every app. Per-app Node comes later. |
| R4 | **Shared PostgreSQL.** One app's heavy query slows the others. | Acceptable at this scale. Roles and `revoke connect` keep the data apart. |
| R5 | **The rollback rule can't be enforced by the tool.** Migrations must work with the previous release's code. | `HEALTH_FAIL` defaults to `report`. The runbook keeps today's expand/contract checklist. |
| R6 | **Deploys drop requests for a few seconds** while `restart` runs, the same as today. | Zero downtime would need two ports per app and a Caddy reload. That's a later milestone. |
| R7 | **Disk.** Every release has its own `node_modules`, and logs and backups grow too. | `MIN_FREE_DISK_GB` stops a deploy before it builds. Logrotate and `BACKUP_KEEP` cap the rest. |
| R8 | **A broken Caddy config** on disk blocks every app's site changes, and takes every site down on the next restart. | Validate before every write, only ever reload, and `status` runs `caddy validate`. |
| R9 | **Backups are on the same disk as the database.** Losing the VPS loses the backups too. | That's your scope decision. Hostinger's own VPS snapshots or backups are the off-site copy until an "off-site backups" milestone. `shipit status` says where the backups are. |
| R10 | **SSH lockout** from hardening or the firewall. | Hardening needs a key login in the current session and an admin with keys. Root keeps key login when it's the admin. The firewall reads the SSH port from `sshd -T`. Both leave the current session open, and Hostinger's browser terminal is the way back in. |
| R11 | **The zero-config health check is lenient.** A page that answers 4xx on `/` counts as healthy. | Apps that want a strict check set `HEALTH_PATH` in `deploy.conf`. |
| R12 | **Next.js writes `.next/cache` at runtime** (for example the image optimiser), but the release is read-only to the app user. | The same as Tracklite today. Add a per-app writable `CacheDirectory=` later if an app needs it. |

## 10. Decisions on open questions

None. Settled:

- **O1:** a named admin's `sudo` needs no password (`NOPASSWD`).
- **O2:** logs are per process: `<process>.log` and `<process>.error.log`, plus `access.log` and `deploy.log`.
- **O3:** `deploy` doesn't take a backup before migrating. Run `shipit backup` by hand, as the runbook says.
- **O4:** Tracklite's R2 backups are discarded. shipit is a general tool, and every app, Tracklite included, follows its design with no per-app exceptions.
- **O5:** zero config supports npm only. pnpm and yarn need a `deploy.conf`.
- **O6:** the default admin is `root`, so `setup` creates no user unless you name one.
