# shipit

> **Status:** shipit 1.0.0 is being rebuilt from [docs/plan.md](docs/plan.md) (the spec), one
> milestone at a time; M0 (skeleton), M1 (`shipit.ini` parser), M2 (`shipit setup`), M3
> (`shipit deploy` for static sites), M4 (Node and Next.js deploys), M5 (`shipit rollback`) and M6
> (deploys and rollbacks from GitHub Actions: `setup --ci-key`, the `ci` user) are done.

## 1. What it is

A small bash tool that turns a Debian or Ubuntu VPS into a host for several websites, and deploys each
one from its GitHub repo. It does three things:

- `shipit setup`: install Caddy, Node.js LTS and the tools below, and harden SSH and the firewall.
- `shipit deploy`: build a site from GitHub on the VPS and switch to it atomically.
- `shipit rollback`: go back one version.

No prompts, so every command works over SSH from a laptop or from GitHub Actions.

## 2. How to use it

```bash
# once per VPS (log in with an SSH key, so setup can turn off password logins)
ssh root@vps 'curl -fsSL https://github.com/<you>/shipit/archive/refs/tags/v1.0.0.tar.gz | tar -xz && cd shipit-1.0.0 && ./install.sh'
ssh root@vps shipit setup

# first deploy of a site, by hand
ssh root@vps shipit deploy https://github.com/<you>/blog blog

# later: by hand, or from CI (section "Deploying from GitHub Actions")
ssh root@vps shipit deploy blog [ref]
ssh root@vps shipit rollback blog
```

`shipit setup` is safe to re-run; a re-run changes no file that's already right. It checks the OS
(Debian 13+ or Ubuntu 26.04+), adds the Caddy and NodeSource apt repos and installs the packages
below (the Node.js LTS major is looked up once and kept in `/etc/shipit/host.conf`), installs a
pinned corepack, creates shipit's folders, writes `/etc/caddy/Caddyfile`, turns on ufw (SSH ports
from `sshd -T`, 80, 443/tcp, 443/udp), fail2ban and unattended-upgrades, and turns off SSH password
logins, but only if root has a key in `authorized_keys` and you logged in with it. Its last lines are
the VPS host keys: replace `<host>` and save them as the GitHub secret `VPS_KNOWN_HOSTS`. It also
creates the `ci` user (and its one sudoers rule) that GitHub Actions logs in as; `--ci-key` adds a
site's CI key (below).

Each repo has a `shipit.ini` at its root. A static site:

```ini
[site]
name = docs                ; must match the name you deploy it as
domain = docs.example.com
alias = www.docs.example.com   ; optional, repeatable: redirected (308) to domain
type = static              ; static | node | nextjs
env = PUBLIC_API_URL       ; optional, repeatable: must exist in the site's env file

[static]
root = dist                ; the folder Caddy serves, after the build

[node]                     ; optional: the defaults are picked from the repo
install = npm ci           ; default by lockfile: npm ci, pnpm install --frozen-lockfile, yarn install --immutable
build = npm run build      ; default: npm run build if package.json has a build script
```

A Node site (`start` is required and must listen on `$PORT`) or a Next.js site (every command has a
default; `start` defaults to `./node_modules/.bin/next start -p $PORT`):

```ini
[site]
name = api
domain = api.example.com
type = node                ; or nextjs
health = /healthz          ; optional: checked after each restart; set, it must answer exactly 200
env = DATABASE_URL         ; optional, repeatable

[node]
start = node server.js     ; nextjs: optional

[data]                     ; optional: persistent folders, /var/lib/shipit-api/uploads and .../db
dir = uploads
dir = db
```

Deploying a site:

```bash
# first deploy: the repo URL and the site's name
ssh root@vps shipit deploy https://github.com/me/docs docs
# later: by name, optionally with a branch, tag or full commit SHA (default: the repo's default branch)
ssh root@vps shipit deploy docs
ssh root@vps shipit deploy docs v1.2.0
```

- **Private repos.** If the repo can't be fetched anonymously over HTTPS, the first deploy creates a
  deploy key for the site, prints it and stops: add it at
  `https://github.com/<owner>/<repo>/settings/keys/new` (read-only), then run the same command
  again. GitHub's host keys ship with shipit, so the connection is checked strictly.
- **Secrets.** Put them in `/etc/shipit/sites/<name>.env` (`root:root`, mode 600): `KEY=value`
  lines, blank lines and `#` comments; a value may be wrapped in one pair of quotes, and nothing else
  is expanded. Only the build step gets them (on stdin), never the install step. A deploy fails,
  naming them, if keys listed as `site.env` are missing.
