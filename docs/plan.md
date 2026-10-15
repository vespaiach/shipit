# shipit — plan

A small bash tool that does five things:

1. `shipit setup` — prepare a VPS for atomic, symlink-based deploys.
2. `shipit deploy <name> [ref]` (or `<repo-url> <name> [ref]`) — build a website from GitHub and switch to it.
3. `shipit rollback <name>` — go back exactly one version.
4. `shipit delete <name>` — delete a site and its data, after asking (5.6).
5. `shipit uninstall` — remove shipit, every site and its data, after asking (5.7).

Every command runs by hand over SSH, and only a site's first deploy, `delete` and `uninstall` ask questions (`ssh -t`, or piped
answers; decision 69). Several sites share one VPS.

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
| Remote via SSH | No command prompts, except a site's first deploy (shipit.ini and env file, 5.2 A.2b and A.2c), which reads its answers from stdin and refuses when there's none. Exit status 0 = success, non-zero = failure, so a script over SSH sees failures. There is no CI path (decision 68). |
| Site config on the server | Each site has a `shipit.ini` in `/srv/<name>/config/`, in git's config dialect, read with `git config` by `deploy` only (section 3, decision 69). The first deploy asks for it. |

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
| `sudo` | Lets the admin run `sudo shipit`. Minimal images may lack it. |
| (already present) `util-linux` (`flock`), `systemd` | Locks, services. |

## 3. Site config: `shipit.ini`

A site's `shipit.ini` is a file on the server, `/srv/<name>/config/shipit.ini` (root:root, mode 600, in a
root-only folder; section 4), not in the repo. A site's first deploy asks for it (5.2 A.2b) and every
later deploy reads it again, so an edit takes effect on the next deploy. Only `deploy` reads it: revert
and rollback never read, restore or apply it (5.5). The site's name isn't in it: it comes from the
command line on the first deploy (decision 67).

```ini
# shipit.ini
[site]
domain = blog.example.com
alias = www.blog.example.com
type = nextjs
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
| `site.env` | no, repeatable | A key that must exist in the site's env file on the server; deploy fails, naming the missing ones, if any are absent. One per line. Must match `^[A-Za-z_][A-Za-z0-9_]*$`. |
| `node.install` | no | Default: picked by lockfile — `npm ci` / `pnpm install --frozen-lockfile` / `yarn install --immutable`. Runs without the site's secrets (see below). Any non-empty command line without control characters: it runs as `<name>-build` and never lands in a rendered file. |
| `node.build` | no | Default: `npm run build` if `package.json` has a `build` script, else nothing. Same rule as `node.install`. |
| `node.start` | `node`: yes; not for `static` | Command that starts the server. It must listen on `$PORT`. `nextjs` default: `./node_modules/.bin/next start -p $PORT` (`next` isn't on the unit's PATH). It's written into the unit's `ExecStart=`, so a newline or other control character, `'`, `%` or `\` is rejected; systemd expands `$VAR` itself, so `$PORT` works. |
| `static.root` | `static`: yes | Folder (relative to the release) Caddy serves. Must match `^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$`, with no `.` or `..` segment (so never the release itself, which holds the whole repo). Not for `node`/`nextjs`. A `static` site may still have `node.install`/`node.build` (e.g. Vite, `next export`). |
| `data.dir` | no, repeatable | A subfolder of the site's data folder (section 4), matching `^[a-z0-9][a-z0-9_-]{0,63}$` (no `/`, no `..`). Each becomes an extra `StateDirectory=shipit-<name>/<dir>` in the unit, so systemd creates it with the right owner. Without any `data.dir`, no data folder is created: `git config` doesn't report an empty `[data]` section, so a site that keeps a single SQLite file still names a folder (e.g. `dir = db`). Rejected for `site.type = static` (no process to write to it). |

