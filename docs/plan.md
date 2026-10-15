# shipit — plan

A small bash tool that does three things:

1. `shipit setup` — prepare a VPS for atomic, symlink-based deploys.
2. `shipit deploy <name> [ref]` (or `<repo-url> <name> [ref]`) — build a website from GitHub and switch to it.
3. `shipit rollback <name>` — go back exactly one version.

Everything runs non-interactively, so each command can be run over SSH from a laptop or from GitHub
Actions. Several sites share one VPS.

Out of scope (dropped from the old tool): PostgreSQL, backups/restore, state folders,
`env`/`logs`/`status` commands, nftables, per-process units, swap sizing, Tracklite reference scripts.

---

## 1. Constraints → consequences

| Constraint | Consequence |
|---|---|
| Debian 13+ or Ubuntu 26.04+ | `setup` reads `/etc/os-release`: `ID=debian` with `VERSION_ID >= 13`, or `ID=ubuntu` with `VERSION_ID >= 26.04`. Anything else is refused. Both use apt, systemd and bash 5, so one code path covers them. Ubuntu 26.04 ships sudo-rs and the Rust coreutils, so the sudoers line, `visudo -cf` and `mv -T` must be checked by hand on Ubuntu as well as Debian. |
| Caddy is the only web server | Caddy (stable apt repo) listens on 80/443, gets TLS certificates, serves static sites and proxies Node/Next.js sites. nginx is **not** installed. |
| Node.js LTS | NodeSource apt repo for the LTS major current when `setup` first runs (looked up in `nodejs.org/dist/index.json` with `jq`). The major is recorded in `/etc/shipit/host.conf` and never changed automatically; re-running `setup` keeps it. |
| One rollback version | After a deploy finishes, each site keeps at most two releases: `current` and `previous`. Every successful deploy deletes the rest. |
| Many sites per VPS | Each site gets its own folder, two Linux users, port (Node/Next.js), Caddy site file and systemd unit. Domains and ports are checked for uniqueness across sites. |
| Remote via SSH / CI | No prompts in any command. A dedicated `ci` SSH user may only run `deploy` and `rollback`, and each CI key only for its own site (forced command + one sudoers line). Exit status 0 = success, non-zero = failure, so CI steps fail correctly. |
| Common repo config | Each repo has a `shipit.ini` at its root, in git's config dialect, read with `git config` (section 3). |

## 2. Packages installed by `setup`

| Package | Why |
|---|---|
| `caddy` | Web server, TLS, reverse proxy. |
| `nodejs` | Builds and runs sites (npm comes with it). Node 25+ no longer bundles corepack, so setup installs a pinned `corepack` with npm and runs `corepack enable`, for pnpm/yarn. |
| `jq` | Reads the Node release index during `setup`, and `package.json` scripts during `deploy` (for the `node.build` default). |
| `curl` | Downloads apt keys, health checks. |
| `git` | Fetches repos. |
| `ca-certificates`, `gnupg` | Adding the NodeSource and Caddy apt repos with signed keys. |
| `gettext-base` | `envsubst`, used by `render` for templates. |
| `acl` | `setfacl`: gives Caddy read access to a static site's served folder only (section 4). |
| `ufw` | Firewall: allow the ports sshd listens on (5.1 step 5), 80/tcp, 443/tcp and 443/udp (HTTP/3); deny the rest. |
| `unattended-upgrades` | Automatic security updates. |
| `fail2ban` | Bans IPs that brute-force SSH (`sshd` jail with `backend = systemd`: Debian 13 has no `/var/log/auth.log`). |
| (already present) `util-linux` (`flock`), `systemd` | Locks, services. |

## 3. Repo config: `shipit.ini`

```ini
# shipit.ini
[site]
name = blog
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

[static]
root = out

[data]
dir = uploads
dir = db
```

Minimal examples, one per type:

```ini
# static: build with the defaults, serve dist/
[site]
name = docs
domain = docs.example.com
type = static

[static]
root = dist
```

```ini
# node: start is required
[site]
name = api
domain = api.example.com
type = node

[node]
start = node server.js

[data]
dir = uploads
```

```ini
# nextjs: every command has a default
[site]
name = blog
domain = blog.example.com
type = nextjs
```

