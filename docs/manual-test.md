# Testing shipit by hand on a VPS

`make` tests shipit's logic with the host commands stubbed. Nothing in it touches a real apt, systemd,
Caddy, sshd, ufw, sudo or Linux users, so check those here before a release, and after any change to
how shipit uses them. Tick each box; anything that doesn't happen as described is a bug.

Run the whole list on **Debian 13**. Run it on **Ubuntu 26.04** too, at least sections 1, 2, 4 and 7,
because Ubuntu ships sudo-rs and the Rust coreutils (plan §1).

## 0. What you need

- [ ] A fresh VPS or VM (2 GB RAM or more, for a Next.js build) with a public IP, ports 22, 80 and 443
      reachable, and your SSH key in `/root/.ssh/authorized_keys`.
- [ ] Three hostnames pointing at it, e.g. `docs.test.example.com`, `api.test.example.com`,
      `blog.test.example.com`, plus `www.docs.test.example.com` for the alias checks.
- [ ] Test repos on GitHub, each with a `shipit.ini` (README "shipit.ini"):
  - **docs**: public, `type = static`, `static.root = dist`, a build script that writes
    `dist/index.html`;
  - **docs-private**: the same, but a private repo;
  - **api**: `type = node`, `start = node server.js`, `[data] dir = uploads`. `server.js` listens on
    `$PORT` and answers `/` with 200;
  - **blog**: `type = nextjs`, from `create-next-app`, with one `next/image` on its home page.
- [ ] A second terminal with its own SSH session as root, kept open until section 1 is done, in case
      SSH hardening goes wrong.

Below, `<rel>` means a release folder name (`ls /srv/<name>/releases`).

## 1. Install and setup

