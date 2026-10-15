# shipit

> **Status:** shipit 1.0.0 is being rebuilt from [docs/plan.md](docs/plan.md) (the spec), one
> milestone at a time; M0 (skeleton) and M1 (`shipit.ini` parser) are done, the commands aren't
> implemented yet.

## 1. What it is

A small bash tool that turns a Debian or Ubuntu VPS into a host for several websites, and deploys each
one from its GitHub repo. It does three things:

- `shipit setup`: install Caddy, Node.js LTS and the tools below, and harden SSH and the firewall.
- `shipit deploy`: build a site from GitHub on the VPS and switch to it atomically.
- `shipit rollback`: go back one version.

No prompts, so every command works over SSH from a laptop or from GitHub Actions.

## 2. How to use it

```bash
# once per VPS
ssh root@vps 'curl -fsSL https://github.com/<you>/shipit/archive/refs/tags/v1.0.0.tar.gz | tar -xz && cd shipit-1.0.0 && ./install.sh'
ssh root@vps 'shipit setup --ci-key blog -' < ~/.ssh/shipit_blog_ci.pub

# first deploy of a site, by hand
ssh root@vps shipit deploy https://github.com/<you>/blog blog

# later: from CI (ci@vps), or by hand
ssh root@vps shipit deploy blog [ref]
ssh root@vps shipit rollback blog
```

Each repo has a `shipit.ini` at its root:

```ini
[site]
name = blog
domain = blog.example.com
type = nextjs        ; static | node | nextjs
env = DATABASE_URL   ; must exist in the site's env file on the server
```

Secrets live only on the server, in `/etc/shipit/sites/<name>.env`. The GitHub Actions workflow and
every `shipit.ini` key are in [docs/plan.md](docs/plan.md) (sections 3 and 5.4).

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