- **What a deploy does.** As the site's build user it fetches the repo, checks `shipit.ini`
  (name, type, and that no other site uses the domain or aliases), builds a new
  `releases/<UTC time>-<sha>/` folder, refuses it if `static.root` is missing or links outside
  itself, switches `current` to it (the old one becomes `previous`), writes the site's Caddy file
  and reloads Caddy if it changed, and deletes older releases. A failed build changes nothing; a
  Caddy file that doesn't validate switches back.
- **Node and Next.js sites.** The first deploy gives the site a port from 3000–3999 (kept in
  `/etc/shipit/sites/<name>.conf`). Each deploy writes the unit
  `/etc/systemd/system/shipit-<name>.service` (run as the user `<name>`, hardened, enabled at boot)
  and a Caddy file proxying to the port, restarts the site, and polls
  `http://127.0.0.1:<port><health>` with the site's `Host` header for up to 60 s (any status below
  500, or exactly 200 when `site.health` is set). If the site doesn't come up, the deploy switches
  back to the previous release, restarts it and fails: "Deploy failed health check; still serving
  <release>." A failed first deploy removes the unit, `current`, the Caddy file and the release, and
  keeps the users and the port, so you can fix it and run the same command again. Next.js's runtime
  cache lives in `/var/cache/shipit-<name>` (`.next/cache` links to it) and is emptied on every
  deploy.
- **The env file at runtime.** A Node/Next.js process gets the env file through systemd
  (`EnvironmentFile=`, read as root), plus `NODE_ENV=production` and `PORT`. A site without an env
  file starts without one. After editing the file, redeploy (or `systemctl restart shipit-<name>`).
- **Data folders.** With `[data]`, systemd creates `/var/lib/shipit-<name>/` and one subfolder per
  `dir` (owned by `<name>`, mode 700), the only place the process can write. `$STATE_DIRECTORY`
  lists them joined by `:` (`/var/lib/shipit-api:/var/lib/shipit-api/uploads:...`), so use the
  fixed path `/var/lib/shipit-<name>/<dir>` or the first entry. Deploys never touch it, and it isn't
  backed up.
- **Logs.** `journalctl -u shipit-<name>` (app output), `tail -f /var/log/shipit/<name>/access.log |
  jq` (requests), `journalctl -u caddy` (TLS and proxy errors).

Rolling back a site:

```bash
ssh root@vps shipit rollback docs
```

