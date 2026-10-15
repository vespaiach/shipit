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
| `nodejs` | Builds and runs sites (npm comes with it). Node 25+ no longer bundles corepack, so setup installs a pinned `corepack` (0.36.0, decision 28) with npm and runs `corepack enable`, for pnpm/yarn. |
| `jq` | Reads the Node release index during `setup`, and `package.json` scripts during `deploy` (for the `node.build` default). |
| `curl` | Downloads apt keys, health checks. |
| `git` | Fetches repos. |
| `ca-certificates`, `gnupg` | Adding the NodeSource and Caddy apt repos with signed keys. |
| `gettext-base` | `envsubst`, used by `render` for templates. |
| `acl` | `setfacl`: gives Caddy read access to a static site's served folder only (section 4). |
| `ufw` | Firewall: allow the ports sshd listens on (5.1 step 5), 80/tcp, 443/tcp and 443/udp (HTTP/3); deny the rest. |
| `unattended-upgrades` | Automatic security updates. |
| `fail2ban` | Bans IPs that brute-force SSH (`sshd` jail with `backend = systemd`: Debian 13 has no `/var/log/auth.log`). |
| `sudo` | The `ci` user runs `shipit remote` through one sudoers rule; `visudo` checks it (5.1 step 6). Minimal images may lack it. |
| (already present) `util-linux` (`flock`), `systemd` | Locks, services. |

## 3. Repo config: `shipit.ini`

The site's name isn't in `shipit.ini`: it comes from the command line on the first deploy (decision 67).

```ini
# shipit.ini
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
domain = docs.example.com
type = static

[static]
root = dist
```

```ini
# node: start is required
[site]
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
domain = blog.example.com
type = nextjs
```

| Key | Required | Meaning |
|---|---|---|
| `site.domain` | yes | Primary hostname. Must not be used by another site. |
| `site.alias` | no, repeatable | Extra hostname, redirected (308) to `site.domain`. One per line. Not equal to `site.domain`. |
| `site.type` | yes | `static`, `node` or `nextjs`. Can't change after the first deploy (decision 15). |
| `site.health` | no | Node/Next.js only. Path checked after a switch. Default `/`. Needs a status below 500; set explicitly → needs exactly 200. Must match `^/[A-Za-z0-9._~/-]*$`. |
| `site.env` | no, repeatable | A key that must exist in the site's env file on the server; deploy fails, naming the missing ones, if any are absent. One per line. Must match `^[A-Za-z_][A-Za-z0-9_]*$`. |
| `node.install` | no | Default: picked by lockfile — `npm ci` / `pnpm install --frozen-lockfile` / `yarn install --immutable`. Runs without the site's secrets (see below). Any non-empty command line without control characters: it runs as `<name>-build` and never lands in a rendered file. |
| `node.build` | no | Default: `npm run build` if `package.json` has a `build` script, else nothing. Same rule as `node.install`. |
| `node.start` | `node`: yes; not for `static` | Command that starts the server. It must listen on `$PORT`. `nextjs` default: `./node_modules/.bin/next start -p $PORT` (`next` isn't on the unit's PATH). It's written into the unit's `ExecStart=`, so a newline or other control character, `'`, `%` or `\` is rejected; systemd expands `$VAR` itself, so `$PORT` works. |
| `static.root` | `static`: yes | Folder (relative to the release) Caddy serves. Must match `^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$`, with no `.` or `..` segment (so never the release itself, which holds `shipit.ini`). Not for `node`/`nextjs`. A `static` site may still have `node.install`/`node.build` (e.g. Vite, `next export`). |
| `data.dir` | no, repeatable | A subfolder of the site's data folder (section 4), matching `^[a-z0-9][a-z0-9_-]{0,63}$` (no `/`, no `..`). Each becomes an extra `StateDirectory=shipit-<name>/<dir>` in the unit, so systemd creates it with the right owner. Without any `data.dir`, no data folder is created: `git config` doesn't report an empty `[data]` section, so a site that keeps a single SQLite file still names a folder (e.g. `dir = db`). Rejected for `site.type = static` (no process to write to it). |

Parsing rules:
- `shipit.ini` is read from the commit with `git show <sha>:shipit.ini`, as `<name>-build`, and parsed
  in one pass of `git config -f <file> --no-includes -z --list` (`-z`: NUL-separated `key\nvalue`
  entries, so a value can't fake extra lines). It is never sourced. A syntax error fails with its line
  number.
- `--no-includes` is always passed, so a repo can't use `[include]` to make the parser read other files.
- Only the sections `site`, `node`, `static` and `data` are allowed. Unknown sections or keys are
  rejected (checked against `--list`, all named in one message), so a typo like `domian` fails the
  deploy instead of being ignored. Subsections (`[site "x"]`) are unknown keys too. So is a key that
  doesn't fit `site.type` (marked in the table): it would otherwise be silently ignored.
- Every value is a string and is validated before use (kept from the old tool). git config turns
  escapes like `\n` in a value into real characters, so each key has its own pattern and control
  characters are never allowed. A key without a value (`type` alone) or with an empty one is rejected.
  A single-value key given more than once is rejected; only `site.alias`, `site.env` and `data.dir` may
  repeat, and none of them may repeat a value.
- Defaults applied by the parser: `site.health` = `/`, and `node.start` for `nextjs`. The
  `node.install` and `node.build` defaults need the repo (lockfile, `package.json`), so the build step
  picks them.
- Validation, including the domain clash check (5.2 A.3), runs every time a `shipit.ini` is used:
  before a build (5.2 A.3) and before every render (5.5), so a revert or rollback never renders a value
  that wasn't checked against the other sites as they are now.

Quirks to know when writing `shipit.ini`:
- `#` and `;` start a comment even in the middle of a value, so values containing them must be quoted,
  e.g. `start = "node server.js --tag=#1"`.
- Section and key names are case-insensitive. They're documented, and should be written, in lowercase.