Parsing rules:
- `shipit.ini` is read by root from `/srv/<name>/config/shipit.ini`, parsed in one pass of
  `git config -f <file> --no-includes -z --list` (`-z`: NUL-separated `key\nvalue` entries, so a value
  can't fake extra lines). It is never sourced. A syntax error fails with its line number. A repo's own
  `shipit.ini`, if it has one, is never read.
- `--no-includes` is always passed, so an `[include]` can't make the parser read other files.
- Only the sections `site`, `node`, `static` and `data` are allowed. Unknown sections or keys are
  rejected (checked against `--list`, all named in one message), so a typo like `domian` fails the
  deploy instead of being ignored. Subsections (`[site "x"]`) are unknown keys too. So is a key that
  doesn't fit `site.type` (marked in the table): it would otherwise be silently ignored. `site.health` was
  removed (decision 69), so it is an unknown key too.
- Every value is a string and is validated before use (kept from the old tool). git config turns
  escapes like `\n` in a value into real characters, so each key has its own pattern and control
  characters are never allowed. A key without a value (`type` alone) or with an empty one is rejected.
  A single-value key given more than once is rejected; only `site.alias`, `site.env` and `data.dir` may
  repeat, and none of them may repeat a value.
- Defaults applied by the parser: `node.start` for `nextjs`. The `node.install` and `node.build`
  defaults need the repo (lockfile, `package.json`), so the build step picks them.
- Validation, including the domain clash check (5.2 A.3), runs on every deploy: before the build (5.2
  A.3) and again before the render (5.2 C.2), so a value never reaches a unit or Caddy file unchecked
  against the other sites as they are now. The file is the admin's, but a typo must still be refused.

Quirks to know when writing `shipit.ini`:
- `#` and `;` start a comment even in the middle of a value, so values containing them must be quoted,
  e.g. `start = "node server.js --tag=#1"`.
- Section and key names are case-insensitive. They're documented, and should be written, in lowercase.

Secrets are **never** in the repo. They live on the server in `/etc/shipit/sites/<name>.env`
(`KEY=value` lines, mode 600 `root:root`, format in decision 42), edited by the admin over SSH, or
entered at the first deploy's prompt (5.2 A.2c). The
service gets them via `EnvironmentFile=-` (the `-`: a site that needs no secrets needs no file,
decision 53), which systemd reads as root before switching to `<name>`, so neither site user can read
the file. Root passes it to the build step on stdin. The install step
doesn't get it, so dependencies' install scripts never see secrets; a private npm registry that needs
a token at install time isn't supported.

## 4. Server layout

```
/etc/shipit/host.conf                 NODE_MAJOR, written once by setup
/etc/shipit/sites/<name>.conf         REPO, TYPE, DOMAIN, ALIASES, PORT (written by deploy); root, 0644
/etc/shipit/sites/<name>.env          secrets, edited by the admin (a first deploy can create it, 5.2 A.2c); root:root, 600
/etc/caddy/Caddyfile                  managed: global options + `import /etc/caddy/sites/*.caddy`
/etc/caddy/sites/                     root:root, 0755 (setup)
/etc/caddy/sites/<name>.caddy         managed, one per site
/etc/systemd/system/shipit-<name>.service   node/nextjs sites only
/srv/<name>/                          root:<name>, mode 2750
  home/                               home of <name>-build (npm cache); <name>-build, mode 700
  .ssh/                               deploy key (private repos), <name>-build, mode 700
  repo.git/                           bare repo, fetched each deploy; <name>-build, mode 700
  config/                             root:root, mode 700 (00700: not setgid)
    shipit.ini                        the site's config (section 3); root:root, 600
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
/var/lib/shipit/<name>.lock           site lock, held for the whole deploy (A–D), rollback and delete
```

`<name>.conf` describes what the last deploy applied (rollback doesn't change it). It is `KEY=value` lines (`ALIASES` space-separated), blank lines and `#` comments; it's
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
is group-readable: the env file is root-only, and the data and cache folders are 0700. `config/` is
root-only too (00700, five digits, so `/srv/<name>`'s setgid bit isn't inherited): neither site user can
read or change `shipit.ini`, and it belongs to no release.

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
- Root runs `shipit` (directly, or via `sudo`).

## 5. Commands

### 5.1 `shipit setup`

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
3. Create `/etc/shipit/sites`, `/etc/caddy/sites`, `/var/lib/shipit`, `/srv`, `/var/log/shipit` (root:root,
   0755).
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
6. Removed (decision 68).
7. SSH hardening: write `/etc/ssh/sshd_config.d/10-shipit.conf` (`PasswordAuthentication no`,
   `KbdInteractiveAuthentication no`, `PermitRootLogin prohibit-password`), check it with `sshd -t`,
   install, `systemctl reload ssh`. Done **only** if root has a key in `authorized_keys` and the current
   session logged in with a key (sshd's journal shows `Accepted publickey` for this session); otherwise
   setup skips this step and prints why, so it can never lock you out. "This session" is any ancestor
   of the setup process: the `sshd`/`sshd-session` pid that logged the login is one of them. If the
   journal can't be read, the step is skipped too. `sshd -t -f <temp copy>` checks the drop-in on its
   own (decision 31).
8. Removed (decision 68).

Bootstrap from your laptop:
```bash
ssh root@vps 'curl -fsSL https://github.com/<you>/shipit/archive/refs/tags/v1.0.0.tar.gz | tar -xz && cd shipit-1.0.0 && ./install.sh'
ssh root@vps 'shipit setup'
```

### 5.2 `shipit deploy <name> [ref]` / `shipit deploy <repo-url> <name> [ref]`

`ref` defaults to the repo's default branch. A ref is a 40-hex SHA or a
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
      root-owned `/srv/<name>` skeleton (section 4, `config/` included) and `/var/log/shipit/<name>/`
      (caddy:caddy, 0750; every deploy re-checks it, idempotently), and write `<name>.conf` with REPO
      only. A rerun of the same command resumes; another repo can't claim the name meanwhile.
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
   2b. **`shipit.ini`** (`deploy_ini`), after 2 and before 3. If `/srv/<name>/config/shipit.ini` exists,
      nothing. If it's missing and the site never deployed (no TYPE in `<name>.conf`: a first deploy,
      or the rerun of one that stopped before the file was saved), ask for it on stdin, then save it
      root-only (mode 600) and print "Saved <file>. Edit it to add aliases, site.env or node.install; the
      next deploy applies them." If it's missing for a site that deployed before, refuse without
      asking (a prompt would forget its aliases, env keys and data folders): "<file> is missing, and
      <name> was deployed before, so shipit won't guess its settings. Put the file back (the keys are
      in the README), then run the deploy again." If the input ends while asking (no terminal, `ssh`
      without `-t`, Ctrl-D), refuse with "There's no <file> and nothing to ask. Run the deploy in a
      terminal (ssh -t), or write the file by hand (the keys are in the README), then run the same
      command again." The site stays registered, so the same command resumes (A.1). The questions go to
      stderr, one answer per line from stdin, in this order; each answer is checked as section 3 says
      and asked again until it's accepted (control characters are refused), and a blank answer to an
      optional question leaves its key out of the file:
      1. `Domain (for example blog.example.com):`
      2. `Site type (static, node or nextjs):`
      3. static: `Folder Caddy serves, inside the release (for example dist):` (required).
      4. node, nextjs: `Build command (Enter for the default):` (optional: `node.build`).
      5. node, nextjs: `Start command; it must listen on $PORT (for example node server.js):`
         (`node.start`; required for `node`. For `nextjs` the prompt reads `Start command; it must
         listen on $PORT (for example node server.js; Enter for the default):` and a blank answer is
         fine).
      6. node, nextjs: `Data sub-folder the site can write to, kept across deploys (for example
         uploads; Enter for none):`, then `Another data sub-folder (Enter when done):` until a blank
         answer; a repeated name is kept once, not refused (each is a `data.dir`, under
         `/var/lib/shipit-<name>/`).

      Not asked, so added by editing the file: aliases, `site.env`, `node.install`. Piped answers work:
      `printf 'docs.example.com\nstatic\ndist\n' | shipit deploy <url> docs`. Running out of input
      at one of these questions is the no-input refusal above, so a node site's piped answers end
      with a blank line for the data sub-folders.
   2c. **Env file** (`deploy_env`), right after 2b and before 3 (so that A.3's env checks see the
      file). Only for a site that never deployed (no TYPE) and has no `/etc/shipit/sites/<name>.env`
      yet. It prints "Environment variables for <name>, saved in <env file> (root-only, never in the
      repo). Enter KEY=VALUE, one per line, and /q when done." and asks `KEY=VALUE (/q when done):`
      until the answer is exactly `/q` or the input ends (so piped answers need no `/q`, and a deploy
      with no terminal skips this step). A line is split at the first `=`, so a value may hold more
      `=`, spaces, `#` or `/q`, and may be empty. A line with no `=` is refused ("Write it as
      KEY=VALUE."), as is a name that isn't `^[A-Za-z_][A-Za-z0-9_]*$` ("Invalid name '<x>': use
      letters, digits and _, not starting with a digit.") or a line with a control character ("A value
      can't contain a control character."), and it is asked again. A repeated name isn't checked: the
      later value replaces the earlier one in its place. Values are typed visible (they show in the
      terminal and its scrollback). The pairs are kept in memory and written once at the end, through a
      temp file in `/etc/shipit/sites/` and a rename (root:root, mode 600, never a command line or
      the world-readable temp folder), so an interrupted run saves nothing and the rerun asks again.
      It prints "Saved <env file> with: <NAMES>. Edit it to change a value; the next deploy uses it."
      With no pairs there's no file (decision 53). Later deploys never ask. Entering a name doesn't
      add `site.env` to `shipit.ini`: add it by hand to make a deploy fail when the key goes missing.
   3. As `<name>-build`, `git fetch --prune` only `refs/heads/*` and `refs/tags/*` into `repo.git`,
      resolve `ref` to a full SHA, and load and validate the site's `/srv/<name>/config/shipit.ini`
      (section 3; the repo's own files aren't read for config), including the `site.env` keys. A bad
      file stops the deploy with "Fix <file>, then run the deploy again." Then, before building:
      - If `site.type` differs from TYPE in `<name>.conf` (a later deploy), refuse with "shipit.ini
        says the site type is <x>, but this site is deployed as <type>. Changing a site's type isn't
        supported."
      - Check `site.domain` and every `site.alias` against every other site's DOMAIN and ALIASES in
        `/etc/shipit/sites/*.conf`. A clash fails the deploy. A first `node`/`nextjs` deploy is given a PORT (decision 39): the lowest
        from 3000–3999 that no `<name>.conf` has, picked at the start of B, under `build.lock`, and
        written to `<name>.conf` next to REPO at once (decision 50). TYPE, DOMAIN and ALIASES are written to `<name>.conf` only in C.2, so the conf
        describes what the last deploy applied.
B. **Build** (`build.lock` taken, after the site lock; repo commands run as `<name>-build`)
   1. Root creates `releases/<UTC>-<full sha>` (decision 40) and hands it to `<name>-build`, which
      fills it with `git archive <sha> | tar -x`. Every build step runs with `umask 027`.
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
   2. Check the hostnames against the other sites again (they may have changed during the build), render
      the Caddy file and unit from the `shipit.ini` loaded in A.3 (section 5.5) and validate both
      (decision 54) before installing either. The unit goes in first: `daemon-reload`
      if it changed (including `data.dir`), and `systemctl enable` it so the site comes back after a
      reboot (on every deploy: it's idempotent, decision 55). Then reload (never restart) Caddy if
      the Caddy file changed. Then write TYPE, DOMAIN and ALIASES to `<name>.conf`. If rendering,
      validating or installing fails, revert (step 4) and exit non-zero.
   3. Node/Next.js: restart `shipit-<name>` (`nextjs`: stop, `systemctl clean --what=cache`, start, so
      a release never sees another release's cache), then poll `http://127.0.0.1:$PORT/` with
      `Host: $domain` every second for up to 60 s, passing on any status below 500 (decision 56). A
      failed restart counts as a failed health check. Static: nothing restarts; Caddy is reloaded
      only if its file changed in step 2, and otherwise resolves the `current` symlink per request. When the Caddy file
      changes (e.g. `static.root`), requests between step 1 and the reload in step 2 can get a 404, a
      window well under a second. Accepted.
   4. Revert, on a failed health check or a failed render: switch `current` and `previous` back to
      where they pointed before step 1 (so a failed deploy keeps its rollback target), re-read
      `<name>.conf` (what was last applied), restart the restored release and health-check it, delete
      the failed release, exit non-zero ("Deploy failed health check; still serving <old release>.").
      Revert installs and restores no config: whatever step 2 installed stays, and `shipit.ini` is
      untouched, so if the config was what broke the site the old release can fail its health check
      too ("<old release> didn't come back up either; fix the error above."); fix `shipit.ini` and
      deploy again. A failed render says "Deploy failed: the new release's config couldn't be
      installed; still serving <old release>." instead (decision 47); nothing is installed before
      everything validates.
      The restored release is restarted and health-checked after a failed render too (decision 58).
      On a first deploy there's nothing to go back to: stop and disable the unit and delete it
      (`daemon-reload`), remove `current`, the Caddy file (reload Caddy) and the release, and keep
      the users, `<name>.conf` (back to REPO and PORT, decision 57), `config/shipit.ini` and the env
      file, so running the same deploy again starts over without asking again; exit non-zero
      ("First deploy of <name> failed; nothing is served.").
D. **Prune**: delete every release that isn't `current` or `previous`.
   Release the site lock and print "Deployed <name>: now serving <release>."

### 5.3 `shipit rollback <name>`

Under the site lock (no `build.lock`: nothing is built): needs a `previous`. Swap `current` and
`previous` atomically, restart the unit (Node/Next.js; `nextjs` empties its cache as in 5.2 C.3) and
health-check it, polling `/` of the port and domain in `<name>.conf` as 5.2 C.3 does. Rollback never
reads, restores or applies `shipit.ini` (5.5): it renders no config, validates no config, reloads
neither Caddy nor systemd and doesn't touch `<name>.conf`, so it works even if `shipit.ini` is invalid
or gone, and a static site's rollback is just the swap. If the health check fails, swap back, restart
the original `current`, and exit non-zero ("Rollback failed health check; still serving <release>.").
Rolling back twice returns to where you started. The next deploy drops whichever release
is then `previous`. Nothing is pruned or deleted: both releases are kept.

- Refused, changing nothing: anything but exactly one valid name ("Usage: shipit rollback <name>"); an
  unknown site (the message of 5.2 A.1); a site whose first deploy never succeeded (no TYPE: "<name>
  has never been deployed successfully, so there's nothing to roll back to."); no `previous`, or one
  that points at `current` or at a missing folder ("<name> has no previous release to roll back
  to.").
- The swap is `previous` first, then `current` (decision 60). Success prints "Rolled back <name>: now
  serving <release>."
- Going back after a failure restarts and health-checks the original `current`; if that fails too,
  it's printed and rollback still exits non-zero (decision 58). A failed link switch says "Rollback
  failed: switching the links failed; still serving <release>."

Rollback swaps code only, never config or data (`/var/lib/shipit-<name>` is untouched). Schema
changes, e.g. SQLite migrations, must stay compatible with the previous release for one version.

### 5.4 Removed

`shipit remote`, the `ci` user and the GitHub Actions workflows were removed (decision 68). The number is kept so that references to 5.5 and later stay valid.

### 5.5 Config is applied by deploy only

The Caddy file and unit are rendered from the site's `/srv/<name>/config/shipit.ini` (section 3) by
`deploy` alone, in C.2, after the file was loaded and validated in A.3 and the hostnames were checked
against the other sites once more. An unchanged config touches nothing (`install_if_changed`), and a
changed one is written, reloaded and reported ("Wrote <file> and reloaded Caddy."), so there's no
separate "has the config changed" step. Revert and rollback render and restore nothing: they swap code
links, restart and health-check, using only TYPE, DOMAIN and PORT from `<name>.conf`, which records what
the last deploy applied. Two consequences, documented rather than engineered around:
- A deploy whose **config** breaks the site (say a bad `node.start`): revert restores the old code, but
  the new unit stays installed, so the old release can fail its health check too. Fix `shipit.ini` and
  deploy again. A deploy whose config fails validation or install is still safe: nothing is installed
  before everything validates.
- Rolling back across a `static.root` change leaves Caddy serving the new root inside the older release,
  which may not have it (404). Put `static.root` back and deploy the old ref instead. Rollback doesn't
  re-run the static symlink and ACL checks against a different root.

### 5.6 `shipit delete <name>`

Deletes a site and everything shipit keeps for it (decision 70).

1. Refused, changing nothing: anything but exactly one valid name ("Usage: shipit delete <name>"); an
   unknown site (the message of 5.2 A.1), before asking and before the lock.
2. Confirm, before the site lock (so a deploy isn't held up while the admin types): print on stderr
   "This deletes the site <name> (<domain>): its releases, repo, shipit.ini, env file, Caddy file,
   unit, cache and logs, and the users <name> and <name>-build. It can't be undone." (` (<domain>)` only
   if the site has one; when `/var/lib/shipit-<name>` exists, the sentence ends ", and its data in
   /var/lib/shipit-<name>. It can't be undone, and shipit keeps no backup: copy the data first if you
   may need it."), then ask `Type <name> to delete it:` and read one line from stdin. Only the exact
   name goes on (no spaces stripped). No input: "Nothing was deleted: there was no answer. Run it in a
   terminal (ssh -t), or pipe the name: echo <name> | shipit delete <name>". Any other answer:
   "Nothing was deleted: the answer wasn't <name>."
3. Under the site lock (the same wait message as deploy and rollback), in this order: delete
   `/etc/caddy/sites/<name>.caddy` and reload Caddy ("Deleted <file> and reloaded Caddy."); stop,
   disable and delete the unit, then `daemon-reload` (`site_unit_remove`); `pkill -KILL -u` both site
   users (`userdel` refuses a user with processes); `rm -rf` `/srv/<name>`, `/var/lib/shipit-<name>`,
   `/var/cache/shipit-<name>`, `/var/log/shipit/<name>` and `/etc/shipit/sites/<name>.env`; `userdel
   <name>-build`, then `userdel <name>` (which removes group `<name>`, the build user's primary group);
   last, `<name>.conf`. A Caddy file or unit without the marker, or a user whose GECOS isn't shipit's
   (decision 36), is left alone with "<file> wasn't written by shipit, so it was left alone." / "The
   user <user> wasn't created by shipit, so it was left alone."
4. Print "Deleted <name>." If the site had a deploy key, also "Remove its deploy key from GitHub too:
   https://github.com/<owner>/<repo>/settings/keys".

`<name>.conf` goes last, so a delete that stops half-way (a failed `rm` or `userdel`) still knows the
site, and running it again finishes the job: every step skips what's already gone. The lock file
`/var/lib/shipit/<name>.lock` stays (empty): a deploy already waiting on it would otherwise hold a lock
on a deleted file while a new command makes a new one, and both would run.

### 5.7 `shipit uninstall`

Removes shipit from the VPS: every site, what setup wrote, the old CI user, and shipit itself (decision
71). Packages stay installed and ufw stays on.

1. Refused, changing nothing: any argument ("Usage: shipit uninstall (it takes no arguments)").
2. Confirm, before any lock: print on stderr "This uninstalls shipit. It deletes:", then one line per
   group: the sites (by name, every valid `<name>` with a `<name>.conf`; left out when there are none),
   shipit's Caddyfile (Caddy is stopped), fail2ban jail, unattended-upgrades file and SSH drop-in
   (password logins follow sshd's own settings again), the Caddy and NodeSource apt sources and keys
   (the packages stay, without updates from those repos), the firewall's 80/tcp, 443/tcp and 443/udp
   rules (ufw stays on), and `/etc/shipit`, `/var/lib/shipit`, `/var/log/shipit`, the old ci user and
   shipit itself. When a site has `/var/lib/shipit-<name>`: "Site data goes too: <folders>. shipit keeps
   no backup: copy it first if you may need it." Then "It can't be undone." and `Type uninstall to go
   on:`, reading one line from stdin. Only `uninstall` exactly goes on. No input: "Nothing was removed:
   there was no answer. Run it in a terminal (ssh -t), or pipe the answer: echo uninstall | shipit
   uninstall". Any other answer: "Nothing was removed: the answer wasn't uninstall."
3. Each site is deleted as 5.6 step 3 and 4 do it (`delete_site`: its lock, Caddy file, unit,
   processes, folders, env file, users, `<name>.conf` last, the deploy key reminder), one after the
   other.
4. Then, each file only if it has the marker (otherwise "<file> wasn't written by shipit, so it was
   left alone."): any `.caddy` left in `/etc/caddy/sites/`; `/etc/caddy/Caddyfile`, then `systemctl
   disable --now caddy`; `/etc/caddy/sites/` if it's empty; the fail2ban jail (reload fail2ban);
   `52shipit-auto-upgrades`; `10-shipit.conf` (reload ssh); `caddy-stable.list` and `nodesource.list`,
   each with its keyring (a keyring has no marker, so it goes only with its list); `shipit-nodejs`.
   `ufw delete allow` 80/tcp, 443/tcp and 443/udp (ufw skips a rule it doesn't have); the defaults, the
   SSH rule and ufw itself are kept.
5. The ci user of decision 68: `/etc/sudoers.d/shipit-ci` (marked), and the user `ci` with GECOS
   `shipit ci` (its processes killed, `userdel`, `/home/ci` deleted). A `ci` user that isn't shipit's
   is ignored.
6. `rm -rf` `/etc/shipit`, `/var/lib/shipit` (the lock files) and `/var/log/shipit`. `/srv` stays: it's
   the system's.
7. Last, shipit itself: `/usr/local/bin/shipit` if it's install.sh's link to
   `/usr/local/lib/shipit/bin/shipit`, then `/usr/local/lib/shipit`. Print "Uninstalled shipit." and
   that the packages are still there (remove them with `apt-get purge`).

Every step skips what's already gone, and the sites' `.conf` files go before `/etc/shipit`, so an
uninstall that stops half-way is finished by running it again (from a checkout, if shipit itself was
already deleted).

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
- `sshd.conf` (the drop-in), `fail2ban-sshd.conf` (the jail drop-in), `github_known_hosts` (GitHub's
  SSH host keys, copied, not rendered).
- `apt-caddy.list`, `apt-nodesource.list` (NODE_MAJOR), `apt-nodejs.pref` (the NodeSource pin),
  `apt-auto-upgrades` (unattended-upgrades on).

Every file rendered from these templates starts with a `# managed by shipit` line (`//` in apt.conf
files): each template that begins a file carries it, but not the parts rendered after
`site-log.caddy` or `site.service` (decisions 46, 51). Setup overwrites a file only when one of its first three lines is that marker, or
when it's missing (or, for the Caddyfile, Caddy's untouched default).

Each template gets a golden file and a unit test (kept from the old tool).

## 7. Code layout

```
bin/shipit           dispatcher: setup | deploy | rollback | delete | uninstall | help
lib/common.sh        log/err/die, validators, locks, render, install_if_changed, atomic_link, health_ok
lib/config.sh        shipit.ini reading + validation (git config) and the first-deploy questions
                     (ini_ask), check_env_key, site .conf read/write
lib/setup.sh
lib/deploy.sh        resolve → ask (shipit.ini, env file) → build → switch → prune
lib/rollback.sh
lib/delete.sh        confirm → caddy → unit → folders → users → conf (5.6)
lib/uninstall.sh     confirm → every site (delete_site) → setup's files → ci → folders → itself (5.7)
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
| M1 | `shipit.ini` parser + validators | bats (fixtures for every key and error, including an unknown key, a duplicate single-value key, an `[include]` attempt, an unquoted `#` in a value, an invalid `data.dir` (`../x`, `a/b`), `[data]` on a static site, a `node.start` with `\n`, `'` or `%`, a `static.root` of `../x`, and a ref starting with `-`; `site.health` an unknown key, decision 69) |
| M2 | `setup` (incl. SSH hardening, firewall) | bats (golden files for every rendered file) |
| M3 | `deploy` static (done) | bats (golden `site-static.caddy` with the `log` block; URL form with a REPO that differs from the registered one refused; domain/alias clash on a later deploy refused; a changed `site.type` refused; two concurrent deploys of one site run one after the other) |
| M4 | `deploy` node / nextjs + health check + auto-revert + data folder (done) | bats (golden `site-proxy.caddy` and `site.service`) |
| M5 | `rollback` (done) | bats (static, node and nextjs rollbacks swap the links and restart without rendering or reloading anything; rolling back twice returns to the start; a failed health check swaps back; a held site lock makes rollback wait; rollback works with an invalid or deleted `shipit.ini`) |
| M6 | `remote` + CI user + GitHub Actions example (done; removed later, decision 68) | bats (command parsing: site A's key can't deploy or roll back site B, a ref like `--upload-pack=x` is refused; a `--ci-key` file with two lines or key options is refused) |
| M7 | README, CLAUDE.md rewritten (done) | review |

## 9. Decisions

| # | Question | Decision |
|---|---|---|
| 1 | Web server | **Caddy only.** nginx isn't installed. |
| 2 | Site types | **`static`, `node`, `nextjs`.** |
| 3 | Where builds run | **On the VPS, as the site's own build user `<name>-build`**, one build at a time. |
| 4 | Private repos | **Per-site deploy key.** The first deploy prints it with the GitHub URL and exits non-zero; run deploy again after adding it. The first deploy takes the name on the command line (`shipit deploy <repo-url> <name>`), so the key's folder exists before the first fetch. |
| 5 | Secrets | **Edited by hand over SSH** in `/etc/shipit/sites/<name>.env`, or entered at the first deploy's prompt (decision 69). No other command for them. |
| 6 | First deploy | **By hand, as root**, like every other command. |
| 7 | SSH hardening | **On**, guarded by the key-login check in 5.1 step 7. |
| 8 | Downtime on Node/Next.js deploy | **Accepted**: a ~1–3 s gap while the unit restarts. No blue/green. |
| 9 | Removing a site | **`shipit delete <name>`** (decision 70). It was "no command, README documents the manual steps" until then. |
| 10 | Rewrite approach | **Fresh rewrite** on a new branch; keep the old tool's helpers listed in section 7. |
| 11 | Who runs shipit | **Root.** Repo code only ever runs as `<name>-build` (build) or `<name>` (runtime). Running shipit itself as an unprivileged user was considered and rejected: it needs two privilege modes, an extra command and sudo rules for restarts anyway, and the CI path is already limited by the forced command plus strict `shipit remote` parsing. |
| 12 | Site config format | **`shipit.ini`, in git's config dialect.** It allows comments, is easy to read, adds no dependency (`git` is already installed), and `git config` is a strict, well-specified parser that exits non-zero on bad syntax. Considered: JSON (no comments) and YAML (needs python3 + yq, has YAML 1.1 quirks, and is a bigger parser to run on untrusted input). The file lives on the server, not in the repo (decision 69). |
| 13 | Site data | **`/var/lib/shipit-<name>` (0700) via systemd `StateDirectory=`, opt-in with `[data]`, node/nextjs only.** No backups, no Caddy-served folders. Not inside `/srv/<name>`: that tree holds code, the build user owns the release folders and `repo.git`, and releases are deleted on prune. `$STATE_DIRECTORY` is a `:`-joined list when `data.dir` is set; this is documented rather than worked around. |
| 14 | Where the config is applied | **The Caddy file and unit are rendered from the site's `/srv/<name>/config/shipit.ini` by deploy only.** Revert and rollback apply no config, so rolling back code doesn't roll back its config (this reverses the earlier "config follows `current`"; decision 69). |
| 15 | Renaming a site, changing its type | **The site name (fixed by the first deploy's command line) and the type are fixed after the first deploy; renaming or changing type = remove + deploy.** A later deploy whose `site.type` differs is refused before building, so a rollback never crosses a type change. |
| 17 | Who owns `/srv/<name>` | **Root** (`root:<name>`, 2750), and `releases/` too. Root creates and names release folders, owns the symlinks, and takes each release back after its build; `<name>-build` owns only `repo.git`, `.ssh/`, `home/` and the release being built. Rejected: build-owned `/srv/<name>`, where a build step could repoint `current`/`previous` or rename releases that root then follows. |
| 19 | Next.js runtime cache | **`CacheDirectory=shipit-<name>`**, linked from `.next/cache` after the build and emptied (`systemctl clean --what=cache`) on every switch, so a rollback never serves pages cached by the newer release. |
| 20 | Logs | **Per-site access logs in `/var/log/shipit/<name>/access.log`, rolled by Caddy; app and Caddy errors in the journal; build output only in the SSH session/Actions log. No logrotate.** |
| 21 | Caddy's access to static sites | **ACLs (`setfacl`) on the served folder only**, set after the build. Rejected: adding `caddy` to group `<name>`, which let Caddy read `repo.git`, the whole release and the env file (so one site's symlink could publish another's), and which a running Caddy only sees after a restart. |
| 22 | Secrets during install | **None: only the build step gets the env file.** Dependencies' install scripts are third-party code. Private npm registries that need a token at install time aren't supported. |
| 23 | Values from `shipit.ini` in rendered files | **Every key has a strict pattern; control characters are never allowed**, because git config turns `\n` into a newline and a value lands in a unit or Caddy file that root installs. |
| 24 | Which GitHub URLs | **`https://github.com/<owner>/<repo>[.git]` only.** Owner: `[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?` (GitHub's user/org rule); repo: `[A-Za-z0-9._-]{1,100}`, not `.` or `..`. Anything else (SSH, other hosts, extra path, query, user info) is refused. |
| 25 | Port allocation | **The lowest port in 3000–3999 that no `<name>.conf` has.** Listening sockets aren't checked: 3000–3999 is kept for shipit's sites. |
| 26 | Keys that don't fit the type | **Refused**, not ignored: `node.start` and `data.dir` on `static`; `static.root` on `node`/`nextjs`. Same reason as unknown keys: a value that does nothing is a mistake. |
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
| 37 | Default branch, ref resolution | **The remote's `HEAD`, read with `git ls-remote --symref <url> HEAD`** each time the ref is left out (its name must pass `check_ref`), then used as `refs/heads/<branch>`. Any ref resolves in `repo.git` with `rev-parse --verify --end-of-options <ref>^{commit}`, so a branch, a tag or the SHA of a fetched commit works. |
| 38 | Transport after the first deploy | **SSH if `/srv/<name>/.ssh/id_ed25519` exists, else HTTPS**, without probing. Before the first success, a repo that answers over HTTPS is public and a key left by an earlier try is deleted, so a public site never switches to SSH. A public repo that later turns private: create the key as `<name>-build` (`ssh-keygen -t ed25519 -N '' -f /srv/<name>/.ssh/id_ed25519`) and add it to GitHub. SSH runs as `ssh -i <key> -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=<templates>/github_known_hosts -o GlobalKnownHostsFile=/dev/null`; the key's comment is `shipit-<name>`. |
| 39 | PORT for static sites | **None.** Only `node`/`nextjs` sites get a PORT (M4); `conf_parse` already allows a static site without one. |
| 40 | Release folder name | **`<date -u +%Y%m%dT%H%M%SZ>-<full sha>`**, so names sort by time. Root makes it with `mkdir` (no `-p`); if the name is taken (the same commit within one second), it waits a second and tries once more. `current` and `previous` are relative links (`releases/<dir>`); a link that isn't one is refused rather than followed. |
| 41 | Install and build | **Defaults are read from the commit as data**: `git ls-tree --name-only <sha>` for lockfiles (`package-lock.json` → `npm ci`, else `pnpm-lock.yaml` → `pnpm install --frozen-lockfile`, else `yarn.lock` → `yarn install --immutable`, else `package.json` → `npm install`, else no install) and `git show <sha>:package.json` piped to `jq` for `.scripts.build`. Each command runs as `runuser -u <name>-build -- env -i HOME=/srv/<name>/home PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8`, with `umask 027`, as `sh -c "<cmd>"` in the release. Install's stdin is `/dev/null`; build's is the env file, read by a small sh wrapper that looks the command up first, exports it, and runs the build with stdin from `/dev/null`. Root only parses the env file to check it (bash, no export, nothing run with its values). |
| 42 | Env file format | **`KEY=value` lines (KEY `^[A-Za-z_][A-Za-z0-9_]*$`, at the start of the line), blank lines and `#`/`;` comments.** The value is literal, except that spaces and tabs around it, then one pair of matching `"` or `'` around all of it, are removed; no escapes, no `export`, no line continuations. That's the part of systemd's `EnvironmentFile=` syntax both read the same way. Any other line fails the deploy, naming the line, before the build. |
| 43 | Symlinks in a static root | **Every `find -P <root> -type l` is resolved by `path_resolve`** (bash and `readlink`, like `realpath -m`, which macOS lacks; more than 40 links is a loop and refused) and must stay inside `<root>`. `<root>` itself, and every folder on the way to it, must not be a symlink. The check runs after root takes the release back, so the build user can't change the tree meanwhile. |
| 44 | Static site headers | **`X-Content-Type-Options nosniff`, `Referrer-Policy strict-origin-when-cross-origin`, `X-Frame-Options SAMEORIGIN`, `-Server`.** No HSTS: browsers keep it for its max-age, after the site's config (or the site) has changed, and Caddy already redirects HTTP to HTTPS. No CSP: it depends on the site. |
| 45 | What the access log filter cuts | **The query string of `request>uri`, `request>headers>Referer` and `resp_headers>Location`** (Caddy's `regexp` field filter, `\?.*$` → empty). An alias redirect's `Location` repeats the request's query string, and same-site `Referer`s carry the previous page's. |
| 46 | Variable-length alias blocks | **Rendered one at a time and concatenated**: `site-log.caddy`, then the type's block (`site-static.caddy`), then `site-alias.caddy` per alias, each through `render`. The snippet is named `shipit-<name>-log`, because all site files share one Caddyfile and a snippet name can't repeat. Only `site-log.caddy` carries the marker line (it comes first). The site file is validated on its own (`caddy validate`, as `caddy`). |
| 47 | Render failure message | **"Deploy failed: the new release's config couldn't be installed; still serving <release>."** (the health-check message would be wrong). A first deploy prints "First deploy of <name> failed; nothing is served." either way. Rollback has no such message: it renders no config (decision 69). |
| 48 | URL form for a known site | **Matches when it names the same `<owner>/<repo>`**, ignoring letter case (GitHub does) and `.git`. REPO keeps the URL of the first deploy. |
| 49 | Waiting for `build.lock` | **Prints "Another site is building; waiting."** (it can only be another site: the site lock is held). |
| 50 | When a first deploy gets its PORT | **At the start of B, right after `build.lock` is taken, and written to `<name>.conf` (REPO and PORT; valid by section 4's rules) before the lock is let go.** Every deploy takes `build.lock`, so two first deploys of different sites can't pick the same port, and no extra lock is needed. A failed first deploy keeps its PORT, so a rerun gets the same one. Later deploys keep PORT; only a site with no PORT yet gets one. |
| 51 | The unit's variable parts | **Rendered one at a time and concatenated, as for the Caddy file (decision 46)**: `site.service` (marker, `[Unit]`, `[Install]`, then `[Service]` last), then `site-data.service` when `data.dir` is set (`STATE_DIRS` is computed from the validated `data.dir` values: `shipit-<name> shipit-<name>/<dir>...`), then `site-nextjs.service` for `nextjs`. The parts after the first only add lines to `[Service]`, which is why `[Install]` comes before it (systemd doesn't mind the order). `render` stays the only templating. |
| 52 | Extra hardening in the unit | **`PrivateDevices`, `ProtectKernelTunables`, `ProtectKernelModules`, `ProtectControlGroups`, `RestrictSUIDSGID` and `LockPersonality`**, on top of section 6's list. Nothing that breaks Node: no `MemoryDenyWriteExecute` (V8 JIT-compiles), no syscall filter. |
| 53 | A site without an env file | **`EnvironmentFile=-...`**: the unit starts without one. A site that needs secrets lists them as `site.env`, and deploy fails before building when they're missing, so the `-` never hides a missing secret that shipit.ini names. |
| 54 | Checking the unit | **`systemd-analyze verify <temp>/unit/shipit-<name>.service`** (verify needs a unit's name; it doesn't need the user or the working directory to exist), and an installed `shipit-<name>.service` or `<name>.caddy` without the marker is refused, not replaced. The Caddy file and the unit are both checked before either is installed. |
| 55 | `systemctl enable` | **On every deploy**, not only the first: it's idempotent and keeps no state about which deploy is the first. Revert and rollback install no unit, so they don't run it. |
| 56 | Health check | **`curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Host: <domain>" http://127.0.0.1:<port>/`, every second until `health_ok` accepts the status (anything below 500) or 60 s have passed** (`HEALTH_TIMEOUT`, `HEALTH_INTERVAL`, `HEALTH_MAX_TIME` in `lib/deploy.sh`; tests shorten them). Redirects aren't followed, so `/` redirecting to a login page passes. There's no custom path or strict mode (`site.health` was removed, decision 69). The type, domain and port come from `<name>.conf` (`CONF_*`), which deploy has just written and rollback and revert read, so none of them needs `shipit.ini`. On failure it prints the URL, the last status (or "gave no answer"), "it needs a status below 500" and `journalctl -u shipit-<name>`. `site_restart_and_check` (restart + health check) is shared by deploy, revert and rollback. |
| 57 | What a failed first deploy keeps | **The users and `<name>.conf` with REPO and PORT**: TYPE, DOMAIN and ALIASES (written in C.2) are removed again, so the rerun is a first deploy (access probe, name check) and the domain isn't held. The unit is stopped, disabled and deleted (then `daemon-reload`), not only stopped and disabled, so no unit is left pointing at a missing `current`. |
| 58 | Restart after a failed render | **The restored release is restarted and health-checked whatever made the deploy fail**, as C.4 says, even though a failed render never restarted the new one (a short gap); the config stays as the failed deploy left it. If that fails too, it's printed and the deploy (or rollback) still exits non-zero. |
| 59 | Test seams for M4 | **`SYSTEMD_DIR` (`/etc/systemd/system`) and `CACHE_ROOT` (`/var/cache`, the `.next/cache` link's target) in `lib/common.sh`.** No `STATE_ROOT`: shipit never touches `/var/lib/shipit-<name>`; systemd makes it. (Until `delete`, which deletes it: `STATE_ROOT`, `/var/lib`, decision 70.) |
| 60 | Rollback's swap order | **`previous` → old `current` first, then `current` → old `previous`**, as deploy's C.1 orders them. A crash in between leaves `current` unchanged (the site keeps serving what it served), with both links on the same release; rollback treats a `previous` equal to `current` as no `previous`. The other order would leave both links on the older release, so the newer one would be unreachable and the next deploy would prune it. Going back after a failure uses the same order. |
| 61 | Waiting for the site lock | **One message for deploy and rollback: "Another deploy or rollback of <name> is running; waiting."** The waiting command can't know which of the two holds the lock. |
| 67 | No `site.name` in `shipit.ini` | **The name comes only from the command line** (`shipit deploy <repo-url> <name>`, then `shipit deploy <name>`), and `REPO` in `<name>.conf` ties it to its repo, so a `site.name` key said nothing new and could only disagree with it (and needed two refusal messages). It also finds the site's `config/shipit.ini` (decision 69). `site.name` is now an unknown key, refused like any other (decision 26), so a `shipit.ini` written for v1.0.0 fails with "shipit.ini has unknown keys: site.name. …" until the line is deleted. A breaking change for those files. |
| 68 | CI deployment removed | **No `ci` user, no `shipit remote`, no `--ci-key`, no sudoers rule, no known_hosts output, no workflow examples.** Deploys and rollbacks are run by hand as root (over SSH if you like). Removed with it: decisions 16, 18 and 62–66, which only concerned CI. Numbers of the other decisions, setup steps (6 and 8 are now empty) and sections (5.4) are kept so references stay valid. An existing VPS keeps its `ci` user, `/etc/sudoers.d/shipit-ci` and `/home/ci/.ssh/authorized_keys`: setup no longer touches them, so remove them by hand (`userdel ci`, `rm /etc/sudoers.d/shipit-ci`, `rm -r /home/ci`). |
| 69 | Site config on the server | **`shipit.ini` is `/srv/<name>/config/shipit.ini`** (root:root, mode 600, in a root-only `config/` of mode 00700), not in the repo. It is built by prompts on the site's first deploy (5.2 A.2b) and read by `deploy` only, on every deploy, so an edit takes effect on the next one; `deploy` and `rollback` already take `<name>`, so the command line is unchanged. The first deploy also offers to create `<name>.env` from `KEY=VALUE` prompts (5.2 A.2c). Rollback and revert never read, restore or apply it (5.5): they swap links, restart and health-check, with TYPE, DOMAIN and PORT from `<name>.conf`; so there's no per-release copy, and a config change is rolled forward by editing the file, not back. **`site.health` is removed**: the check always polls `/` and accepts a status below 500 (decision 56), which keeps a custom path and a strict mode out of `<name>.conf`. The pin `refs/shipit/<sha>`, which only kept a release's `shipit.ini` readable after a force-push, is gone with the repo copy. Version stays 1.0.0 and there is no import or fallback for the old layout: the server file is how 1.0.0 works. Rejected: keeping the repo file and copying it per release (the config would still travel with the code, and a rollback re-render could still fail); restoring the old config on rollback. Consequences: a deploy whose config breaks the site is reverted in code only; rolling back across a `static.root` change can leave Caddy serving a folder the older release lacks (5.5). |
| 70 | Deleting a site | **`shipit delete <name>` deletes everything shipit made for the site, its data in `/var/lib/shipit-<name>` included, after the admin types the site's name** (5.6). Typing the name, not y/N, because Enter on a y/N habit would cost a site; piping it (`echo <name> \| shipit delete <name>`) keeps it scriptable, as the first deploy's answers are. No `--yes` flag (shipit takes no flags). It asks before taking the site lock, so a deploy isn't blocked by a prompt, and deletes `<name>.conf` last so a rerun finishes a half-done delete. Data is deleted too: keeping it would leave a `/var/lib/shipit-<name>` that a new site of the same name would inherit; the prompt names the folder and says to copy it first. Files without the marker and users without shipit's GECOS are left alone, as setup and deploy treat them. The lock file is kept (5.6). The deploy key on GitHub can't be removed from the VPS, so it's printed as a reminder. New seam: `STATE_ROOT` (`/var/lib`) in `lib/common.sh`; tests stub `userdel` and `pkill`. |
| 71 | Uninstalling shipit | **`shipit uninstall` removes what shipit made: every site as `delete` removes it (data and users included), the files setup wrote, the CI user and sudoers rule of decision 68, `/etc/shipit`, `/var/lib/shipit`, `/var/log/shipit`, and its own install** (5.7), after the admin types `uninstall` (as `delete` asks for the name, decision 70). Kept: **the packages** (sudo, git or curl may predate shipit, and removing them can break the host; the closing message says to `apt-get purge` what isn't needed), corepack (installed with npm, like a package), **ufw itself** with its defaults and SSH rule (turning it off would leave the host open; only the 80/443 rules go), and `/srv`. Its SSH drop-in is deleted too, so password logins follow sshd's own settings again: the prompt says so. Caddy is stopped and disabled when its Caddyfile was shipit's, since nothing is left to serve. Apt keyrings carry no marker, so each goes only with the shipit list that uses it. Files without the marker and users without shipit's GECOS are left alone. No new lock: each site is deleted under its own lock, as `delete` does. New seams in `lib/uninstall.sh`: `INSTALL_DIR`, `INSTALL_LINK`, `SUDOERS_DIR`, `CI_HOME`; tests stub `ufw`. |