- [ ] **Bootstrap.** Run the install command from the README (with your fork's URL). `shipit help` prints
      the usage.
- [ ] **Not root.** As a normal user, `shipit deploy x` refuses with "Run this as root, or with sudo:
      …", and `shipit help` still works.
- [ ] **Setup runs.** `shipit setup` finishes with exit 0 and prints the known_hosts lines and
      "Replace <host> with …". Save these lines for section 7.
- [ ] **Node.js.** `cat /etc/shipit/host.conf` shows `NODE_MAJOR=<the current LTS>`, and
      `node --version` has that major.
- [ ] **corepack.** `corepack --version` prints the pinned version, and `pnpm --version` works (corepack
      is enabled).
- [ ] **Caddy.** `systemctl is-active caddy` is active, and `/etc/caddy/Caddyfile` starts with
      `# managed by shipit` and imports `/etc/caddy/sites/*.caddy`.
- [ ] **Folders.** `stat -c '%U:%G %a %n' /etc/shipit/sites /etc/caddy/sites /var/lib/shipit /srv /var/log/shipit`
      shows `root:root 755` for each.
- [ ] **Firewall.** `ufw status verbose` shows deny (incoming), allow (outgoing), and ALLOW for 22/tcp,
      80/tcp, 443/tcp and 443/udp.
- [ ] **fail2ban.** `fail2ban-client status sshd` shows the jail. `/etc/fail2ban/jail.d/shipit-sshd.conf` has
      `backend = systemd`.
- [ ] **unattended-upgrades.** `apt-config dump | grep -E 'Periodic::(Update-Package-Lists|Unattended-Upgrade)'`
      shows both set to `"1"`.
- [ ] **SSH hardening.** `sshd -T | grep -E '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin) '`
      shows `no`, `no` and `prohibit-password`. A **new** key login as root still works.
- [ ] **Hardening skipped on a password session.** On a fresh VM, log in as root with a password and
      run setup. It prints "Skipped SSH hardening: …" and `/etc/ssh/sshd_config.d/10-shipit.conf`
      doesn't exist.
- [ ] **ci user and sudoers.** `getent passwd ci` shows GECOS `shipit ci` and shell `/bin/sh`.
      `visudo -c` passes. `sudo -l -U ci` lists only `/usr/local/bin/shipit remote *`. *(Ubuntu: this
      is the sudo-rs check.)*
- [ ] **Re-run is a no-op.** Run `shipit setup` again. It prints no "Wrote …" or "reloaded" lines, and
      `systemctl show caddy -p ExecMainStartTimestamp` is unchanged.
- [ ] **Hand-edited Caddyfile.** Change one line of `/etc/caddy/Caddyfile` and remove its marker, then
      re-run setup. It stops and says to move the file away, and the file is untouched. Restore it.

## 2. Static deploy (docs)

- [ ] **First deploy.** `shipit deploy https://github.com/<you>/docs docs` ends with "Deployed docs: now
      serving <rel>." Then `curl -s https://docs.test.example.com/` serves the page over a real
      certificate.
- [ ] **Caddy reloaded, not restarted.** `systemctl show caddy -p ExecMainStartTimestamp` is the same as
      before the deploy.
- [ ] **Alias.** `curl -sI https://www.docs.test.example.com/x?y=1` answers 308 with
      `Location: https://docs.test.example.com/x?y=1`.
- [ ] **Users.** `id docs` and `id docs-build` exist, docs-build's group is `docs`, and both have
      nologin shells.
- [ ] **Ownership and modes.**
      `stat -c '%U:%G %a %n' /srv/docs /srv/docs/releases /srv/docs/repo.git /srv/docs/.ssh /srv/docs/home /srv/docs/releases/*`
      shows:
      - `root:docs 2750` for `/srv/docs`, `releases/` and the release (the release is root-owned
        after the deploy);
      - `docs-build:docs 700` for `repo.git`, `.ssh` and `home`, **without** a setgid bit.
- [ ] **Not world-readable.** `find /srv/docs/releases -perm -o=r` prints nothing.
- [ ] **Caddy's ACLs.**
      - `runuser -u caddy -- cat /srv/docs/current/dist/index.html` works;
      - `runuser -u caddy -- ls /srv/docs/current/` is refused, as is
        `runuser -u caddy -- cat /srv/docs/current/shipit.ini`;
      - `runuser -u caddy -- ls /srv/docs/repo.git` is refused;
      - `runuser -u caddy -- cat /etc/shipit/sites/docs.env` is refused (create the file first).
- [ ] **The build user can't touch live releases.**
      - `runuser -u docs-build -- ln -sfn /tmp /srv/docs/current` is refused, and so is
        `runuser -u docs-build -- mv /srv/docs/releases/<rel> /srv/docs/releases/x`;
      - `runuser -u docs-build -- touch /srv/docs/current/dist/x` is refused.
- [ ] **Access log.**
      - `curl -s 'https://docs.test.example.com/?token=secret'` adds one line to
        `/var/log/shipit/docs/access.log`, and `grep -c secret` on that file prints `0`;
      - `stat -c '%U:%G %a' /var/log/shipit/docs` shows `caddy:caddy 750`.
- [ ] **Two releases at most.** Push two more commits and deploy after each. `ls /srv/docs/releases`
      shows two folders. `readlink /srv/docs/current /srv/docs/previous` names them.
- [ ] **Concurrent deploys.** Start `shipit deploy docs` in two sessions at once. The second prints
      "Another deploy or rollback of docs is running; waiting." and runs after the first.
- [ ] **A failed build keeps everything.** Push a commit whose build fails. The deploy exits non-zero,
      the half-built folder is gone, and `readlink` of `current` and `previous` is unchanged.
- [ ] **Symlink out of the served folder.** Push a commit whose build runs `ln -s /etc/passwd dist/pw`.
      The deploy is refused ("… is a symlink to somewhere outside dist …") and the site is unchanged.
      Revert the commit.
- [ ] **static.root follows rollback.** Push a commit that serves `out` instead of `dist`, with a
      visibly different page, and deploy it. `/etc/caddy/sites/docs.caddy` names `current/out`, and the
      new page is served. `shipit rollback docs` brings back `current/dist` in the Caddy file and the
      old page.
- [ ] **Rename refused.** Change `site.name` in a commit. The deploy says "shipit.ini says the site name
      is …, but this repo is deployed as docs. …", and nothing changes. Revert.
- [ ] **Type change refused.** Change `site.type` to `node` in a commit. The deploy says "… Changing a
      site's type isn't supported." Revert.
- [ ] **Hand-edited site Caddy file.** Remove the marker line from `/etc/caddy/sites/docs.caddy`, then
      deploy. It's refused, and the file is untouched. Restore it by deleting the file and deploying.

## 3. Private repo (docs-private)

- [ ] **The key is printed.** `shipit deploy https://github.com/<you>/docs-private docsp` prints an
      `ssh-ed25519 …` key and "Can't fetch … add this key as a read-only deploy key at
      https://github.com/<you>/docs-private/settings/keys/new, then run the same command again.", then
      exits non-zero.
- [ ] **The rerun completes.** Add the key on GitHub (read-only) and run the same command. It deploys.
      A later `shipit deploy docsp` works without the URL.
- [ ] **Isolation.** `runuser -u docs-build -- cat /srv/docsp/.ssh/id_ed25519` is refused.

## 4. Node site (api)

- [ ] **First deploy.** `shipit deploy https://github.com/<you>/api api` passes its health check.
      `/etc/shipit/sites/api.conf` has `PORT=3000` (or the next free one), and
      `curl -s https://api.test.example.com/` works.
- [ ] **The unit.** `systemctl is-enabled shipit-api` prints `enabled`.
      `systemctl show shipit-api -p User -p SocketBindAllow -p SocketBindDeny -p ProtectSystem` shows
      `api`, `tcp:<port>`, `any` and `strict`.
- [ ] **Secrets: build yes, install no.** Put `MYSECRET=hello` in `/etc/shipit/sites/api.env` (mode 600).
      Set `install = echo install sees ${MYSECRET:-nothing}` and
      `build = echo build sees ${MYSECRET:-nothing}` in shipit.ini (no quotes: git config would strip
      them), then deploy. The output shows
      "install sees nothing" and "build sees hello". The running process sees it too: log
      `process.env.MYSECRET` once.
- [ ] **Env file and root.** Add `PATH=/nonexistent` to `api.env` and deploy. It still works, because
      root doesn't use the file's values. Remove the line.
- [ ] **Required keys.** Add `env = NEEDED` to shipit.ini without adding NEEDED to `api.env`. The deploy
      fails before building, naming `NEEDED`. Revert.
- [ ] **The build user can't read secrets or data.** `runuser -u api-build -- cat /etc/shipit/sites/api.env`
      and `runuser -u api-build -- ls /var/lib/shipit-api` are both refused.
- [ ] **Data folder.**
      - `stat -c '%U:%G %a' /var/lib/shipit-api /var/lib/shipit-api/uploads` shows `api:api 700` for
        both;
      - write a file there from the app (or `runuser -u api -- touch /var/lib/shipit-api/uploads/keep`),
        deploy, then roll back. The file is still there.
- [ ] **A failed health check reverts.** Push a commit whose server answers `/` with 500, and deploy
      it. (Break the code, not the env file: the revert restarts the old release with the same env
      file.) The deploy prints "Deploy failed health check; still serving <old rel>." Then:
      - `readlink /srv/api/current /srv/api/previous` is as before the deploy;
      - the unit file is the old one;
      - the failed release is gone.
      Revert the commit.
- [ ] **Port isolation.** Push a commit whose server also listens on 4000. That listen fails with
      `EACCES`/`EPERM` in `journalctl -u shipit-api` (if the app then crashes, the deploy reverts, which
      is fine). Revert the commit.
- [ ] **Reboot.** `reboot`. Afterwards `curl -s https://api.test.example.com/` works without any
      command.
- [ ] **A failed first deploy leaves nothing.** Deploy a second node repo (or `api` under the name
      `api2` with `site.name = api2`) whose app never answers. It prints "First deploy of api2 failed;
      nothing is served." and:
      - `ls /srv/api2/current /etc/caddy/sites/api2.caddy /etc/systemd/system/shipit-api2.service`
        finds none of them;
      - `id api2` and `/etc/shipit/sites/api2.conf` remain.
      Fix the app and run the same command again: it deploys. Then remove the site (section 8).

## 5. Next.js site (blog)

- [ ] **First deploy.** `shipit deploy https://github.com/<you>/blog blog` (no `node.*` keys) builds
      and serves the site.
- [ ] **The cache link.** `readlink /srv/blog/current/.next/cache` prints `/var/cache/shipit-blog`.
- [ ] **The cache is written.** Request the page with the image. `ls /var/cache/shipit-blog` now has
      files, owned by `blog`.
- [ ] **The cache is emptied.** Deploy again, and also roll back. `/var/cache/shipit-blog` is empty
      right after each.

## 6. Rollback

- [ ] **Config is restored.** On `api`, deploy a commit that adds `dir = db`. The unit gains
      `shipit-api/db`. `shipit rollback api` restores the old unit file (`diff` it against a copy taken
      before) and the old Caddy file, and prints "Rolled back api: now serving <rel>."
- [ ] **Twice returns to the start.** Rolling back again returns `current` and `previous` to where they
      started.
- [ ] **A failed rollback swaps back.** Make the previous release fail its health check (for example, a
      commit whose app returns 500 only if a file like `/etc/shipit-test-old` exists, then a fixed
      commit, then `touch /etc/shipit-test-old`). The rollback prints "Rollback failed health check;
      still serving <rel>.", and the links are as before. Remove the file.
- [ ] **Survives a force-push and gc.** Force-push `main` back to an older commit and deploy, so the
      release before it is no longer on any branch. Run
      `runuser -u api-build -- git -C /srv/api/repo.git gc --prune=now`. `shipit rollback api` still
      works.
- [ ] **No previous.** On a site with only one release, rollback prints "<name> has no previous release
      to roll back to."

## 7. CI over SSH

On your laptop: `ssh-keygen -t ed25519 -N '' -f /tmp/ci_docs` and `ssh-keygen -t ed25519 -N '' -f /tmp/ci_api`.

- [ ] **Keys installed.** Run `ssh root@vps 'shipit setup --ci-key docs -' < /tmp/ci_docs.pub`, then the
      same for `api`. `/home/ci/.ssh/authorized_keys` has one `restrict,command="sudo /usr/local/bin/shipit remote <name>" … shipit:<name>`
      line per site, and `stat -c '%U:%G %a'` shows `root:root 644` for the file and `755` for the
      folders.
- [ ] **Bad key files refused.** A key file with two lines, or one starting with `restrict ` or
      `command="…"`, is refused, and `authorized_keys` is unchanged.
- [ ] **Pinned host key.** Write the setup output, with `<host>` replaced, to `/tmp/kh`. Then
      `ssh -i /tmp/ci_docs -o UserKnownHostsFile=/tmp/kh -o StrictHostKeyChecking=yes ci@<vps> deploy docs`
      deploys, streaming the build. *(Ubuntu: this shows sudo-rs keeps `SSH_ORIGINAL_COMMAND`.)*
- [ ] **Wrong host key fails.** Change one character of the key in `/tmp/kh`. The same command fails
      with a host key error.
- [ ] **One site per key.** `… -i /tmp/ci_docs … ci@<vps> deploy api` and `… rollback api` are both
      refused ("This key belongs to the site docs, …").
- [ ] **Hostile refs refused.** `deploy docs --upload-pack=x`, `'deploy docs main; id'`,
      `deploy docs $(id)` and a plain interactive `ssh … ci@<vps>` are all refused.
- [ ] **Rollback from CI.** `… -i /tmp/ci_docs … ci@<vps> rollback docs` works.
- [ ] **No first deploys from CI.** A key for a site that was never deployed is refused ("… Its first
      deploy must be run by hand, as root …").
- [ ] **A non-22 port.** Add `Port 2222` to an sshd drop-in, `systemctl reload ssh`, and re-run
      `shipit setup`. `ufw status` now allows 2222. `ssh -p 2222 …` works (use `[<vps>]:2222` in
      `/tmp/kh`).
- [ ] **GitHub Actions.** In the docs repo, add the four secrets and `examples/deploy.yml` (with
      `blog` → `docs`). A push deploys, and the Actions log shows the build. A push with a failing
      build makes the run fail. `examples/rollback.yml`, run from the Actions tab, rolls back.

## 8. Removing a site

- [ ] **Clean removal.** Follow README "Removing a site" for `docs`. Afterwards no
      `docs`/`docs-build` users remain, nothing under `/srv/docs`, `/etc/caddy/sites/docs.caddy` or
      `/etc/shipit/sites/docs.*`, and no `shipit:docs` line. Other sites still work. The same name can
      be deployed again from scratch.

## Recording the result

In the release PR, list the OS versions tested, which boxes failed (with the output), and any box
skipped and why.