Secrets are **never** in the repo. They live on the server in `/etc/shipit/sites/<name>.env`
(`KEY=value` lines, mode 600 `root:root`, format in decision 42), edited by the admin over SSH. The
service gets them via `EnvironmentFile=-` (the `-`: a site that needs no secrets needs no file,
decision 53), which systemd reads as root before switching to `<name>`, so neither site user can read
the file. Root passes it to the build step on stdin. The install step
doesn't get it, so dependencies' install scripts never see secrets; a private npm registry that needs
a token at install time isn't supported.

## 4. Server layout

```
/etc/shipit/host.conf                 NODE_MAJOR, written once by setup
/etc/shipit/sites/<name>.conf         REPO, TYPE, DOMAIN, ALIASES, PORT (written by deploy and rollback); root, 0644
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

`<name>.conf` is `KEY=value` lines (`ALIASES` space-separated), blank lines and `#` comments; it's
read as data, never sourced, and any other line, a repeated or unknown key, or an invalid value is
refused. REPO is always there; TYPE and DOMAIN come together (C.2); a `node`/`nextjs` site has PORT.
It holds nothing secret. It's replaced by a rename, so a deploy reading it for its clash check never
sees half a file.

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
  logged URI, since they can carry tokens, and from the logged `Referer` and `Location` headers, which
  can repeat them (decision 45).
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
  command through it; the key can't choose another command. A system user (GECOS `shipit ci`), with
  password field `*` and a root-owned home `/home/ci` (decision 63).
- Root runs `shipit` (directly, or via `sudo` for `ci`).

## 5. Commands

### 5.1 `shipit setup [--ci-key <name> <public key file | ->]...`

Idempotent: re-running changes no file whose content is already right.

