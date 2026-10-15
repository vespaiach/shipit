# shipit

> **Status:** shipit 1.0.0 is being rebuilt from [docs/plan.md](docs/plan.md) (the spec), one
> milestone at a time; M0 (skeleton), M1 (`shipit.ini` parser), M2 (`shipit setup`) and M3
> (`shipit deploy` for static sites) are done. Node and Next.js deploys (M4), `rollback` (M5) and
> `setup --ci-key` (M6) aren't implemented yet.

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

# later: from CI (ci@vps), or by hand
ssh root@vps shipit deploy blog [ref]
ssh root@vps shipit rollback blog
```

`shipit setup` is safe to re-run; a re-run changes no file that's already right. It checks the OS
(Debian 13+ or Ubuntu 26.04+), adds the Caddy and NodeSource apt repos and installs the packages
below (the Node.js LTS major is looked up once and kept in `/etc/shipit/host.conf`), installs a
pinned corepack, creates shipit's folders, writes `/etc/caddy/Caddyfile`, turns on ufw (SSH ports
from `sshd -T`, 80, 443/tcp, 443/udp), fail2ban and unattended-upgrades, and turns off SSH password
logins, but only if root has a key in `authorized_keys` and you logged in with it. Its last lines are
the VPS host keys: replace `<host>` and save them as the GitHub secret `VPS_KNOWN_HOSTS`. Setting up
the `ci` user's keys (`shipit setup --ci-key <name> <key file>`) comes with CI support.

Each repo has a `shipit.ini` at its root. A static site (for now the only type `deploy` takes):

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

Secrets live only on the server. The GitHub Actions workflow and every `shipit.ini` key are in
[docs/plan.md](docs/plan.md) (sections 3 and 5.4).

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
/srv/<name>/
  repo.git/                         bare clone
  releases/<time>-<sha>/            at most two
  current  -> releases/...
  previous -> releases/...
/var/lib/shipit-<name>/             persistent data (opt-in, survives deploys)
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
| Also installed | git, jq, curl, ufw, fail2ban, unattended-upgrades, acl |

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