| Key | Required | Meaning |
|---|---|---|
| `site.name` | yes | Site name: `^[a-z][a-z0-9-]{0,24}$`, at most 25 characters, so `<name>-build` fits Linux's 32-character username limit. Used for folders, users, unit, Caddy file. Must match the name given on the first deploy (5.2 A). |
| `site.domain` | yes | Primary hostname. Must not be used by another site. |
| `site.alias` | no, repeatable | Extra hostname, redirected (308) to `site.domain`. One per line. |
| `site.type` | yes | `static`, `node` or `nextjs`. Can't change after the first deploy (decision 15). |
| `site.health` | no | Path checked after a Node/Next.js switch. Default `/`. Needs a status below 500; set explicitly → needs exactly 200. Must match `^/[A-Za-z0-9._~/-]*$`. |
| `site.env` | no, repeatable | A key that must exist in the site's env file on the server; deploy fails, naming the missing ones, if any are absent. One per line. |
| `node.install` | no | Default: picked by lockfile — `npm ci` / `pnpm install --frozen-lockfile` / `yarn install --immutable`. Runs without the site's secrets (see below). |
| `node.build` | no | Default: `npm run build` if `package.json` has a `build` script, else nothing. |
| `node.start` | `node`: yes | Command that starts the server. It must listen on `$PORT`. `nextjs` default: `./node_modules/.bin/next start -p $PORT` (`next` isn't on the unit's PATH). It's written into the unit's `ExecStart=`, so a newline or other control character, `'`, `%` or `\` is rejected; systemd expands `$VAR` itself, so `$PORT` works. |
| `static.root` | `static`: yes | Folder (relative to the release) Caddy serves. Must match `^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$`, with no `..` segment. A `static` site may still have `node.install`/`node.build` (e.g. Vite, `next export`). |
| `data.dir` | no, repeatable | A subfolder of the site's data folder (section 4), matching `^[a-z0-9][a-z0-9_-]{0,63}$` (no `/`, no `..`). Each becomes an extra `StateDirectory=shipit-<name>/<dir>` in the unit, so systemd creates it with the right owner. Without any `data.dir`, no data folder is created: `git config` doesn't report an empty `[data]` section, so a site that keeps a single SQLite file still names a folder (e.g. `dir = db`). Rejected for `site.type = static` (no process to write to it). |

Parsing rules:
- `shipit.ini` is read from the commit with `git show <sha>:shipit.ini`, as `<name>-build`, and parsed
  with `git config -f <file> --no-includes -z --get` / `--get-all` / `--list` (`-z`: NUL-separated
  output, so a value can't fake extra lines). It is never sourced.
- `--no-includes` is always passed, so a repo can't use `[include]` to make the parser read other files.
- Only the sections `site`, `node`, `static` and `data` are allowed. Unknown sections or keys are
  rejected (checked against `--list`), so a typo like `domian` fails the deploy instead of being ignored.
- Every value is a string and is validated before use (kept from the old tool). git config turns
  escapes like `\n` in a value into real characters, so each key has its own pattern and control
  characters are never allowed. A single-value key given more than once is rejected; only
  `site.alias`, `site.env` and `data.dir` may repeat.
- Validation, including the domain clash check (5.2 A.3), runs every time a `shipit.ini` is used:
  before a build (5.2 A.3) and before every render (5.5), so a revert or rollback never renders a value
  that wasn't checked against the other sites as they are now.

Quirks to know when writing `shipit.ini`:
- `#` and `;` start a comment even in the middle of a value, so values containing them must be quoted,
  e.g. `start = "node server.js --tag=#1"`.
- Section and key names are case-insensitive. They're documented, and should be written, in lowercase.

Secrets are **never** in the repo. They live on the server in `/etc/shipit/sites/<name>.env`
(`KEY=value` lines, mode 600 `root:root`), edited by the admin over SSH. The service gets them via
`EnvironmentFile=`, which systemd reads as root before switching to `<name>`, so neither site user can
read the file. Root passes it to the build step on stdin. The install step doesn't get it, so
dependencies' install scripts never see secrets; a private npm registry that needs a token at install
time isn't supported.

## 4. Server layout