1. Check the OS (section 1, decision 30) and that we're root.
2. Add the Caddy and NodeSource apt repos (signed-by keyrings), install the packages in section 2,
   then `npm install -g corepack@<pinned version>` and `corepack enable`. The keys are downloaded
   once into `/etc/apt/keyrings/` (`caddy-stable-archive-keyring.gpg`, `nodesource.gpg`); the
   sources are `/etc/apt/sources.list.d/caddy-stable.list` and `nodesource.list` (the names Caddy's
   and NodeSource's own instructions use, so a repo added by hand is never listed twice), and
   `/etc/apt/preferences.d/shipit-nodejs` pins `nodejs` to NodeSource. A source file shipit didn't
   write is left alone, with a message. The NodeSource line uses NODE_MAJOR from `host.conf`, written
   on the first run. The npm install is skipped when `corepack --version` already prints the pin.
3. Create `ci` (shell `/bin/sh`; on every run, with or without `--ci-key`, decision 63); create
   `/etc/shipit/sites`, `/etc/caddy/sites`, `/var/lib/shipit`, `/srv`, `/var/log/shipit` (root:root,
   0755). An existing `ci` user that shipit didn't create stops setup.
4. Write `/etc/caddy/Caddyfile` (`import /etc/caddy/sites/*.caddy`), validate, reload Caddy (only if
   it changed). Caddy files are always validated as `caddy` (`runuser -u caddy -- caddy validate`):
   validating opens the log files, and run as root it would create them owned by root, breaking the
   next reload. The Caddyfile is replaced only if it's missing, shipit's, or Caddy's package default
   untouched (dpkg's conffile md5); otherwise setup stops and says to move it away.
5. ufw: allow the ports sshd actually listens on (read from `sshd -T`, so a non-22 port doesn't lock
   you out), 80/tcp, 443/tcp and 443/udp; default deny incoming, allow outgoing; enable
   (`ufw --force enable`). fail2ban: enable the `sshd` jail with `backend = systemd`
   (`/etc/fail2ban/jail.d/shipit-sshd.conf`; fail2ban reloaded if it changed).
   unattended-upgrades: enable (`/etc/apt/apt.conf.d/52shipit-auto-upgrades`, decision 29).
6. For each `--ci-key <name> <file>` (repeatable; re-run setup to add a site's key later; the site
   doesn't have to exist yet): the key must be exactly one line, accepted by `ssh-keygen -l -f`, and
   made only of a key type, base64 and an optional comment, so it can't add a second line or its own
   options. Install it in `~ci/.ssh/authorized_keys` as
   `restrict,command="sudo /usr/local/bin/shipit remote <name>" <key> shipit:<name>`, replacing that
   site's previous line and keeping the others. Write `/etc/sudoers.d/shipit-ci` (validated with
   `visudo -cf` on a temp copy first): `ci ALL=(root) NOPASSWD: /usr/local/bin/shipit remote *` plus
   `Defaults:ci env_keep += SSH_ORIGINAL_COMMAND`. The wildcard is safe because a `ci` key can't run
   anything but its forced command, which fixes the arguments, and `remote` validates them.
   The sudoers file is written on every run; `authorized_keys` only when `--ci-key` is given. Every
   `--ci-key` is parsed and its key checked before setup changes anything (decision 62).
7. SSH hardening: write `/etc/ssh/sshd_config.d/10-shipit.conf` (`PasswordAuthentication no`,
   `KbdInteractiveAuthentication no`, `PermitRootLogin prohibit-password`), check it with `sshd -t`,
   install, `systemctl reload ssh`. Done **only** if root has a key in `authorized_keys` and the current
   session logged in with a key (sshd's journal shows `Accepted publickey` for this session); otherwise
   setup skips this step and prints why, so it can never lock you out. "This session" is any ancestor
   of the setup process: the `sshd`/`sshd-session` pid that logged the login is one of them. If the
   journal can't be read, the step is skipped too. `sshd -t -f <temp copy>` checks the drop-in on its
   own (decision 31).
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
deploy of the same site waits, printing "Another deploy or rollback of <name> is running; waiting."
(rollback takes the same lock and prints the same message, decision 61). The lock order
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
      shipped by shipit (`templates/github_known_hosts`) and `StrictHostKeyChecking=yes`. After the
      first deploy succeeds: SSH if the site has a deploy key, else HTTPS (decision 38).
   3. As `<name>-build`, `git fetch --prune` only `refs/heads/*` and `refs/tags/*` into `repo.git`,
      resolve `ref` to a full SHA, and read and validate `shipit.ini` at that commit (section 3),
      including the `site.env` keys. Then, before building:
      - If `site.type` differs from TYPE in `<name>.conf` (a later deploy), refuse with "shipit.ini
        says the site type is <x>, but this site is deployed as <type>. Changing a site's type isn't
        supported."
      - Check `site.domain` and every `site.alias` against every other site's DOMAIN and ALIASES in
        `/etc/shipit/sites/*.conf`. A clash fails the deploy. A first `node`/`nextjs` deploy is given a PORT (decision 39): the lowest
        from 3000–3999 that no `<name>.conf` has, picked at the start of B, under `build.lock`, and
        written to `<name>.conf` next to REPO at once (decision 50). TYPE, DOMAIN and ALIASES are written to `<name>.conf` only in C.2, so the conf
        always describes `current`.
B. **Build** (`build.lock` taken, after the site lock; repo commands run as `<name>-build`)
   1. Root creates `releases/<UTC>-<full sha>` (decision 40) and hands it to `<name>-build`, which
      fills it with `git archive <sha> | tar -x` and pins the commit with
      `git update-ref refs/shipit/<sha> <sha>`, so `git gc` never removes it (5.5). Every build step runs with `umask 027`.
   2. Run install (without secrets), then build (with the env file on stdin). A failure deletes the
      half-built release and leaves the live site untouched. Defaults, and how the commands run:
      decision 41.
   3. `nextjs` only: as `<name>-build`, replace `.next/cache` (the build cache) with a symlink to
      `/var/cache/shipit-<name>` (`rm -rf .next/cache && ln -s ...`), so `next start` can write its
      image and ISR cache (section 6).
   4. Root kills any process `<name>-build` left running (`pkill -KILL -u <name>-build`), then takes
      the release back (`chown -R root:<name>`). `static` only: refuse the release if
      `<root>` contains a symlink pointing outside `<root>`, then set Caddy's ACLs (section 4).
   `build.lock` is released here; the site lock is kept.
C. **Switch** (site lock still held)
   1. Remember where `previous` points, then `previous` → old `current`; `current` → new release (both
      atomic).
   2. Render the Caddy file and unit from the `shipit.ini` of the new `current` (section 5.5) and
      validate both (decision 54) before installing either. The unit goes in first: `daemon-reload`
      if it changed (including `data.dir`), and `systemctl enable` it so the site comes back after a
      reboot (on every deploy: it's idempotent, decision 55). Then reload (never restart) Caddy if
      the Caddy file changed. Then write TYPE, DOMAIN and ALIASES to `<name>.conf`. If rendering,
      validating or installing fails, revert (step 4) and exit non-zero.
   3. Node/Next.js: restart `shipit-<name>` (`nextjs`: stop, `systemctl clean --what=cache`, start, so
      a release never sees another release's cache), then poll `http://127.0.0.1:$PORT$health` with
      `Host: $domain` every second for up to 60 s (decision 56). A failed restart counts as a failed
      health check. Static: nothing restarts; Caddy is reloaded only if its file
      changed in step 2, and otherwise resolves the `current` symlink per request. When the Caddy file
      changes (e.g. `static.root`), requests between step 1 and the reload in step 2 can get a 404, a
      window well under a second. Accepted.
   4. Revert, on a failed health check or a failed render: switch `current` and `previous` back to
      where they pointed before step 1 (so a failed deploy keeps its rollback target), re-render the
      config from the restored release (reload Caddy / `daemon-reload` as needed), restart, delete the
      failed release, exit non-zero ("Deploy failed health check; still serving <old release>.").
      A failed render says "Deploy failed: the new release's config couldn't be installed; still
      serving <old release>." instead (decision 47).
      The restored release is restarted and health-checked after a failed render too (decision 58).
      On a first deploy there's nothing to go back to: stop and disable the unit and delete it
      (`daemon-reload`), remove `current`, the Caddy file (reload Caddy) and the release, and keep
      the users and `<name>.conf` (back to REPO and PORT, decision 57), so running the same deploy
      again starts over; exit non-zero ("First deploy of <name> failed; nothing is served.").
D. **Prune**: delete every release that isn't `current` or `previous`, and its `refs/shipit/<sha>`
   (unless a kept release has the same SHA; any other pin, e.g. from a failed build, goes too).
   Release the site lock and print "Deployed <name>: now serving <release>."

### 5.3 `shipit rollback <name>`

Under the site lock (no `build.lock`: nothing is built): needs a `previous`. Swap `current` and
`previous` atomically, re-render the
Caddy file and unit from the new `current`'s `shipit.ini` (section 5.5; reload Caddy / `daemon-reload`
as needed, and TYPE, DOMAIN and ALIASES in `<name>.conf`), restart the unit (Node/Next.js; `nextjs`
empties its cache as in 5.2 C.3) and health-check it. If validation or the health check fails, swap
back, re-render and restart, and exit non-zero ("Rollback failed health check; still serving
<release>."). Rolling back twice returns to where you started. The next deploy drops whichever release
is then `previous`. Nothing is pruned or deleted: both releases are kept.

- Refused, changing nothing: anything but exactly one valid name ("Usage: shipit rollback <name>"); an
  unknown site (the message of 5.2 A.1); a site whose first deploy never succeeded (no TYPE: "<name>
  has never been deployed successfully, so there's nothing to roll back to."); no `previous`, or one
  that points at `current` or at a missing folder ("<name> has no previous release to roll back
  to.").
- The swap is `previous` first, then `current` (decision 60). Success prints "Rolled back <name>: now
  serving <release>."
- A failed render or validation (including the domain clash check against the other sites as they
  are now) says "Rollback failed: the previous release's config couldn't be installed; still serving
  <release>." instead (as decision 47 does for deploy). Going back always re-renders, restarts and
  health-checks the original `current`; if that fails too, it's printed and rollback still exits
  non-zero (decision 58).

Rollback swaps code only, never data (`/var/lib/shipit-<name>` is untouched). Schema changes, e.g.
SQLite migrations, must stay compatible with the previous release for one version.

### 5.4 `shipit remote <name>` (internal, used only by the `ci` forced command)

`<name>` comes from the key's forced command. Parses `$SSH_ORIGINAL_COMMAND` strictly:
`deploy <name> [<40-hex sha | branch>]` (the ref rule of 5.2) or `rollback <name>`, and the name must
equal the key's `<name>`, so a site's key can't act on another site. Only sites that have completed a
deploy (no first deploys from CI). Anything else: refused.

- The whole string must match one pattern: words separated by single spaces, no leading or trailing
  whitespace, the ref made only of letters, digits and `. _ / -` and then passing `check_ref`
  (decision 64). Tabs, newlines, quotes and shell syntax never match. Refused: "Refused the command
  <quoted command>. This key can only run: deploy <name> [<commit sha or branch>], or rollback
  <name>." An empty command (an interactive login) says "No command given." before the same list.
- Another site's name: "This key belongs to the site <name>, so it can't deploy or roll back <other>."
  This is checked before the site config is read.
- A site without TYPE: "<name> has never been deployed successfully. Its first deploy must be run by
  hand, as root: shipit deploy <repo-url> <name>"; an unknown site gets 5.2 A.1's message.
- `shipit remote` itself takes exactly one valid name; anything else prints "Usage: shipit remote
  <name>. Only the ci user's SSH keys run it, as their forced command."
- The command runs in the same root process (`cmd_deploy <name> [ref]` or `cmd_rollback <name>`,
  decision 65), never with a URL.
- `$SSH_ORIGINAL_COMMAND` is the only value shipit reads from the environment. It's input, parsed as
  above, not a setting.

The two workflows below are also in `examples/deploy.yml` and `examples/rollback.yml` (a unit test
keeps them identical to this section).

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
- `site-static.caddy` — `root * /srv/<name>/current/<root>`, `file_server`, `encode zstd gzip`,
  security headers (decision 44), and the site's `log` snippet. A site's Caddy file is
  `site-log.caddy` (the marker, and a `(shipit-<name>-log)` snippet writing
  `/var/log/shipit/<name>/access.log` with `roll_size 10MiB`, `roll_keep 10` and `format filter`
  cutting query strings), then the site block, then one `site-alias.caddy` block per alias
  (`redir https://<domain>{uri} 308`, same snippet), each rendered on its own (decision 46).
- `site-proxy.caddy` — `reverse_proxy 127.0.0.1:<port>`, `encode zstd gzip`, the headers of
  decision 44, and the same `log` snippet; rendered between `site-log.caddy` and the alias blocks, as
  `site-static.caddy` is.
- `site.service` — `User=<name>`, `Group=<name>`, `WorkingDirectory=/srv/<name>/current`,
  `EnvironmentFile=-/etc/shipit/sites/<name>.env`, `Environment=NODE_ENV=production PORT=<port>`,
  `ExecStart=/bin/sh -c '<start>'`, `Restart=on-failure`, hardening (`NoNewPrivileges`,
  `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, the extras of decision 52,
  `SocketBindAllow=tcp:<port>` with `SocketBindDeny=any`, so a site can't take another site's port
  while it restarts), logs to the journal; `WantedBy=multi-user.target`. With `[data]`,
  `site-data.service` adds `StateDirectory=shipit-<name>` plus one `shipit-<name>/<dir>` per
  `data.dir`, and `StateDirectoryMode=0700`. `nextjs`: `site-nextjs.service` adds
  `CacheDirectory=shipit-<name>`, `CacheDirectoryMode=0700` (decision 51). Installed as
  `/etc/systemd/system/shipit-<name>.service`.
- `sshd.conf` (the drop-in), `sudoers-ci`, `authorized_keys` line (one per site key),
  `fail2ban-sshd.conf` (the jail drop-in), `github_known_hosts` (GitHub's SSH host keys, copied, not
  rendered). The `authorized_keys` template is one key line, so it has no marker; setup writes the
  marker as the file's first line (decision 66).
- `apt-caddy.list`, `apt-nodesource.list` (NODE_MAJOR), `apt-nodejs.pref` (the NodeSource pin),
  `apt-auto-upgrades` (unattended-upgrades on).

Every file rendered from these templates starts with a `# managed by shipit` line (`//` in apt.conf
files): each template that begins a file carries it, but not the parts rendered after
`site-log.caddy` or `site.service` (decisions 46, 51), nor `authorized_keys`, whose marker setup
writes as the file's first line (decision 66). Setup overwrites a file only when one of its first three lines is that marker, or
when it's missing (or, for the Caddyfile, Caddy's untouched default).

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
examples/            deploy.yml, rollback.yml (the workflows of 5.4)
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
| M1 | `shipit.ini` parser + validators | bats (fixtures for every key and error, including an unknown key, a duplicate single-value key, an `[include]` attempt, an unquoted `#` in a value, an invalid `data.dir` (`../x`, `a/b`), `[data]` on a static site, a `node.start` with `\n`, `'` or `%`, a `static.root` of `../x`, a `site.health` with a space, and a ref starting with `-`) |
| M2 | `setup` (incl. SSH hardening, firewall) | bats (golden files for every rendered file) |
| M3 | `deploy` static (done) | bats (golden `site-static.caddy` with the `log` block; URL form with a REPO that differs from the registered one refused; domain/alias clash on a later deploy refused; a changed `site.type` refused; two concurrent deploys of one site run one after the other) |
| M4 | `deploy` node / nextjs + health check + auto-revert + data folder (done) | bats (golden `site-proxy.caddy` and `site.service`) |
| M5 | `rollback` (done) | bats (static, node and nextjs rollbacks re-render from the previous release's `shipit.ini`; rolling back twice returns to the start; a failed health check or a domain clash swaps back; a held site lock makes rollback wait; the previous release's `shipit.ini` is still readable after a force-push and `git gc --prune=now`) |
| M6 | `remote` + CI user + GitHub Actions example (done) | bats (command parsing: site A's key can't deploy or roll back site B, a ref like `--upload-pack=x` is refused; a `--ci-key` file with two lines or key options is refused) |
| M7 | README, CLAUDE.md rewritten (done) | review |

## 9. Decisions

| # | Question | Decision |
|---|---|---|
| 1 | Web server | **Caddy only.** nginx isn't installed. |
| 2 | Site types | **`static`, `node`, `nextjs`.** |
| 3 | Where builds run | **On the VPS, as the site's own build user `<name>-build`**, one build at a time. |
| 4 | Private repos | **Per-site deploy key.** The first deploy prints it with the GitHub URL and exits non-zero; run deploy again after adding it. The first deploy takes the name on the command line (`shipit deploy <repo-url> <name>`), so the key's folder exists before the first fetch. |
| 5 | Secrets | **Edited by hand over SSH** in `/etc/shipit/sites/<name>.env`. No command or CI path for them. |
| 6 | First deploy | **By hand, as root.** CI (`ci` user, `shipit remote`) only redeploys and rolls back registered sites. |
| 7 | SSH hardening | **On**, guarded by the key-login check in 5.1 step 7. |
| 8 | Downtime on Node/Next.js deploy | **Accepted**: a ~1–3 s gap while the unit restarts. No blue/green. |
| 9 | Removing a site | **No command.** README documents the manual steps (stop/disable unit, remove Caddy file and reload, remove `/srv/<name>`, `/etc/shipit/sites/<name>.*`, `/var/lib/shipit-<name>`, `/var/cache/shipit-<name>`, `/var/log/shipit/<name>`, `/var/lib/shipit/<name>.lock`, the site's line in `~ci/.ssh/authorized_keys`, the users `<name>` and `<name>-build`). Warning: deleting `/var/lib/shipit-<name>` deletes the site's data. |
| 10 | Rewrite approach | **Fresh rewrite** on a new branch; keep the old tool's helpers listed in section 7. |
| 11 | Who runs shipit | **Root.** Repo code only ever runs as `<name>-build` (build) or `<name>` (runtime). Running shipit itself as an unprivileged user was considered and rejected: it needs two privilege modes, an extra command and sudo rules for restarts anyway, and the CI path is already limited by the forced command plus strict `shipit remote` parsing. |
| 12 | Repo config format | **`shipit.ini`, in git's config dialect.** It allows comments, is easy to read, adds no dependency (`git` is already installed), and `git config` is a strict, well-specified parser that exits non-zero on bad syntax. Considered: JSON (no comments) and YAML (needs python3 + yq, has YAML 1.1 quirks, and is a bigger parser to run on untrusted input). |
| 13 | Site data | **`/var/lib/shipit-<name>` (0700) via systemd `StateDirectory=`, opt-in with `[data]`, node/nextjs only.** No backups, no Caddy-served folders. Not inside `/srv/<name>`: that tree holds code, the build user owns the release folders and `repo.git`, and releases are deleted on prune. `$STATE_DIRECTORY` is a `:`-joined list when `data.dir` is set; this is documented rather than worked around. |
| 14 | Config follows `current` | **The Caddy file and unit are always rendered from the `shipit.ini` of the release `current` points at**, after every switch, revert and rollback, so rolling back code also rolls back its config. |
| 15 | Renaming a site, changing its type | **The site name (fixed by the first deploy's command line) and the type are fixed after the first deploy; renaming or changing type = remove + deploy.** A later deploy whose `site.type` differs is refused before building, so a rollback never crosses a type change. |
| 16 | CI host key | **CI pins the VPS host key:** setup prints known_hosts lines, CI uses `StrictHostKeyChecking=yes`. `accept-new` and `ssh-keyscan` on the runner were rejected: a fresh runner would trust any host on every run. |
| 17 | Who owns `/srv/<name>` | **Root** (`root:<name>`, 2750), and `releases/` too. Root creates and names release folders, owns the symlinks, and takes each release back after its build; `<name>-build` owns only `repo.git`, `.ssh/`, `home/` and the release being built. Rejected: build-owned `/srv/<name>`, where a build step could repoint `current`/`previous` or rename releases that root then follows. |
| 18 | CI key scope | **One key per site.** `setup --ci-key <name> <key>` puts the site in the forced command (`shipit remote <name>`), and `remote` refuses any other site. Rejected: one shared key, with which any repo could deploy or roll back every site. |
| 19 | Next.js runtime cache | **`CacheDirectory=shipit-<name>`**, linked from `.next/cache` after the build and emptied (`systemctl clean --what=cache`) on every switch, so a rollback never serves pages cached by the newer release. |
| 20 | Logs | **Per-site access logs in `/var/log/shipit/<name>/access.log`, rolled by Caddy; app and Caddy errors in the journal; build output only in the SSH session/Actions log. No logrotate.** |
| 21 | Caddy's access to static sites | **ACLs (`setfacl`) on the served folder only**, set after the build. Rejected: adding `caddy` to group `<name>`, which let Caddy read `repo.git`, the whole release and the env file (so one site's symlink could publish another's), and which a running Caddy only sees after a restart. |
| 22 | Secrets during install | **None: only the build step gets the env file.** Dependencies' install scripts are third-party code. Private npm registries that need a token at install time aren't supported. |
| 23 | Values from `shipit.ini` in rendered files | **Every key has a strict pattern; control characters are never allowed**, because git config turns `\n` into a newline and a value lands in a unit or Caddy file that root installs. |
| 24 | Which GitHub URLs | **`https://github.com/<owner>/<repo>[.git]` only.** Owner: `[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?` (GitHub's user/org rule); repo: `[A-Za-z0-9._-]{1,100}`, not `.` or `..`. Anything else (SSH, other hosts, extra path, query, user info) is refused. |
| 25 | Port allocation | **The lowest port in 3000–3999 that no `<name>.conf` has.** Listening sockets aren't checked: 3000–3999 is kept for shipit's sites. |
| 26 | Keys that don't fit the type | **Refused**, not ignored: `node.start`, `site.health` and `data.dir` on `static`; `static.root` on `node`/`nextjs`. Same reason as unknown keys: a value that does nothing is a mistake. |
| 27 | `ref` check | **`@{` is refused before `git check-ref-format --branch` runs**, because `--branch` expands `@{-N}` inside a repo. |
| 28 | corepack version | **Pinned to 0.36.0** (`COREPACK_VERSION` in `lib/setup.sh`; the latest on npm when M2 was written). Bumped by hand, with a shipit release. setup skips `npm install -g` when `corepack --version` already prints it, and always runs `corepack enable`. |
| 29 | Turning on unattended-upgrades | **A shipit file, `/etc/apt/apt.conf.d/52shipit-auto-upgrades`** (`Update-Package-Lists` and `Unattended-Upgrade` = 1), checked with `apt-config -c <temp copy> dump`. It's read after Debian's `20auto-upgrades`, so it wins without shipit touching that file (which isn't marked as shipit's). Rejected: `dpkg-reconfigure -f noninteractive unattended-upgrades`, which goes through debconf and rewrites `20auto-upgrades`. The package's `50unattended-upgrades` (security origins only) is left as shipped. |
| 30 | OS version check | **`/etc/os-release` is read as data** (only `ID` and `VERSION_ID`, quotes stripped), never sourced. Versions compare number by number (`26.10 >= 26.04`, `27.04 >= 26.10`). Debian's `VERSION_ID` must be a plain integer, Ubuntu's `YY.MM`; a missing `VERSION_ID` (Debian testing/sid) or any other `ID` (including derivatives such as Mint) is refused. |
| 31 | Checking the sshd drop-in | **`sshd -t -f <temp copy>`**, the drop-in on its own as the whole config: it checks the drop-in's syntax and values without depending on the rest of `/etc/ssh`. sshd keeps the first value it reads and Debian's and Ubuntu's `sshd_config` include `sshd_config.d/*.conf` first, so `10-shipit.conf` wins over later drop-ins such as cloud-init's `50-cloud-init.conf`. |
| 32 | ufw defaults | **Deny incoming, allow outgoing**, then allow sshd's ports (each `port N` line of `sshd -T`, as `N/tcp`; any malformed `port` line stops setup before ufw is touched), 80/tcp, 443/tcp and 443/udp, then `ufw --force enable`. Re-running is safe: ufw skips rules it already has. Ports opened by hand are kept. |
| 33 | Caddyfile global options | **Only `admin localhost:2019`** (Caddy's default, written out so the reload path is explicit). No ACME email: Caddy gets certificates without one. |
| 34 | Test seams for setup | **Plain constants in `lib/common.sh`**: `OS_RELEASE` (`/etc/os-release`), `APT_ETC` (`/etc/apt`), `CADDY_ETC` (`/etc/caddy`), `LOG_ROOT` (`/var/log/shipit`), `SSH_ETC` (`/etc/ssh`: the drop-in folder and host keys), `FAIL2BAN_ETC` (`/etc/fail2ban`) and `ROOT_HOME` (`/root`), next to `SHIPIT_ETC`, `SHIPIT_VAR` and `SRV_ROOT`. Tests point them at a temp dir and stub `apt-get`, `systemctl`, `ufw`, `sshd`, `runuser`, `caddy`, `journalctl`, `dpkg-query`, `chown` and the rest through `PATH`. |
| 35 | Test seams for deploy | **Only `SYSTEMD_DIR` and `CACHE_ROOT` (M4, decision 59), and the health check's timing.** Paths come from the existing constants (`SRV_ROOT`, `SHIPIT_ETC`, `SHIPIT_VAR`, `CADDY_ETC`, `LOG_ROOT`; `github_known_hosts` is found through `SHIPIT_TEMPLATES`). Tests point `https://github.com/<owner>/<repo>` at a local repo with `url.<path>.insteadOf` in the build user's `~/.gitconfig` (its HOME is `$SRV_ROOT/<name>/home`), stub `runuser` to run the command as themselves, and prepend their stubs to `BUILD_PATH` (a plain constant in `lib/deploy.sh`). |
| 36 | Site users | **`<name>`**: `useradd --system --user-group`, home `/nonexistent`, shell `/usr/sbin/nologin`. **`<name>-build`**: `--system`, primary group `<name>` (no group of its own), home `/srv/<name>/home`, `nologin`. A user is shipit's when its GECOS field is exactly `shipit site <name>` / `shipit build <name>`; an existing user with either name and any other GECOS refuses the first deploy before anything is created. Existing shipit users are kept, so a rerun resumes. |
| 37 | Default branch, ref resolution | **The remote's `HEAD`, read with `git ls-remote --symref <url> HEAD`** each time the ref is left out (its name must pass `check_ref`), then used as `refs/heads/<branch>`. Any ref resolves in `repo.git` with `rev-parse --verify --end-of-options <ref>^{commit}`, so a branch, a tag or the SHA of a fetched (or pinned) commit works. |
| 38 | Transport after the first deploy | **SSH if `/srv/<name>/.ssh/id_ed25519` exists, else HTTPS**, without probing. Before the first success, a repo that answers over HTTPS is public and a key left by an earlier try is deleted, so a public site never switches to SSH. A public repo that later turns private: create the key as `<name>-build` (`ssh-keygen -t ed25519 -N '' -f /srv/<name>/.ssh/id_ed25519`) and add it to GitHub. SSH runs as `ssh -i <key> -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=<templates>/github_known_hosts -o GlobalKnownHostsFile=/dev/null`; the key's comment is `shipit-<name>`. |
| 39 | PORT for static sites | **None.** Only `node`/`nextjs` sites get a PORT (M4); `conf_parse` already allows a static site without one. |
| 40 | Release folder name | **`<date -u +%Y%m%dT%H%M%SZ>-<full sha>`**, so names sort by time. Root makes it with `mkdir` (no `-p`); if the name is taken (the same commit within one second), it waits a second and tries once more. `current` and `previous` are relative links (`releases/<dir>`); a link that isn't one is refused rather than followed. |
| 41 | Install and build | **Defaults are read from the commit as data**: `git ls-tree --name-only <sha>` for lockfiles (`package-lock.json` → `npm ci`, else `pnpm-lock.yaml` → `pnpm install --frozen-lockfile`, else `yarn.lock` → `yarn install --immutable`, else `package.json` → `npm install`, else no install) and `git show <sha>:package.json` piped to `jq` for `.scripts.build`. Each command runs as `runuser -u <name>-build -- env -i HOME=/srv/<name>/home PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8`, with `umask 027`, as `sh -c "<cmd>"` in the release. Install's stdin is `/dev/null`; build's is the env file, read by a small sh wrapper that looks the command up first, exports it, and runs the build with stdin from `/dev/null`. Root only parses the env file to check it (bash, no export, nothing run with its values). |
| 42 | Env file format | **`KEY=value` lines (KEY `^[A-Za-z_][A-Za-z0-9_]*$`, at the start of the line), blank lines and `#`/`;` comments.** The value is literal, except that spaces and tabs around it, then one pair of matching `"` or `'` around all of it, are removed; no escapes, no `export`, no line continuations. That's the part of systemd's `EnvironmentFile=` syntax both read the same way. Any other line fails the deploy, naming the line, before the build. |
| 43 | Symlinks in a static root | **Every `find -P <root> -type l` is resolved by `path_resolve`** (bash and `readlink`, like `realpath -m`, which macOS lacks; more than 40 links is a loop and refused) and must stay inside `<root>`. `<root>` itself, and every folder on the way to it, must not be a symlink. The check runs after root takes the release back, so the build user can't change the tree meanwhile. |
| 44 | Static site headers | **`X-Content-Type-Options nosniff`, `Referrer-Policy strict-origin-when-cross-origin`, `X-Frame-Options SAMEORIGIN`, `-Server`.** No HSTS: browsers keep it for its max-age, after the site's config (or the site) has changed, and Caddy already redirects HTTP to HTTPS. No CSP: it depends on the site. |
| 45 | What the access log filter cuts | **The query string of `request>uri`, `request>headers>Referer` and `resp_headers>Location`** (Caddy's `regexp` field filter, `\?.*$` → empty). An alias redirect's `Location` repeats the request's query string, and same-site `Referer`s carry the previous page's. |
| 46 | Variable-length alias blocks | **Rendered one at a time and concatenated**: `site-log.caddy`, then the type's block (`site-static.caddy`), then `site-alias.caddy` per alias, each through `render`. The snippet is named `shipit-<name>-log`, because all site files share one Caddyfile and a snippet name can't repeat. Only `site-log.caddy` carries the marker line (it comes first). The site file is validated on its own (`caddy validate`, as `caddy`). |
| 47 | Render failure message | **"Deploy failed: the new release's config couldn't be installed; still serving <release>."** (the health-check message would be wrong). If re-rendering the restored release fails too, that's printed as well, and the deploy still exits non-zero. A first deploy prints "First deploy of <name> failed; nothing is served." either way. |
| 48 | URL form for a known site | **Matches when it names the same `<owner>/<repo>`**, ignoring letter case (GitHub does) and `.git`. REPO keeps the URL of the first deploy. |
| 49 | Waiting for `build.lock` | **Prints "Another site is building; waiting."** (it can only be another site: the site lock is held). |
| 50 | When a first deploy gets its PORT | **At the start of B, right after `build.lock` is taken, and written to `<name>.conf` (REPO and PORT; valid by section 4's rules) before the lock is let go.** Every deploy takes `build.lock`, so two first deploys of different sites can't pick the same port, and no extra lock is needed. A failed first deploy keeps its PORT, so a rerun gets the same one. Later deploys keep PORT; only a site with no PORT yet gets one. |
| 51 | The unit's variable parts | **Rendered one at a time and concatenated, as for the Caddy file (decision 46)**: `site.service` (marker, `[Unit]`, `[Install]`, then `[Service]` last), then `site-data.service` when `data.dir` is set (`STATE_DIRS` is computed from the validated `data.dir` values: `shipit-<name> shipit-<name>/<dir>...`), then `site-nextjs.service` for `nextjs`. The parts after the first only add lines to `[Service]`, which is why `[Install]` comes before it (systemd doesn't mind the order). `render` stays the only templating. |
| 52 | Extra hardening in the unit | **`PrivateDevices`, `ProtectKernelTunables`, `ProtectKernelModules`, `ProtectControlGroups`, `RestrictSUIDSGID` and `LockPersonality`**, on top of section 6's list. Nothing that breaks Node: no `MemoryDenyWriteExecute` (V8 JIT-compiles), no syscall filter. |
| 53 | A site without an env file | **`EnvironmentFile=-...`**: the unit starts without one. A site that needs secrets lists them as `site.env`, and deploy fails before building when they're missing, so the `-` never hides a missing secret that shipit.ini names. |
| 54 | Checking the unit | **`systemd-analyze verify <temp>/unit/shipit-<name>.service`** (verify needs a unit's name; it doesn't need the user or the working directory to exist), and an installed `shipit-<name>.service` or `<name>.caddy` without the marker is refused, not replaced. The Caddy file and the unit are both checked before either is installed. |
| 55 | `systemctl enable` | **On every deploy, revert and rollback**, not only the first: it's idempotent and keeps no state about which deploy is the first. |
| 56 | Health check | **`curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Host: <domain>" http://127.0.0.1:<port><health>`, every second until `health_ok` accepts the status or 60 s have passed** (`HEALTH_TIMEOUT`, `HEALTH_INTERVAL`, `HEALTH_MAX_TIME` in `lib/deploy.sh`; tests shorten them). Redirects aren't followed, so `/` redirecting to a login page passes without `site.health`. On failure it prints the URL, the last status (or "gave no answer") and `journalctl -u shipit-<name>`. `site_restart_and_check` (restart + health check) is shared by deploy, revert and rollback. |
| 57 | What a failed first deploy keeps | **The users and `<name>.conf` with REPO and PORT**: TYPE, DOMAIN and ALIASES (written in C.2) are removed again, so the rerun is a first deploy (access probe, name check) and the domain isn't held. The unit is stopped, disabled and deleted (then `daemon-reload`), not only stopped and disabled, so no unit is left pointing at a missing `current`. |
| 58 | Restart after a failed render | **The restored release is restarted and health-checked whatever made the deploy fail**, as C.4 says, even though a failed render never restarted the new one (a short gap). If that fails too, it's printed and the deploy still exits non-zero. |
| 59 | Test seams for M4 | **`SYSTEMD_DIR` (`/etc/systemd/system`) and `CACHE_ROOT` (`/var/cache`, the `.next/cache` link's target) in `lib/common.sh`.** No `STATE_ROOT`: shipit never touches `/var/lib/shipit-<name>`; systemd makes it. |
| 60 | Rollback's swap order | **`previous` → old `current` first, then `current` → old `previous`**, as deploy's C.1 orders them. A crash in between leaves `current` and the config rendered from it unchanged (the site keeps serving what it served), with both links on the same release; rollback treats a `previous` equal to `current` as no `previous`. The other order would leave `current` on the older release with the newer release's config until something re-rendered it. Going back after a failure uses the same order. |
| 61 | Waiting for the site lock | **One message for deploy and rollback: "Another deploy or rollback of <name> is running; waiting."** The waiting command can't know which of the two holds the lock. |
| 62 | `--ci-key` input | **Parsed and checked before anything changes** (even before the OS check), so a bad key leaves the VPS as it was. Only `--ci-key <name> <file \| ->` pairs; anything else prints "Usage: shipit setup [--ci-key <name> <public key file \| ->]...". A site may be given once per run, and only one key may come from stdin (`-`). The file must be one line (one trailing newline allowed; any second line, even an empty one, is refused) matching `^<type> <base64>( <printable ASCII>)?$`, with `<type>` one of `ssh-ed25519`, `ecdsa-sha2-nistp256/384/521`, `sk-ssh-ed25519@openssh.com`, `sk-ecdsa-sha2-nistp256@openssh.com` and `ssh-rsa` (accepted: older CI setups still use RSA keys, and `ssh-keygen -l` checks the key itself), and `<base64>` `[A-Za-z0-9+/]+={0,2}`. Anything before the type (options such as `restrict` or `command="..."`) doesn't match. Only `<type> <base64>` is kept: written to a temp file, it must pass `ssh-keygen -l -f`, and it's what goes into the line; the user's comment is dropped and `shipit:<name>` takes its place. |
| 63 | The `ci` user | **Created by every `setup` run**, so adding a key later only touches `authorized_keys`: `useradd --system --user-group --no-create-home --home-dir /home/ci --shell /bin/sh --password '*' --comment 'shipit ci' ci`. It's shipit's when its GECOS is exactly `shipit ci` (as decision 36); any other `ci` user stops setup. Password field `*`: no password matches it, and unlike `!` sshd doesn't treat it as locked when `UsePAM` is off, so key logins work either way. `/home/ci` and `/home/ci/.ssh` are `root:root` 0755 and `authorized_keys` `root:root` 0644 (sshd's `StrictModes` accepts root-owned files): ci owns nothing, so even code running as ci couldn't change its forced commands, and root never writes into a folder another user controls. `/etc/sudoers.d/shipit-ci` (0440) is also written on every run, checked with `visudo -cqf` on the temp copy (with `-f`, visudo doesn't check owner or mode). Seams: `CI_HOME` and `SUDOERS_DIR` in `lib/common.sh`; `SHIPIT_BIN` (`/usr/local/bin/shipit`, where install.sh links it) is a plain constant in `lib/setup.sh`. |
| 64 | Parsing `$SSH_ORIGINAL_COMMAND` | **One anchored pattern per command**: `^deploy ([a-z][a-z0-9-]*)( ([A-Za-z0-9._/-]+))?$` or `^rollback ([a-z][a-z0-9-]*)$`, then the name must equal the key's and the ref must pass `check_ref` (so `-x` and `--upload-pack=x` are refused, and so is anything git's ref rules refuse). The ref's characters are a subset of what `check_ref` allows, so a branch with other characters can be deployed by hand but not from CI; CI passes `$GITHUB_SHA` anyway. A refused command is echoed with bash's `${cmd@Q}`, so control characters can't reach the CI log raw. |
| 65 | How `remote` runs the command | **In the same process**: `lib/remote.sh` sources `lib/rollback.sh` (and through it `lib/deploy.sh`) and calls `cmd_deploy <name> [ref]` or `cmd_rollback <name>`, as the dispatcher would. One root process, no second argument parsing, and the arguments passed are the validated ones. |
| 66 | `authorized_keys` updates | **Rendered line by line, merged, installed through `install_if_changed` (0644)**: the first line is the marker `# managed by shipit: one line per site, written by shipit setup --ci-key <name> <key>.`; a line ending in ` shipit:<name>` is that site's and is replaced in place (a new site's line goes last); every other line, including ones added by hand, is kept as it was. An existing `authorized_keys` without the marker stops setup. Re-running with the same key changes nothing. |
| 67 | No `site.name` in `shipit.ini` | **The name comes only from the command line** (`shipit deploy <repo-url> <name>`, then `shipit deploy <name>`), and `REPO` in `<name>.conf` ties it to its repo, so a `site.name` key said nothing new and could only disagree with it (and needed two refusal messages). `site.name` is now an unknown key, refused like any other (decision 26), so a `shipit.ini` written for v1.0.0 fails with "shipit.ini has unknown keys: site.name. …" until the line is deleted. A breaking change for those files. |
