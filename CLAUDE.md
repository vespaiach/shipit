# CLAUDE.md

shipit is a bash tool that sets up a Debian or Ubuntu VPS (`shipit setup`), deploys static, Node and
Next.js sites from GitHub onto it (`shipit deploy`) and goes back one release (`shipit rollback`).
**docs/plan.md is the spec**: read it before changing anything, and keep it, README.md and this file
in step with the code.

## Layout

- `bin/shipit` — dispatcher. Checks the command against its list (`setup | deploy | rollback | remote
  | help`), prints usage for `help` or no command, refuses non-root (except `help`), sources
  `lib/common.sh` and `lib/<command>.sh`, and calls `cmd_<command> "$@"`. `remote` is internal (the
  `ci` user's forced command) and isn't in `usage`. A new command needs its library, an entry in the
  dispatcher's `case` and, if public, a line in `usage`.
- `lib/common.sh` — logging (`log`/`err`/`die`), validators (`check_domain`, `check_port`), locks,
  `render`, `install_if_changed`, `is_shipit_file`, `atomic_link`, `health_ok`, and the test-seam
  constants.
- `lib/config.sh` — `shipit.ini`: `ini_load` (one `git config --no-includes -z --list` pass, every
  key validated, results in `INI_*`), `ini_check_name`/`ini_check_type`/`ini_check_clash` (plan §5.2
  A.3). Validators `check_site_name`, `check_ref`, `check_repo_url`, and `repo_slug`/`repo_ssh_url`.
  Site configs: `conf_parse`/`site_conf_read` (data only, into `CONF_*`), `site_conf_write` (atomic
  rename), `site_next_port`.
- `lib/<command>.sh` — one per command (`setup`, `deploy`, `rollback`, `remote`), defining
  `cmd_<command>`. Logic lives in small stdin/argument-driven helpers the tests call; the host-touching
  steps stay thin. `lib/setup.sh`: helpers `version_ge`, `os_supported`, `node_lts_major`,
  `host_conf_read`, `sshd_ports`, `has_authorized_key`, `session_used_key`, `ssh_key_login_ok`,
  `known_hosts_lines`, `may_replace`; steps `setup_packages` (`setup_host_conf`, `setup_apt_repos`,
  `setup_corepack`), `setup_dirs`, `setup_caddy`, `setup_firewall`, `setup_fail2ban`,
  `setup_auto_upgrades`, `setup_ssh`, `print_known_hosts`, called in order by `cmd_setup`.
  `lib/deploy.sh` (sources `lib/config.sh`): helpers `deploy_args`, `same_repo`, `default_branch`,
  `install_default`, `build_default`, `missing_env_keys`, `release_name`/`release_sha`,
  `path_resolve`, `static_root_check`, `prune_releases`, `prune_refs`, `site_user_state`; the
  sh scripts `ENV_EXEC` (exports the env file read on stdin, then runs a command) and `RUN_IN`;
  `as_build` (every repo command, as `<name>-build`, `env -i`, umask 027, locks dropped),
  `git_remote`/`git_build`, `site_ini`, `link_target`; Caddy: `render_site_caddy` (log snippet +
  type block + alias blocks), `site_caddy_check`, `site_caddy_install`; the unit (node/nextjs):
  `render_site_unit` (site.service + optional data/nextjs parts), `site_unit_check`
  (`systemd-analyze verify`), `site_unit_install` (daemon-reload if changed, enable),
  `site_unit_remove`; `site_apply_config` (plan §5.5: render from `current`, check, install, write
  TYPE/DOMAIN/ALIASES) and `site_restart_and_check` (C.3: restart, or stop/clean/start for nextjs,
  then `site_health_check`), both shared with revert and rollback (M5 calls them in that order);
  steps `deploy_resolve` (A.1), `deploy_access` (A.2), `deploy_fetch` (A.3), `deploy_build` (B, with
  `deploy_port` for a first node/nextjs deploy and `release_nextjs_cache`, B.3), `deploy_switch`
  (C.1), `deploy_config` (C.2–C.3, with `deploy_revert`, C.4), `deploy_prune` (D), called in order by
  `cmd_deploy`. `HEALTH_TIMEOUT`, `HEALTH_INTERVAL` and `HEALTH_MAX_TIME` (plain constants there) time
  the health check.
- `templates/` — what `render` fills in: `Caddyfile`, `sshd.conf`, `fail2ban-sshd.conf`,
  `apt-caddy.list`, `apt-nodesource.list`, `apt-nodejs.pref`, `apt-auto-upgrades`, and a site's Caddy
  file in parts: `site-log.caddy` (marker + log snippet), `site-static.caddy` or `site-proxy.caddy`,
  `site-alias.caddy` (one per alias); a node/nextjs site's unit in parts: `site.service` (marker,
  `[Unit]`, `[Install]`, `[Service]` last), `site-data.service` (with `data.dir`),
  `site-nextjs.service`. `github_known_hosts` is copied data (GitHub's SSH host keys, used by git's ssh as is).