- **What it does.** Swaps `current` and `previous`, then writes the Caddy file and unit from the
  `shipit.ini` of the release that's now live (so a changed `static.root`, alias or `data.dir` goes
  back too), checking its domains against the other sites as they are now. Node/Next.js sites are
  restarted (Next.js's cache emptied) and health-checked as on a deploy. It prints "Rolled back
  <name>: now serving <release>."
- **One step.** It goes back exactly one release; running it again returns to where you started.
  Both releases are kept; the next deploy drops whichever one is then `previous`. A site with only
  one release has nothing to roll back to, and rollback says so.
- **Code and config, not data.** `/var/lib/shipit-<name>` and the env file are untouched, so schema
  changes must work with the previous release.
- **If it fails** (the older release's config is refused, or it doesn't pass the health check), it
  swaps back, restores the config, restarts the release that was live, and exits non-zero: "Rollback
  failed health check; still serving <release>."
- It waits for a deploy or rollback of the same site that's already running. It still works after a
  force-push and `git gc`: each release's commit is pinned in the site's `repo.git`.

Deploying from GitHub Actions:

1. Deploy the site once by hand (above). CI only redeploys and rolls back sites that have been
   deployed successfully.
2. Make a key pair for the site, on your laptop, without a passphrase:
   `ssh-keygen -t ed25519 -N '' -C 'shipit ci blog' -f ~/.ssh/shipit_blog_ci`.
3. Give the public half to the VPS (re-run setup for each site; other sites' keys are kept):
   `ssh root@vps 'shipit setup --ci-key blog -' < ~/.ssh/shipit_blog_ci.pub`. The file must be the
   one line `ssh-keygen` wrote (ed25519, ECDSA, security-key or RSA), without options. Several sites
   at once: `shipit setup --ci-key blog blog.pub --ci-key api api.pub`.
4. Add the repo's secrets (Settings, Secrets and variables, Actions): `SHIPIT_KEY` (the private key,
   `~/.ssh/shipit_blog_ci`), `VPS_KNOWN_HOSTS` (the lines setup printed, with `<host>` replaced),
   `VPS_HOST` (the address CI connects to) and, if SSH isn't on 22, `VPS_PORT`.
5. Copy [examples/deploy.yml](examples/deploy.yml) (deploys every push to `main`) and
   [examples/rollback.yml](examples/rollback.yml) (run by hand from the Actions tab) to the repo's
   `.github/workflows/`, replacing `blog` with the site's name.

- **What the key can do.** It logs in as `ci` and can only run `deploy <name> [<commit sha or
  branch>]` or `rollback <name>` for its own site: the line in `/home/ci/.ssh/authorized_keys` forces
  `sudo shipit remote <name>`, which checks the command strictly and refuses everything else
  (another site, options, shell syntax, an interactive login).
- **Output and exit status.** The build streams to the Actions log, and the step fails when the
  deploy or rollback does.
- **A new key for a site** replaces its old one: run step 3 again. To revoke a key, delete its line
  (ending in `shipit:<name>`) from `/home/ci/.ssh/authorized_keys`.

Secrets live only on the server. Every `shipit.ini` key is in [docs/plan.md](docs/plan.md)
(section 3); why the workflows look as they do is in section 5.4.

## 3. Philosophy

- **Atomic switches.** Each deploy builds into a new `releases/<time>-<sha>/` folder. Going live is one
  `rename()` of the `current` symlink, so visitors see either the old release or the new one, never a
  half-built mix.
- **One step back.** A site keeps exactly two releases, `current` and `previous`. Rollback swaps the
  two symlinks.
- **Config follows the code.** The Caddy file and systemd unit are rendered from the `shipit.ini` of
  the release that's live, so rolling back code also rolls back its config.
- **Fail safe.** A failed build changes nothing; a failed health check switches back.
- **Boring tools.** bash, git, systemd and Caddy. No Docker, no agent, no database.

## 4. Directories

```
/etc/shipit/host.conf               Node major, fixed at setup
/etc/shipit/sites/<name>.conf       repo, type, domains, port
/etc/shipit/sites/<name>.env        secrets (root only)
/etc/caddy/sites/<name>.caddy       the site's Caddy config
/etc/systemd/system/shipit-<name>.service   the site's unit (Node/Next.js)
/srv/<name>/
  repo.git/                         bare clone
  releases/<time>-<sha>/            at most two
  current  -> releases/...
  previous -> releases/...
/var/lib/shipit-<name>/             persistent data (opt-in, survives deploys)
/var/cache/shipit-<name>/           Next.js runtime cache, emptied on every deploy
/var/log/shipit/<name>/access.log   Caddy access log
```

App output is in `journalctl -u shipit-<name>`.

## 5. Permissions

- **Root** runs shipit, and never runs repo code.
- **`<name>-build`** runs repo commands (fetch, install, build). It can write only the release being
  built; root takes each release back when its build finishes.
- **`<name>`** runs the Node/Next.js process. It can read the release and write only its data folder.
- **`caddy`** can read a static site's served folder only (through ACLs).
- **`ci`** can only run `deploy` or `rollback`, and each SSH key only for its own site.

Neither site user can read the env file: systemd reads it as root and passes it to the process.

## 6. Platforms and tech

| | |
|---|---|
| OS | Debian 13+, Ubuntu 26.04+ |
| Web server | Caddy, automatic HTTPS |
| Runtime | Node.js LTS (npm, pnpm and yarn through corepack) |
| Site types | `static`, `node`, `nextjs` |
| Source | GitHub, public or private (per-site deploy key) |
| Processes | systemd, one unit per site |
| Also installed | git, jq, curl, ufw, fail2ban, unattended-upgrades, acl, sudo |

## 7. Limitations

- Builds run on the VPS, one at a time, so a large build is slow on a small plan.
- One Node version for every site, fixed when `setup` first runs.
- Rollback goes back one release only, and never touches data: schema changes must work with the
  previous release.
- A Node/Next.js deploy restarts the process (a 1–3 s gap). No blue/green.
- No backups, no command to remove a site, and a site's name and type can't change after its first
  deploy.
- A private npm registry that needs a token at install time isn't supported.

## 8. Security notes

- **Anyone who can push to a site's deployed branch runs code on the VPS** as `<name>-build`, and the
  build step sees that site's secrets. Deploy only repos you trust.
- Sites are isolated from each other: separate users, code, data, ports and CI keys.
- Install scripts of dependencies never see secrets; only the build step gets them.
- `setup` turns off SSH password logins (only if you logged in with a key) and enables a firewall.
- CI pins the VPS host key; shipit pins GitHub's.
- Every `shipit.ini` value is checked against a strict pattern, and every config is validated on a
  temp copy before it's installed.
