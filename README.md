# shipit

A small bash tool that turns one Debian or Ubuntu VPS into a host for several websites, and deploys
each of them from its GitHub repo:

- `shipit setup` installs Caddy, Node.js LTS and a few tools, and hardens SSH and the firewall.
- `shipit deploy` builds a site from GitHub on the VPS and switches to it atomically.
- `shipit rollback` goes back one release.

Sites can be `static` (Caddy serves a folder), `node` (any server listening on `$PORT`) or `nextjs`.
Caddy is the web server for all of them and gets their TLS certificates automatically. No command
asks a question, so each one works over SSH from a laptop.

[docs/plan.md](docs/plan.md) is the full spec, with the reasons behind each choice. This README is the
manual.

## Contents

1. [Requirements](#requirements)
2. [Install and set up the VPS](#install-and-set-up-the-vps)
3. [shipit.ini](#shipitini)
4. [Deploying](#deploying)
5. [Secrets](#secrets)
6. [Node and Next.js sites](#node-and-nextjs-sites)
7. [Rolling back](#rolling-back)
8. [Logs](#logs)
9. [Server layout and security](#server-layout-and-security)
10. [Removing a site](#removing-a-site)
11. [Limitations](#limitations)
13. [Development](#development)

## Requirements

- A VPS running **Debian 13 or later, or Ubuntu 26.04 or later**. Anything else is refused.
- **Root** (every command but `shipit help` refuses to run otherwise; `sudo shipit ...` works).
- An **SSH key login as root**. Setup turns off password logins only if root has a key in
  `/root/.ssh/authorized_keys` and you logged in with it; otherwise it skips that step and says why.
- Each site's domain (and aliases) pointing at the VPS, and ports 80 and 443 reachable, so Caddy can
  get certificates.

## Install and set up the VPS

```bash
ssh root@vps 'curl -fsSL https://github.com/<you>/shipit/archive/refs/tags/v1.0.0.tar.gz | tar -xz && cd shipit-1.0.0 && ./install.sh'
ssh root@vps shipit setup
```

`install.sh` copies `bin/`, `lib/` and `templates/` to `/usr/local/lib/shipit` and links
`/usr/local/bin/shipit`. Re-running it replaces the installed copy.

`shipit setup` is safe to re-run: a re-run changes no file that's already right. It:

- checks the OS;
- adds the Caddy and NodeSource apt repos and installs `caddy`, `nodejs`, `git`, `jq`, `curl`,
  `gettext-base`, `acl`, `ufw`, `fail2ban`, `unattended-upgrades`, `sudo`, `ca-certificates` and
  `gnupg`, plus a pinned `corepack` (for pnpm and yarn). The Node.js LTS major is looked up on the
  first run and kept in `/etc/shipit/host.conf`; later runs never change it;
- creates `/etc/shipit/sites`, `/etc/caddy/sites`, `/var/lib/shipit`, `/srv` and `/var/log/shipit`;
- writes `/etc/caddy/Caddyfile` (which imports `/etc/caddy/sites/*.caddy`) and reloads Caddy;
- turns on ufw (the ports sshd listens on, 80/tcp, 443/tcp, 443/udp; everything else incoming is
  denied), fail2ban's `sshd` jail and unattended-upgrades;
- turns off SSH password logins (`/etc/ssh/sshd_config.d/10-shipit.conf`), only when that can't lock
  you out (see [Requirements](#requirements)).

Setup only overwrites files it wrote itself (marked `# managed by shipit`), and Caddy's untouched
default Caddyfile. A file you wrote or changed by hand stops it, with a message saying to move the
file away (an apt source file is left alone instead).

## shipit.ini

Each repo has a `shipit.ini` at its root, in git's config syntax. A full example:

```ini
# deployed as: shipit deploy https://github.com/<owner>/<repo> blog
[site]
domain = blog.example.com
alias = www.blog.example.com
type = nextjs
health = /api/health
env = DATABASE_URL
env = NEXT_PUBLIC_API

[node]
install = pnpm install --frozen-lockfile
build = pnpm build
start = pnpm start

[data]
dir = uploads
dir = db
```

A minimal one per type:

```ini
# static: build with the defaults, serve dist/ (deployed as: shipit deploy <url> docs)
[site]
domain = docs.example.com
type = static

[static]
root = dist
```

```ini
# node: start is required (deployed as: shipit deploy <url> api)
[site]
domain = api.example.com
type = node

[node]
start = node server.js

[data]
dir = uploads
```

```ini
# nextjs: every command has a default (deployed as: shipit deploy <url> blog)
[site]
domain = blog.example.com
type = nextjs
```

| Key | Required | Meaning |
|---|---|---|
| `site.domain` | yes | The site's hostname, lowercase. No other site may use it. |
| `site.alias` | no, repeatable | Another hostname, redirected (308) to `site.domain`. |
| `site.type` | yes | `static`, `node` or `nextjs`. Can't change after the first deploy. |
| `site.health` | no | `node`/`nextjs` only. The path checked after a restart. Default `/`, which passes with any status below 500; set, it must answer exactly 200. Letters, digits and `. _ ~ / -`, starting with `/`. |
| `site.env` | no, repeatable | A key that must be in the site's env file ([Secrets](#secrets)); the deploy fails, naming the missing ones. |
| `node.install` | no | Install command. Default, by lockfile: `npm ci` (`package-lock.json`), `pnpm install --frozen-lockfile` (`pnpm-lock.yaml`), `yarn install --immutable` (`yarn.lock`), `npm install` (only `package.json`), else none. Runs without secrets. |
| `node.build` | no | Build command. Default: `npm run build` if `package.json` has a `build` script, else none. Gets the secrets. |
| `node.start` | `node`: yes | `node`/`nextjs` only. Starts the server, which must listen on `$PORT`. `nextjs` default: `./node_modules/.bin/next start -p $PORT`. Can't contain `'`, `%`, `\` or control characters (it goes into the systemd unit). |
| `static.root` | `static`: yes | `static` only. The folder, inside the release, that Caddy serves (`dist`, `build/out`). No `.` or `..` parts. |
| `data.dir` | no, repeatable | `node`/`nextjs` only. A persistent data folder ([Data folders](#data-folders)): lowercase letters, digits, `_` and `-`, no `/`. |

Rules and quirks:

- Unknown sections or keys, a key that doesn't fit the type (`static.root` on a node site,
  `node.start` on a static one), a single-value key given twice, a repeated value, an empty value, or
  a control character all fail the deploy before anything is built. A syntax error names its line.
- A `static` site may still have `node.install` and `node.build` (Vite, `next export`).
- `#` and `;` start a comment **even in the middle of a value**, so quote a value that contains
  them: `start = "node server.js --tag=#1"`.
- Section and key names are case-insensitive, but write them in lowercase.
- `[include]` is refused (as an unknown key) and the included file is never read.

## Deploying

The first deploy of a site names the repo (only `https://github.com/<owner>/<repo>`, optionally with
`.git`) and the site:

```bash
ssh root@vps shipit deploy https://github.com/me/docs docs
```

Later deploys use the name, optionally with a branch, a tag or a full 40-character commit SHA (the
default is the repo's default branch):

```bash
ssh root@vps shipit deploy docs
ssh root@vps shipit deploy docs v1.2.0
```

The URL form still works for a known site, if it names the same repo.

**Private repos.** If the repo can't be fetched anonymously over HTTPS, the first deploy creates a
deploy key for the site, prints it, and stops with:

> Can't fetch https://github.com/me/docs. If it's a private repo, add this key as a read-only deploy
> key at https://github.com/me/docs/settings/keys/new, then run the same command again.

Add it there (read-only), then run the same command again. GitHub's host keys ship with shipit, so
the connection is checked strictly. A repo that's public on its first deploy keeps using HTTPS; if
it turns private later, create the key by hand and add its `.pub` to GitHub:
`runuser -u <name>-build -- ssh-keygen -t ed25519 -N '' -C shipit-<name> -f /srv/<name>/.ssh/id_ed25519`.

**What a deploy does.**

1. Takes the site's lock (a second deploy or rollback of the same site waits: "Another deploy or
   rollback of docs is running; waiting.").
2. On a first deploy, creates the users `<name>` and `<name>-build`, `/srv/<name>/` and
   `/etc/shipit/sites/<name>.conf`.
3. As `<name>-build`, fetches the repo's branches and tags, resolves the ref, and checks
   `shipit.ini` at that commit: its type must match the site's, its domain and aliases must
   not be used by another site, the env file must parse and hold every `site.env` key.
4. Builds, one site at a time on the VPS ("Another site is building; waiting."): a new folder
   `releases/<UTC time>-<sha>/` gets the commit's files, then the install and build commands run in
   it as `<name>-build`. For a static site, `static.root` must exist and contain no symlink pointing
   outside it.
5. Switches: `previous` points at the old release and `current` at the new one, each in one atomic
   rename. The Caddy file (and for node/nextjs the systemd unit) is rendered from the new release's
   `shipit.ini`, validated, installed, and Caddy is reloaded if it changed (never restarted).
   Node/Next.js sites are restarted and health-checked ([below](#node-and-nextjs-sites)).
6. Deletes every release except `current` and `previous`, and prints "Deployed docs: now serving
   <release>."

A failed fetch, check or build changes nothing that's live. A config that doesn't validate, or a
failed health check, switches back ("Deploy failed health check; still serving <release>.", or
"Deploy failed: the new release's config couldn't be installed; still serving <release>."). A failed
first deploy removes what it installed and prints "First deploy of docs failed; nothing is served.";
it keeps the users and the port, so fix the problem and run the same command again.

A site's name is the one you gave on its first deploy (`shipit deploy <repo-url> <name>`); `shipit.ini` doesn't hold it. The name and the type can't change after that. To rename it or change its type, remove
it ([Removing a site](#removing-a-site)) and deploy it again.

## Secrets

Secrets never go in the repo. Put them on the VPS in `/etc/shipit/sites/<name>.env`, owned by root
with mode 600:

```bash
ssh root@vps 'touch /etc/shipit/sites/blog.env && chmod 600 /etc/shipit/sites/blog.env'
ssh root@vps 'nano /etc/shipit/sites/blog.env'
```

The format is the part of systemd's `EnvironmentFile=` syntax that shipit and systemd read the same
way:

```sh
# comments start with # or ;
DATABASE_URL=postgres://app@localhost/app
GREETING="hello world"
```

- One `KEY=value` per line, the key at the start of the line (letters, digits and `_`, not starting
  with a digit), no spaces before the `=`. Blank lines and lines starting with `#` or `;` are skipped.
- The value is literal: spaces and tabs around it are removed, then one pair of matching `"` or `'`
  around the whole value. No escapes, no `export`, no line continuations.
- Any other line fails the deploy, naming the line, before anything is built.

Who gets them:

- The **build** step gets them as environment variables (passed on stdin, never on a command line),
  so a static site can bake public values in at build time.
- The **install** step never does, so dependencies' install scripts don't see them. (A private npm
  registry that needs a token at install time isn't supported.)
- A **node/nextjs process** gets them from systemd (read as root; neither site user can read the
  file), plus `NODE_ENV=production` and `PORT`. A site without an env file starts without one.

List the keys a site needs as `site.env` in `shipit.ini`: a deploy then fails before building if any
are missing. After editing the file, deploy again (or, if only the running process needs the change,
`systemctl restart shipit-<name>`).

## Node and Next.js sites

**Process.** The first deploy gives the site a port from 3000–3999 (kept in its `.conf`). Each
deploy writes the unit `/etc/systemd/system/shipit-<name>.service`, which runs `node.start` as the
user `<name>` in `/srv/<name>/current`, hardened (read-only system, private `/tmp`, no new
privileges, may bind only its own port), restarted on failure and enabled at boot. Caddy proxies the
domain to `127.0.0.1:<port>`. A deploy restarts the process, so expect a gap of 1–3 s.

**Health check and auto-revert.** After the restart, shipit polls
`http://127.0.0.1:<port><site.health>` with the site's `Host` header, every second for up to 60 s.
Without `site.health`, any status below 500 passes (redirects aren't followed, so `/` redirecting to
a login page is fine); with it, only exactly 200 does. If the site doesn't pass, the deploy switches
back to the previous release, restarts and checks it, deletes the failed release and exits non-zero.

### Data folders

A process can write only to its data folder. Opt in with `[data]` and at least one `dir`:

```ini
[data]
dir = uploads
dir = db
```

systemd then creates `/var/lib/shipit-<name>/` and `/var/lib/shipit-<name>/<dir>` for each `dir`,
owned by `<name>`, mode 700. It sets `$STATE_DIRECTORY` to all of them **joined by `:`**, root first
(`/var/lib/shipit-api:/var/lib/shipit-api/uploads:/var/lib/shipit-api/db`), so use the fixed path
`/var/lib/shipit-<name>/<dir>`, or the first entry. An empty `[data]` creates nothing, so a site that
keeps one SQLite file still names a folder (`dir = db`).

Deploys and rollbacks never touch it, the build can't read it, and shipit doesn't back it up: that's
your job.

### Next.js cache

For `nextjs` sites, the release's `.next/cache` is a link to `/var/cache/shipit-<name>`, so
`next start` can write its image and ISR cache. It's emptied on every deploy and rollback, so a
release never serves pages cached by another.

## Rolling back

```bash
ssh root@vps shipit rollback docs
```

- **One step.** It swaps `current` and `previous`; running it again returns to where you started.
  Nothing is deleted; the next deploy drops whichever release is then `previous`. A site with one
  release says "docs has no previous release to roll back to."
- **Code and config.** The Caddy file and unit are rendered from the `shipit.ini` of the release
  that's now live, so a changed `static.root`, alias, `node.start` or `data.dir` goes back too. Its
  domains are checked against the other sites as they are now. Node/Next.js sites are restarted and
  health-checked as on a deploy.
- **Not data.** `/var/lib/shipit-<name>` and the env file are untouched. **Schema changes (e.g.
  SQLite migrations) must keep working with the previous release for one version.**
- Success prints "Rolled back docs: now serving <release>." On failure it swaps back, restores the
  config, restarts the release that was live and exits non-zero ("Rollback failed health check;
  still serving <release>.").

Each release's commit is pinned in the site's `repo.git`, so rollback works after a force-push and
`git gc`.

## Logs

```bash
tail -f /var/log/shipit/<name>/access.log | jq   # requests: Caddy's JSON, one per line
journalctl -u shipit-<name>                      # a node/nextjs site's output
journalctl -u caddy                              # TLS, proxy errors, reloads
```

Access logs are rolled by Caddy (10 MiB, 10 files) and readable only by root and `caddy`. Query
strings are cut from the logged URI, `Referer` and `Location`, since they can carry tokens. Build
output goes to the SSH session (and so the Actions log) and isn't kept on the VPS.

## Server layout and security

```
/etc/shipit/host.conf                       Node.js major, fixed by the first setup
/etc/shipit/sites/<name>.conf               repo, type, domains, port (written by shipit)
/etc/shipit/sites/<name>.env                secrets (root only, 600)
/etc/caddy/Caddyfile                        global options, imports sites/*.caddy
/etc/caddy/sites/<name>.caddy               the site's Caddy config
/etc/systemd/system/shipit-<name>.service   the site's unit (node/nextjs)
/srv/<name>/
  repo.git/                                 bare clone, fetched on each deploy
  releases/<UTC time>-<sha>/                at most two after a deploy
  current  -> releases/...
  previous -> releases/...
  home/, .ssh/                              the build user's home and deploy key
/var/lib/shipit-<name>/                     data folders (opt-in, node/nextjs)
/var/cache/shipit-<name>/                   Next.js runtime cache
/var/log/shipit/<name>/access.log           access log
/var/lib/shipit/                            locks
```

Who can do what:

- **root** runs shipit and never runs repo code: `shipit.ini` is parsed as data with `git config`,
  never sourced.
- **`<name>-build`** runs every repo command (fetch, install, build) with a clean environment. It
  can write only the release being built; root takes each release back when its build ends, so a
  build can't change a live release or repoint `current`.
- **`<name>`** runs a node/nextjs process. It can read the release and write only its data and
  cache folders.
- **`caddy`** can read a static site's `static.root` and nothing else of the site (ACLs, not group
  membership), and shipit refuses a release whose `static.root` has a symlink pointing outside it.

Sites are isolated from each other: separate users, code, data and ports. Every
`shipit.ini` value is checked against a strict pattern, and every config is validated on a temp copy
before it's installed. **Anyone who can push to a site's deployed branch runs code on the VPS** as
`<name>-build`, and the build sees that site's secrets: deploy only repos you trust.

## Removing a site

There's no command for it. As root, for a site `<name>`:

```bash
systemctl disable --now shipit-<name>        # node/nextjs only
rm -f /etc/systemd/system/shipit-<name>.service && systemctl daemon-reload
rm -f /etc/caddy/sites/<name>.caddy && systemctl reload caddy
rm -rf /srv/<name> /var/cache/shipit-<name> /var/log/shipit/<name>
rm -f /etc/shipit/sites/<name>.conf /etc/shipit/sites/<name>.env /var/lib/shipit/<name>.lock
userdel <name>-build && userdel <name>
rm -rf /var/lib/shipit-<name>                # the site's data: see below
```

**Warning: deleting `/var/lib/shipit-<name>` deletes the site's data**, and shipit keeps no backup.
Copy it somewhere first if you may need it.

## Limitations

- Builds run on the VPS, one at a time, so a large build is slow on a small plan.
- One Node.js version for every site, fixed when `setup` first runs.
- Rollback goes back one release only, and never touches data.
- A node/Next.js deploy restarts the process (a 1–3 s gap). No blue/green.
- No backups, no command to remove a site, and a site's name and type can't change after its first
  deploy.
- Repos come from GitHub only (`https://github.com/<owner>/<repo>`).
- A private npm registry that needs a token at install time isn't supported.

## Development

```bash
make          # lint (bash -n, shellcheck, shfmt) and the bats unit tests
make lint
make test
```

On macOS, install the tools with Homebrew (`/bin/bash` is 3.2; the tests need bash 5):
`brew install bash bats-core shellcheck shfmt gettext flock parallel` (`make test` runs bats with
`--jobs 4`, which needs GNU `parallel`). Tests that need GNU-only tools or root
skip with a reason.

GitHub Actions runs `make` on every push to `main` and every pull request
([.github/workflows/check.yml](.github/workflows/check.yml)).
[CLAUDE.md](CLAUDE.md) has the layout and the engineering rules; [docs/plan.md](docs/plan.md) is the
spec.