- `install.sh` — copies `bin lib templates` to `/usr/local/lib/shipit`, links `/usr/local/bin/shipit`.
- `test/unit/*.bats` (bats-core, shared set-up in `test/unit/helpers.bash`), `test/golden/` (expected
  rendered output), `test/fixtures/`.
- `.github/workflows/check.yml` — CI: runs `make`.

## Engineering rules

- **Bash only**, bash 5 as on Debian 13 and Ubuntu 26.04. `set -euo pipefail` goes in entry points
  (`bin/shipit`, `install.sh`), never in libraries.
- **Libraries are side-effect free when sourced**: only constants and functions. Tests source them.
- **Test seams are plain constants** in `common.sh`: `SHIPIT_ETC` (`/etc/shipit`), `SHIPIT_VAR`
  (`/var/lib/shipit`), `SRV_ROOT` (`/srv`), `CADDY_ETC` (`/etc/caddy`), `LOG_ROOT`
  (`/var/log/shipit`), `OS_RELEASE` (`/etc/os-release`), `APT_ETC` (`/etc/apt`), `SSH_ETC`
  (`/etc/ssh`), `FAIL2BAN_ETC` (`/etc/fail2ban`), `ROOT_HOME` (`/root`), `SYSTEMD_DIR`
  (`/etc/systemd/system`), `CACHE_ROOT` (`/var/cache`) and `SHIPIT_TEMPLATES` (`templates/` next to
  `lib/`). Never read them from the environment or add flags for them; tests reassign them after
  sourcing. Lock helpers take the lock path. Tests stub commands such as `id`, `mv`, `systemctl`,
  `apt-get`, `ufw`, `sshd`, `runuser`, `caddy`, `journalctl`, `dpkg-query`, `useradd`, `getent`,
  `chown`, `setfacl`, `systemd-analyze` and `curl` through `PATH`, so call commands by name (no
  absolute paths, no `$EUID`). Deploy tests run git for real: the stubbed `runuser` runs commands as
  the test user, `BUILD_PATH` (lib/deploy.sh) gets the stubs prepended, and `url.<local
  repo>.insteadOf` in the build user's `~/.gitconfig` (`$SRV_ROOT/<name>/home`) stands in for GitHub.
- **Validators** are `check_<thing> <value>`: silent on success, print the reason to stderr and return
  1 on failure. Validate every value read from a config or `shipit.ini`, or typed by a person, before
  using it.
- **Root never runs or sources repo code.** It reads repo files as data only (`shipit.ini` through
  `git config`, never sourced; `git show`/`git ls-tree` output of the build user's git, parsed with
  `jq` or exact matches). Repo commands (fetch, install, build) run as `<name>-build` through
  `as_build`, and the site's process as `<name>`. Secrets reach the build on stdin, never on a
  command line.
- **Templates go through `render <template> <VAR>...`** (envsubst with an explicit list). It fails,
  printing nothing, on an unset or empty variable. Never `sed` values into files.
- **Validate on a temp copy, then install**: render to a temp file, check it (`visudo -cf`,
  `caddy validate`, `systemd-analyze verify` on `<tmp>/shipit-<name>.service`, `sshd -t`), then
  `install -m`.
- **Atomic switches** go through `atomic_link <target> <link>` (`ln -s target link.new && mv -T
  link.new link`).
- **Caddy is reloaded, never restarted.** Only overwrite files marked `# managed by shipit` (`//` in
  apt.conf files; `is_shipit_file`), and setup also replaces a package's untouched default config,
  checked against dpkg's conffile md5 (`may_replace`). Write through `install_if_changed`, so a
  re-run changes no file.
- **Messages** are plain sentences that say what happened and what to do next. Use the exact wording
  the plan gives.

## Style and checks

- `shfmt -i 2 -ci -bn` formatting, shellcheck clean. Disable a check only on the line that needs it,
  with a reason.
- `make lint` (bash -n, shellcheck, shfmt) and `make test` (bats). GitHub Actions runs `make` on every
  push to `main` and every PR (`.github/workflows/check.yml`, Ubuntu, not as root); it passing is the
  gate before merging. On macOS, install `bash`, `bats-core`, `shellcheck`, `shfmt`, `gettext` and
  `flock` with Homebrew (`/bin/bash` is 3.2). Tests that need GNU-only tools or root skip with a stated
  reason, or stub the tool (macOS `mv` has no `-T`, so `atomic_mv` in `helpers.bash` stubs it).
- Every rendered template gets a golden file in `test/golden/` and a unit test comparing against it.

## Making a change

Milestones M0–M7 are in plan §8. M0 (skeleton, dispatcher, helpers), M1 (`lib/config.sh`), M2
(`shipit setup`, without `--ci-key`, which comes with M6), M3 (`shipit deploy` for static sites) and
M4 (node and Next.js deploys, health check, auto-revert) are implemented; M5–M7 are to do.

1. Branch from `origin/main`.
2. Change the code and the plan together; add bats tests for everything testable without root.
3. Run `make`.
4. Open a PR against `main` saying what changed, the decisions taken, and what's covered by `make`.
   Merge once CI passes.