```
/etc/shipit/host.conf                 NODE_MAJOR, written once by setup
/etc/shipit/sites/<name>.conf         REPO, TYPE, DOMAIN, ALIASES, PORT (written by deploy)
/etc/shipit/sites/<name>.env          secrets, edited by the admin; root:root, 600
/etc/caddy/Caddyfile                  managed: global options + `import /etc/caddy/sites/*.caddy`
/etc/caddy/sites/                     root:root, 0755 (setup)
/etc/caddy/sites/<name>.caddy         managed, one per site
/etc/systemd/system/shipit-<name>.service   node/nextjs sites only
/srv/<name>/                          root:<name>, mode 2750
  home/                               home of <name>-build (npm cache); <name>-build, mode 700
  .ssh/                               deploy key (private repos), <name>-build, mode 700
  repo.git/                           bare repo, fetched each deploy; <name>-build, mode 700
  releases/                           root:<name>, mode 2750
    <UTC>-<full sha>/                 at most two after a deploy; created by root, owned by
                                      <name>-build while it builds, then root:<name>
  current  -> releases/...            root-owned; atomic: ln -s X current.new && mv -T current.new current
  previous -> releases/...            root-owned
/var/lib/shipit-<name>/               site data (node/nextjs, opt-in with [data]); <name>:<name>, 0700,
                                      created by systemd (StateDirectory=)
/var/cache/shipit-<name>/             Next.js runtime cache (nextjs only); <name>:<name>, 0700,
                                      created by systemd (CacheDirectory=), emptied on every switch
/var/log/shipit/                      root:root, 0755 (setup)
/var/log/shipit/<name>/access.log     Caddy access log; folder caddy:caddy, 0750; rolled by Caddy
/var/lib/shipit/build.lock            one build at a time on the VPS
/var/lib/shipit/<name>.lock           site lock, held for the whole deploy (A–D) and the whole rollback
```

Permissions: root owns `/srv/<name>` and `releases/`, so only root creates, renames or deletes release
folders and switches `current` and `previous`. A build step can't repoint the symlinks or rename a
release, which matters because root follows them when it switches, prunes and reads config. Root
creates each release folder, names it, and hands it to `<name>-build` for the build; when the build
finishes, root takes it back (`chown -R root:<name>`), so a later build can't change a live or previous
release. The build user owns only `repo.git`, `.ssh/`, `home/` and the release being built. The setgid
bit on `/srv/<name>` and `releases/` makes everything created inside inherit group `<name>`. Builds
run with `umask 027`, so releases are group-readable, not world-readable.

`<name>-build` is a member of group `<name>`, because it has to enter `/srv/<name>`. So nothing secret
is group-readable: the env file is root-only, and the data and cache folders are 0700.

For static sites, root gives `caddy` access with ACLs, not group membership: `u:caddy:x` on
`/srv/<name>`, `releases/` and the release folder, and `u:caddy:rX` recursively on `<root>` only,
applied after root takes the release back. ACLs take effect at once (a new group would reach a running
Caddy only after a restart), and Caddy can't read `repo.git`, the env file or the rest of the release.
Root also refuses a release whose `<root>` contains a symlink pointing outside `<root>`, so one site
can't serve another site's files. One site's build user can't read another site's code, even for
private repos.

Site data: a site that keeps files or SQLite on the VPS gets `/var/lib/shipit-<name>/`, created by
systemd's `StateDirectory=shipit-<name>` (`StateDirectoryMode=0700`) in the site's unit. systemd
creates it on every start, owned by `<name>:<name>`, keeps it writable under `ProtectSystem=strict`, and
sets `$STATE_DIRECTORY` in the process's environment; shipit adds no variable of its own. It survives
restarts, deploys and rollbacks because it isn't part of any release.
- With `data.dir` entries, `$STATE_DIRECTORY` isn't one path: systemd joins every `StateDirectory=`
  entry with `:`, root first (`/var/lib/shipit-blog:/var/lib/shipit-blog/uploads:/var/lib/shipit-blog/db`).
  Each folder is always at `/var/lib/shipit-<name>/<dir>`, so apps can hard-code that, take the first
  entry of `$STATE_DIRECTORY`, or read a path from the env file.
- It isn't inside `/srv/<name>`: that tree holds code, the build user owns the release folders and
  `repo.git`, and releases are deleted on prune. Outside `/srv/<name>`, the build user can't reach it.
- Access: `<name>` reads and writes it; `<name>-build` (although it's in group `<name>`: the folder is
  0700), `caddy` and other sites have no access. The
  build can't read production data, so a build step that needs it (e.g. Next.js static generation
  reading SQLite) fails.
- Backups are out of scope: this data exists only on the VPS, and backing it up is the admin's job.
- Serving uploads is out of scope: the app serves its own files; Caddy doesn't read the data folder.

Logs:
- Access logs: Caddy writes one per site to `/var/log/shipit/<name>/access.log`, in Caddy's default
  JSON (one request per line), rolled by Caddy itself (`roll_size 10MiB`, `roll_keep 10`), so no
  logrotate config is needed. The folder is `caddy:caddy` 0750: only root and caddy can read it.
  Requests to aliases (the redirects) are logged to the same file. Query strings are cut from the
  logged URI, since they can carry tokens.
  Read with `tail -f /var/log/shipit/<name>/access.log | jq`.
- App output: Node/Next.js stdout and stderr stay in the journal: `journalctl -u shipit-<name>`.
  Retention is journald's own size limits; shipit doesn't configure it.
- Caddy errors (TLS, proxy failures, reloads) stay in the journal: `journalctl -u caddy`.
- Build/deploy output is streamed to the SSH session, and so to the Actions log, and isn't kept on the
  VPS.

Users (each site gets two system accounts, neither can log in):
- `<name>-build` (member of group `<name>`) owns `repo.git`, `.ssh/`, `home/` and the release being
  built in `/srv/<name>`, and runs
  every repo command (`git fetch`, install, build). Its home is `/srv/<name>/home`, so its npm cache and
  deploy key stay inside the site.
- `<name>` (system, no login) runs a Node/Next.js site's process; it reads the release, writes nothing there.
- `ci` (login by SSH key only, forced command) can trigger `deploy` and `rollback` and nothing else;
  each key is tied to one site (5.1 step 6). Its login shell is `/bin/sh`, because sshd runs the forced
  command through it; the key can't choose another command.
- Root runs `shipit` (directly, or via `sudo` for `ci`).

## 5. Commands

### 5.1 `shipit setup [--ci-key <name> <public key file | ->]...`

Idempotent: re-running changes no file whose content is already right.

1. Check the OS (section 1) and that we're root.
2. Add the Caddy and NodeSource apt repos (signed-by keyrings), install the packages in section 2,
   then `npm install -g corepack@<pinned version>` and `corepack enable`.
3. Create `ci` (shell `/bin/sh`); create `/etc/shipit/sites`, `/etc/caddy/sites`, `/var/lib/shipit`,
   `/srv`, `/var/log/shipit` (root:root, 0755).
4. Write `/etc/caddy/Caddyfile` (`import /etc/caddy/sites/*.caddy`), validate, reload Caddy. Caddy
   files are always validated as `caddy` (`runuser -u caddy -- caddy validate`): validating opens the
   log files, and run as root it would create them owned by root, breaking the next reload.
5. ufw: allow the ports sshd actually listens on (read from `sshd -T`, so a non-22 port doesn't lock
   you out), 80/tcp, 443/tcp and 443/udp; enable. fail2ban: enable the `sshd` jail with
   `backend = systemd`.
   unattended-upgrades: enable.
6. For each `--ci-key <name> <file>` (repeatable; re-run setup to add a site's key later; the site
   doesn't have to exist yet): the key must be exactly one line, accepted by `ssh-keygen -l -f`, and
   made only of a key type, base64 and an optional comment, so it can't add a second line or its own
   options. Install it in `~ci/.ssh/authorized_keys` as
   `restrict,command="sudo /usr/local/bin/shipit remote <name>" <key> shipit:<name>`, replacing that
   site's previous line and keeping the others. Write `/etc/sudoers.d/shipit-ci` (validated with
   `visudo -cf` on a temp copy first): `ci ALL=(root) NOPASSWD: /usr/local/bin/shipit remote *` plus
   `Defaults:ci env_keep += SSH_ORIGINAL_COMMAND`. The wildcard is safe because a `ci` key can't run
   anything but its forced command, which fixes the arguments, and `remote` validates them.
7. SSH hardening: write `/etc/ssh/sshd_config.d/10-shipit.conf` (`PasswordAuthentication no`,
   `KbdInteractiveAuthentication no`, `PermitRootLogin prohibit-password`), check it with `sshd -t`,
   install, `systemctl reload ssh`. Done **only** if root has a key in `authorized_keys` and the current
   session logged in with a key (sshd's journal shows `Accepted publickey` for this session); otherwise
   setup skips this step and prints why, so it can never lock you out.
8. Print the host key lines for `VPS_KNOWN_HOSTS`: one known_hosts line per
   `/etc/ssh/ssh_host_*_key.pub`, with `<host>` as a placeholder for the name or IP CI will use, then:
   "Replace <host> with the address CI connects to (use [host]:port if SSH isn't on 22), and save these
   lines as the GitHub secret VPS_KNOWN_HOSTS." Setup can't know the public address, so it doesn't
   guess.

Bootstrap from your laptop:
```bash
ssh root@vps 'curl -fsSL https://github.com/<you>/shipit/archive/refs/tags/v1.0.0.tar.gz | tar -xz && cd shipit-1.0.0 && ./install.sh'
ssh root@vps 'shipit setup --ci-key blog -' < ~/.ssh/shipit_blog_ci.pub
```
The last lines `setup` prints are the known_hosts lines: replace `<host>` and save them as the GitHub
secret `VPS_KNOWN_HOSTS` (section 5.4).

### 5.2 `shipit deploy <name> [ref]` / `shipit deploy <repo-url> <name> [ref]`

`ref` defaults to the repo's default branch; CI passes `$GITHUB_SHA`. A ref is a 40-hex SHA or a
name accepted by `git check-ref-format --branch` that doesn't start with `-`, and git gets it after
`--end-of-options`. The URL form is needed for a site's first deploy; for a known site it's accepted if
the URL matches the registered REPO. The only accepted URL is `https://github.com/<owner>/<repo>`
(optionally ending in `.git`).

Locks: the site lock is taken at the start of A and held through D, so two deploys of the same site
can't overlap (otherwise one deploy's prune could delete the other's half-built release). A second
deploy of the same site waits, printing "Another deploy of <name> is running; waiting." The lock order
is always site lock first, then `build.lock`, so a deploy never holds `build.lock` while waiting for a
site lock.

A. **Resolve the site** (site lock taken)
   1. Name form: load `/etc/shipit/sites/<name>.conf`; refuse if it doesn't exist. URL form: if
      `<name>.conf` exists, its REPO must equal the URL. Otherwise this is a first deploy: validate the
      name, refuse if a non-shipit user `<name>` or `<name>-build` exists, create both users and the
      root-owned `/srv/<name>` skeleton (section 4) and `/var/log/shipit/<name>/` (caddy:caddy, 0750;
      every deploy re-checks it, idempotently), and write `<name>.conf` with REPO only. A rerun of
      the same command resumes; another repo can't claim the name meanwhile.
   2. Access, until the site's first deploy succeeds: if `git ls-remote` over HTTPS without
      credentials works (`GIT_TERMINAL_PROMPT=0`, so it never waits for a password), the repo is
      public. Otherwise, if `git ls-remote` over SSH with the site's deploy key fails too (or there's
      no key yet), create the key in `/srv/<name>/.ssh/` if it's missing (an existing one is reused),
      print the public key, and exit non-zero with: "Can't fetch <url>. If it's a private repo, add
      this key as a read-only deploy key at https://github.com/<owner>/<repo>/settings/keys/new, then
      run the same command again." A rerun after adding the key continues. With a key,
      git uses `git@github.com:<owner>/<repo>.git`, derived from REPO, with GitHub's SSH host keys
      shipped by shipit (`templates/github_known_hosts`) and `StrictHostKeyChecking=yes`.
   3. As `<name>-build`, `git fetch --prune` only `refs/heads/*` and `refs/tags/*` into `repo.git`,
      resolve `ref` to a full SHA, and read and validate `shipit.ini` at that commit (section 3),
      including the `site.env` keys. Then, before building:
      - If `site.name` differs from the name: on a first deploy, refuse with "shipit.ini says the site
        name is <x>, but you asked to deploy it as <name>."; later, refuse with "shipit.ini says the
        site name is <x>, but this repo is deployed as <name>. Renaming a site isn't supported; change
        site.name back."
      - If `site.type` differs from TYPE in `<name>.conf` (a later deploy), refuse with "shipit.ini
        says the site type is <x>, but this site is deployed as <type>. Changing a site's type isn't
        supported."
      - Check `site.domain` and every `site.alias` against every other site's DOMAIN and ALIASES in
        `/etc/shipit/sites/*.conf`. A clash fails the deploy. A first deploy is given a PORT from
        3000–3999. TYPE, DOMAIN and ALIASES are written to `<name>.conf` only in C.2, so the conf
        always describes `current`.
B. **Build** (`build.lock` taken, after the site lock; repo commands run as `<name>-build`)
   1. Root creates `releases/<UTC>-<full sha>` and hands it to `<name>-build`, which fills it with
      `git archive <sha> | tar -x` and pins the commit with `git update-ref refs/shipit/<sha> <sha>`,
      so `git gc` never removes it (5.5). Every build step runs with `umask 027`.
   2. Run install (without secrets), then build (with the env file on stdin). A failure deletes the
      half-built release and leaves the live site untouched.
   3. `nextjs` only: replace `.next/cache` (the build cache) with a symlink to
      `/var/cache/shipit-<name>`, so `next start` can write its image and ISR cache (section 6).
   4. Root takes the release back (`chown -R root:<name>`). `static` only: refuse the release if
      `<root>` contains a symlink pointing outside `<root>`, then set Caddy's ACLs (section 4).
   `build.lock` is released here; the site lock is kept.
C. **Switch** (site lock still held)
   1. Remember where `previous` points, then `previous` → old `current`; `current` → new release (both
      atomic).
   2. Render the Caddy file and unit from the `shipit.ini` of the new `current` (section 5.5) and
      validate them, then write TYPE, DOMAIN and ALIASES to `<name>.conf`. Reload (never restart)
      Caddy if the Caddy file changed; `daemon-reload` if the unit changed (including `data.dir`); on
      a first deploy, `systemctl enable` the unit so the site comes back after a reboot. If rendering
      or validating fails, revert (step 4) and exit non-zero.
   3. Node/Next.js: restart `shipit-<name>` (`nextjs`: stop, `systemctl clean --what=cache`, start, so
      a release never sees another release's cache), then poll `http://127.0.0.1:$PORT$health` with
      `Host: $domain` for up to 60 s. Static: nothing restarts; Caddy is reloaded only if its file
      changed in step 2, and otherwise resolves the `current` symlink per request. When the Caddy file
      changes (e.g. `static.root`), requests between step 1 and the reload in step 2 can get a 404, a
      window well under a second. Accepted.
   4. Revert, on a failed health check or a failed render: switch `current` and `previous` back to
      where they pointed before step 1 (so a failed deploy keeps its rollback target), re-render the
      config from the restored release (reload Caddy / `daemon-reload` as needed), restart, delete the
      failed release, exit non-zero ("Deploy failed health check; still serving <old release>.").
      On a first deploy there's nothing to go back to: stop and disable the unit, remove `current`,
      the Caddy file (reload Caddy) and the release, and keep the users and `<name>.conf`, so running
      the same deploy again starts over; exit non-zero ("First deploy of <name> failed; nothing is
      served.").
D. **Prune**: delete every release that isn't `current` or `previous`, and its `refs/shipit/<sha>`
   (unless a kept release has the same SHA). Release the site lock.

### 5.3 `shipit rollback <name>`

Under the site lock: needs a `previous`. Swap `current` and `previous` atomically, re-render the
Caddy file and unit from the new `current`'s `shipit.ini` (section 5.5; reload Caddy / `daemon-reload`
as needed, and TYPE, DOMAIN and ALIASES in `<name>.conf`), restart the unit (Node/Next.js; `nextjs`
empties its cache as in 5.2 C.3) and health-check it. If validation or the health check fails, swap
back, re-render and restart, and exit non-zero ("Rollback failed health check; still serving
<release>."). Rolling back twice returns to where you started. The next deploy drops whichever release
is then `previous`.

Rollback swaps code only, never data (`/var/lib/shipit-<name>` is untouched). Schema changes, e.g.
SQLite migrations, must stay compatible with the previous release for one version.

### 5.4 `shipit remote <name>` (internal, used only by the `ci` forced command)

`<name>` comes from the key's forced command. Parses `$SSH_ORIGINAL_COMMAND` strictly:
`deploy <name> [<40-hex sha | branch>]` (the ref rule of 5.2) or `rollback <name>`, and the name must
equal the key's `<name>`, so a site's key can't act on another site. Only sites that have completed a
deploy (no first deploys from CI). Anything else: refused.

GitHub secrets (per repo):
- `SHIPIT_KEY`: this site's CI private key (its public half was given to `setup --ci-key <name>`).
- `VPS_KNOWN_HOSTS`: the known_hosts lines `setup` printed, with `<host>` replaced.
- `VPS_HOST`: the name or IP CI connects to.
- `VPS_PORT` (optional): the SSH port, if it isn't 22.

GitHub Actions deploy workflow:
```yaml
name: deploy
on:
  push:
    branches: [main]
concurrency:
  group: deploy-blog
  cancel-in-progress: false
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Deploy to VPS
        env:
          SHIPIT_KEY: ${{ secrets.SHIPIT_KEY }}
          VPS_KNOWN_HOSTS: ${{ secrets.VPS_KNOWN_HOSTS }}
          VPS_HOST: ${{ secrets.VPS_HOST }}
          VPS_PORT: ${{ secrets.VPS_PORT }}
        run: |
          install -d -m 700 ~/.ssh
          install -m 600 /dev/stdin ~/.ssh/id_ed25519 <<< "$SHIPIT_KEY"
          install -m 644 /dev/stdin ~/.ssh/known_hosts <<< "$VPS_KNOWN_HOSTS"
          ssh -p "${VPS_PORT:-22}" -o StrictHostKeyChecking=yes \
            -o ServerAliveInterval=30 -o ServerAliveCountMax=6 "ci@$VPS_HOST" deploy blog "$GITHUB_SHA"
```

Manual rollback workflow (run from the Actions tab):
```yaml
name: rollback
on: workflow_dispatch
concurrency:
  group: deploy-blog
  cancel-in-progress: false
jobs:
  rollback:
    runs-on: ubuntu-latest
    steps:
      - name: Roll back on VPS
        env:
          SHIPIT_KEY: ${{ secrets.SHIPIT_KEY }}
          VPS_KNOWN_HOSTS: ${{ secrets.VPS_KNOWN_HOSTS }}
          VPS_HOST: ${{ secrets.VPS_HOST }}
          VPS_PORT: ${{ secrets.VPS_PORT }}
        run: |
          install -d -m 700 ~/.ssh
          install -m 600 /dev/stdin ~/.ssh/id_ed25519 <<< "$SHIPIT_KEY"
          install -m 644 /dev/stdin ~/.ssh/known_hosts <<< "$VPS_KNOWN_HOSTS"
          ssh -p "${VPS_PORT:-22}" -o StrictHostKeyChecking=yes \
            -o ServerAliveInterval=30 -o ServerAliveCountMax=6 "ci@$VPS_HOST" rollback blog
```

Why the workflows look like this:
- **Pinned host key.** `StrictHostKeyChecking=accept-new` checks nothing on a GitHub runner: every
  runner starts with an empty known_hosts, so it trusts whatever answers. The workflow writes
  `VPS_KNOWN_HOSTS` to `~/.ssh/known_hosts` and connects with `StrictHostKeyChecking=yes`. Instead of
  copying setup's output, the keys can also be fetched over an already-trusted connection:
  `ssh root@vps 'cat /etc/ssh/ssh_host_ed25519_key.pub'`. Don't use `ssh-keyscan` from the runner: it
  has the same trust-on-first-use problem.
- **Long builds stay connected.** The build runs on the VPS while the SSH session stays open, streaming
  its output to the Actions log. `ServerAliveInterval=30` and `ServerAliveCountMax=6` keep an
  idle-looking connection from being dropped by a NAT or firewall in the middle of a build, and notice
  a really dead connection within about 3 minutes.
- **One deploy at a time.** The workflow-level `concurrency` group (`deploy-<name>`,
  `cancel-in-progress: false`) keeps at most one running and one pending run: a newer pending run
  replaces the older pending one. For pushes that means the newest commit wins and intermediate pushes
  are skipped. The rollback workflow uses the same group, so a rollback can't run alongside a deploy;
  but a rollback waiting behind a running deploy is cancelled by a newer push (and a pending deploy by
  a rollback), so re-run it once the deploy finishes. The server-side site lock is the real guarantee;
  the concurrency group only keeps runs visible in GitHub and avoids runners waiting on SSH.
- **Secrets go through `env:`**, not `${{ }}` inside `run:`, so a secret's content is never pasted into
  the shell script itself.

### 5.5 Config follows `current`

The Caddy file and unit are always rendered from the `shipit.ini` of the release `current` points at,
read as `<name>-build` with `git config` and validated as in section 3, including the domain clash
check. This happens after every switch (5.2 C), every
revert (5.2 C.4) and every rollback (5.3), so rolling back code also rolls back its config. Example:
a commit changes `static.root` from `out` to `dist`; rolling it back makes Caddy serve `current/out`
again. A release's `shipit.ini` is read from the release's commit: the full SHA is in the release folder's
name, which only root sets and the build user can't rename, and the commit is pinned in `repo.git` by
`refs/shipit/<sha>` (5.2 B.1), so it's still there after a force-push and `git gc`.

## 6. Templates

- `Caddyfile` — global options, `import /etc/caddy/sites/*.caddy`.
- `site-static.caddy` — `root * /srv/<name>/current/<root>`, `file_server`, `encode`, security headers,
  and a `log` block writing `/var/log/shipit/<name>/access.log` (`roll_size 10MiB`, `roll_keep 10`,
  `format filter` cutting the query string from `request>uri`). The alias redirect blocks get the same
  `log` block.
- `site-proxy.caddy` — `reverse_proxy 127.0.0.1:<port>`, `encode`, headers, and the same `log` block.
- `site.service` — `User=<name>`, `WorkingDirectory=/srv/<name>/current`,
  `EnvironmentFile=/etc/shipit/sites/<name>.env`, `Environment=NODE_ENV=production PORT=<port>`,
  `ExecStart=/bin/sh -c '<start>'`, `Restart=on-failure`, hardening (`NoNewPrivileges`,
  `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, `SocketBindAllow=tcp:<port>` with
  `SocketBindDeny=any`, so a site can't take another site's port while it restarts), logs to the
  journal. With `[data]`: `StateDirectory=shipit-<name>` plus one `shipit-<name>/<dir>` per
  `data.dir`, and `StateDirectoryMode=0700`. `nextjs`: `CacheDirectory=shipit-<name>`,
  `CacheDirectoryMode=0700`.
- `sshd.conf` (the drop-in), `sudoers-ci`, `authorized_keys` line (one per site key),
  `fail2ban-sshd.conf` (the jail drop-in), `github_known_hosts` (GitHub's SSH host keys, copied, not
  rendered).

Each template gets a golden file and a unit test (kept from the old tool).

## 7. Code layout

```
bin/shipit           dispatcher: setup | deploy | rollback | remote | help
lib/common.sh        log/err/die, validators, locks, render, install_if_changed, atomic_link, health_ok
lib/config.sh        shipit.ini reading + validation (git config), site .conf read/write
lib/setup.sh
lib/deploy.sh        resolve → build → switch → prune
lib/rollback.sh
lib/remote.sh
templates/
install.sh
test/unit/*.bats, test/golden/, test/fixtures/   (make: lint + bats, CI unchanged)
```

Kept from the old tool: `render`, `install_if_changed`, lock helpers, `check_domain`, `check_port`,
`health_ok`, the atomic symlink switch (`atomic_link <target> <link>`), "validate temp copy then
install", "root never runs repo code". `check_domain` and `check_port` check syntax only; the clash
checks against other sites (5.2 A.3) use the site configs, so they come with `lib/config.sh`.

## 8. Milestones

| # | Deliverable | Verified by |
|---|---|---|
| M0 | Delete the old tool's code, new skeleton, dispatcher, helpers kept from the old tool, CI green | `make` |
| M1 | `shipit.ini` parser + validators | bats (fixtures for every key and error, including an unknown key, a duplicate single-value key, an `[include]` attempt, an unquoted `#` in a value, an invalid `data.dir` (`../x`, `a/b`), `[data]` on a static site, a first-deploy name that differs from `site.name`, a `node.start` with `\n`, `'` or `%`, a `static.root` of `../x`, a `site.health` with a space, and a ref starting with `-`) |
| M2 | `setup` (incl. SSH hardening, firewall) | bats (golden files for every rendered file) |
| M3 | `deploy` static | bats (golden `site-static.caddy` with the `log` block; URL form with a REPO that differs from the registered one refused; renamed `site.name` refused; domain/alias clash on a later deploy refused; a changed `site.type` refused; two concurrent deploys of one site run one after the other) |
| M4 | `deploy` node / nextjs + health check + auto-revert + data folder | bats (golden `site-proxy.caddy` and `site.service`) |
| M5 | `rollback` | bats |
| M6 | `remote` + CI user + GitHub Actions example | bats (command parsing: site A's key can't deploy or roll back site B, a ref like `--upload-pack=x` is refused; a `--ci-key` file with two lines or key options is refused) |
| M7 | README, CLAUDE.md rewritten | review |

## 9. Decisions

| # | Question | Decision |
|---|---|---|
| 1 | Web server | **Caddy only.** nginx isn't installed. |
| 2 | Site types | **`static`, `node`, `nextjs`.** |
| 3 | Where builds run | **On the VPS, as the site's own build user `<name>-build`**, one build at a time. |
| 4 | Private repos | **Per-site deploy key.** The first deploy prints it with the GitHub URL and exits non-zero; run deploy again after adding it. The first deploy takes the name on the command line (`shipit deploy <repo-url> <name>`), so the key's folder exists before the first fetch; `site.name` must match. |
| 5 | Secrets | **Edited by hand over SSH** in `/etc/shipit/sites/<name>.env`. No command or CI path for them. |
| 6 | First deploy | **By hand, as root.** CI (`ci` user, `shipit remote`) only redeploys and rolls back registered sites. |
| 7 | SSH hardening | **On**, guarded by the key-login check in 5.1 step 7. |
| 8 | Downtime on Node/Next.js deploy | **Accepted**: a ~1–3 s gap while the unit restarts. No blue/green. |
| 9 | Removing a site | **No command.** README documents the manual steps (stop/disable unit, remove Caddy file and reload, remove `/srv/<name>`, `/etc/shipit/sites/<name>.*`, `/var/lib/shipit-<name>`, `/var/log/shipit/<name>`, the users `<name>` and `<name>-build`). Warning: deleting `/var/lib/shipit-<name>` deletes the site's data. |
| 10 | Rewrite approach | **Fresh rewrite** on a new branch; keep the old tool's helpers listed in section 7. |
| 11 | Who runs shipit | **Root.** Repo code only ever runs as `<name>-build` (build) or `<name>` (runtime). Running shipit itself as an unprivileged user was considered and rejected: it needs two privilege modes, an extra command and sudo rules for restarts anyway, and the CI path is already limited by the forced command plus strict `shipit remote` parsing. |
| 12 | Repo config format | **`shipit.ini`, in git's config dialect.** It allows comments, is easy to read, adds no dependency (`git` is already installed), and `git config` is a strict, well-specified parser that exits non-zero on bad syntax. Considered: JSON (no comments) and YAML (needs python3 + yq, has YAML 1.1 quirks, and is a bigger parser to run on untrusted input). |
| 13 | Site data | **`/var/lib/shipit-<name>` (0700) via systemd `StateDirectory=`, opt-in with `[data]`, node/nextjs only.** No backups, no Caddy-served folders. Not inside `/srv/<name>`: that tree holds code, the build user owns the release folders and `repo.git`, and releases are deleted on prune. `$STATE_DIRECTORY` is a `:`-joined list when `data.dir` is set; this is documented rather than worked around. |
| 14 | Config follows `current` | **The Caddy file and unit are always rendered from the `shipit.ini` of the release `current` points at**, after every switch, revert and rollback, so rolling back code also rolls back its config. |
| 15 | Renaming a site, changing its type | **Site name and type are fixed after the first deploy; renaming or changing type = remove + deploy.** A later deploy whose `site.name` or `site.type` differs is refused before building, so a rollback never crosses a type change. |
| 16 | CI host key | **CI pins the VPS host key:** setup prints known_hosts lines, CI uses `StrictHostKeyChecking=yes`. `accept-new` and `ssh-keyscan` on the runner were rejected: a fresh runner would trust any host on every run. |
| 17 | Who owns `/srv/<name>` | **Root** (`root:<name>`, 2750), and `releases/` too. Root creates and names release folders, owns the symlinks, and takes each release back after its build; `<name>-build` owns only `repo.git`, `.ssh/`, `home/` and the release being built. Rejected: build-owned `/srv/<name>`, where a build step could repoint `current`/`previous` or rename releases that root then follows. |
| 18 | CI key scope | **One key per site.** `setup --ci-key <name> <key>` puts the site in the forced command (`shipit remote <name>`), and `remote` refuses any other site. Rejected: one shared key, with which any repo could deploy or roll back every site. |
| 19 | Next.js runtime cache | **`CacheDirectory=shipit-<name>`**, linked from `.next/cache` after the build and emptied (`systemctl clean --what=cache`) on every switch, so a rollback never serves pages cached by the newer release. |
| 20 | Logs | **Per-site access logs in `/var/log/shipit/<name>/access.log`, rolled by Caddy; app and Caddy errors in the journal; build output only in the SSH session/Actions log. No logrotate.** |
| 21 | Caddy's access to static sites | **ACLs (`setfacl`) on the served folder only**, set after the build. Rejected: adding `caddy` to group `<name>`, which let Caddy read `repo.git`, the whole release and the env file (so one site's symlink could publish another's), and which a running Caddy only sees after a restart. |
| 22 | Secrets during install | **None: only the build step gets the env file.** Dependencies' install scripts are third-party code. Private npm registries that need a token at install time aren't supported. |
| 23 | Values from `shipit.ini` in rendered files | **Every key has a strict pattern; control characters are never allowed**, because git config turns `\n` into a newline and a value lands in a unit or Caddy file that root installs. |
