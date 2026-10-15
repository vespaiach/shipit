# CLAUDE.md

shipit (1.0.0) is a bash tool that sets up a Debian 13+ or Ubuntu 26.04+ VPS (`shipit setup`), deploys
static, Node and Next.js sites from GitHub onto it (`shipit deploy`), goes back one release
(`shipit rollback`) and deletes a site (`shipit delete`), by hand as root.
**docs/plan.md is the spec**: read it before changing anything, and keep it, README.md (the user
manual) and this file in step with the code.

## Layout

- `bin/shipit` — dispatcher. Checks the command (`setup | deploy | rollback | delete | help`), prints
  usage for `help` or no command, refuses non-root (except `help`), sources `lib/common.sh` and
  `lib/<command>.sh`, and calls `cmd_<command> "$@"`. A new command needs its library, an entry in the `case` and, if
  public, a line in `usage`.
- `lib/common.sh` — the test-seam constants; `log`/`err`/`die`; `check_domain`, `check_port`;
  `health_ok` (any status below 500); `user_state` (is a user missing, shipit's by its GECOS, or someone else's);
  `install_if_changed`, `is_shipit_file`, `atomic_link`; locks (`lock_try`, `lock_wait`,
  `lock_release`, `lock_close_all`); `render`.
- `lib/config.sh` — `check_site_name`, `check_ref`, `check_repo_url`, `check_env_key`, `repo_slug`,
  `repo_ssh_url`, `in_list`; the site's `shipit.ini` (a server file, `/srv/<name>/config/shipit.ini`):
  `ini_load` (one `git config --no-includes -z --list` pass, every key
  validated by `ini_value_ok`, results in `INI_*`), `ini_ask` (the first deploy's questions, with
  `ini_question`; writes the file with `git config -f`), `ini_check_type`,
  `ini_check_clash`; site configs: `conf_parse`/`site_conf_read` (data only, into `CONF_*`),
  `site_conf_write` (checked, then one rename), `site_next_port`.
- `lib/setup.sh` (sources `config.sh`) — plan §5.1. Helpers the tests call: `version_ge`,
  `os_supported`, `node_lts_major`, `host_conf_read`, `sshd_ports`, `has_authorized_key`,
  `session_used_key`, `ssh_key_login_ok`, `may_replace`. Steps, in `cmd_setup` order: `setup_packages` (`setup_host_conf`,
  `setup_apt_repos`, `setup_corepack`), `setup_dirs`, `setup_caddy`,
  `setup_firewall`, `setup_fail2ban`, `setup_auto_upgrades`,
  `setup_ssh`. Constants: `COREPACK_VERSION`, `PACKAGES`.
- `lib/deploy.sh` (sources `config.sh`) — plan §5.2. Helpers: `deploy_args`, `same_repo`,
  `default_branch`, `install_default`, `build_default`, `missing_env_keys`, `env_file_check` (root's
  parse-only check of the env file), `env_ask` (the first deploy's `KEY=VALUE` prompts), `release_name`,
  `release_sha`, `path_resolve`, `static_root_check`, `prune_releases`, `link_target`; the sh scripts `ENV_EXEC` (as
  `<name>-build`: parses the env file on stdin, exports it, runs a command) and `RUN_IN`;
  `as_build` (every repo command as `<name>-build`: `env -i`, umask 027, locks closed), `git_remote`,
  `git_build`. Config: `render_site_caddy`, `site_caddy_check`, `site_caddy_install`,
  `render_site_unit`, `site_unit_check`, `site_unit_install`, `site_unit_remove`,
  `site_health_check`; `site_apply_config` (§5.5: render from the loaded `shipit.ini`, validate,
  install, write TYPE/DOMAIN/ALIASES; deploy only) and `site_restart_and_check` (C.3, from
  `CONF_TYPE`/`CONF_DOMAIN`/`CONF_PORT`), shared by deploy, revert and rollback.
  Steps, in `cmd_deploy` order after `site_lock`: `deploy_resolve` (A.1), `deploy_access` (A.2),
  `deploy_ini` (A.2b), `deploy_env` (A.2c), `deploy_fetch` (A.3), `deploy_build` (B, with `deploy_port` and `release_nextjs_cache`),
  `deploy_switch` (C.1), `deploy_config` (C.2–C.4, `deploy_revert`), `deploy_prune` (D);
  `deploy_exit` is the EXIT trap. State: `CONFIG_FILE` (the site's `shipit.ini`). Constants:
  `BUILD_PATH`, `HEALTH_TIMEOUT`, `HEALTH_INTERVAL`, `HEALTH_MAX_TIME`.
- `lib/rollback.sh` (sources `deploy.sh`, reusing its state globals and helpers) — plan §5.3; it never
  reads or applies `shipit.ini`: `rollback_args`, `rollback_links` (previous first, decision 60), `rollback_revert`, `cmd_rollback`.
- `lib/delete.sh` (sources `deploy.sh`) — plan §5.6: `delete_args`, `delete_confirm` (type the name;
  before the lock), `delete_caddy`, `delete_user`, `cmd_delete` (`<name>.conf` last, so a rerun
  finishes; the lock file stays).
- `templates/` — what `render` fills in (plan §6): `Caddyfile`, `sshd.conf`, `fail2ban-sshd.conf`,
  `apt-caddy.list`, `apt-nodesource.list`,
  `apt-nodejs.pref`, `apt-auto-upgrades`; a site's Caddy file in parts (`site-log.caddy` with the
  marker, then `site-static.caddy` or `site-proxy.caddy`, then `site-alias.caddy` per alias); a
  node/nextjs unit in parts (`site.service` with `[Service]` last, then `site-data.service`,
  `site-nextjs.service`). `github_known_hosts` is copied data, used by git's ssh as is.
- `install.sh` — copies `bin lib templates` to `/usr/local/lib/shipit`, links `/usr/local/bin/shipit`.
- `test/unit/` — bats: one `.bats` per library or concern (`dispatcher`, `validators`, `render`,
  `files`, `locks`, `config`, `setup`, `deploy`, `rollback`, `delete`). `helpers.bash` (sources
  `common.sh` with paths in a temp dir; `stub`; `atomic_mv`) and `deploy_helpers.bash` (the temp-root
  harness for `deploy.bats`, `rollback.bats` and `delete.bats`: `deploy_setup_file` (the shared host-command stubs, written once per file in `setup_file`),
  `deploy_setup`, `host`, `put_ini` (the site's server file), `commit`, `ini`, `node_ini`, `curl_codes`, ...). `test/golden/` holds expected rendered output; `test/fixtures/` the `shipit.ini`
  cases, SSH keys, an sshd journal, a Node release index and a `render` template.
- `Makefile`, `.github/workflows/check.yml` (CI runs `make`).

## Engineering rules

- **Bash only**, bash 5 as on Debian 13 and Ubuntu 26.04. `set -euo pipefail` goes in entry points
  (`bin/shipit`, `install.sh`), never in libraries.
- **Libraries are side-effect free when sourced**: only constants and functions. Tests source them.
- **Test seams are plain constants**, never read from the environment, never flags; tests reassign
  them after sourcing. In `lib/common.sh`: `SHIPIT_ETC`, `SHIPIT_VAR`, `SRV_ROOT`, `CADDY_ETC`,
  `LOG_ROOT`, `SYSTEMD_DIR`, `CACHE_ROOT`, `STATE_ROOT`, `OS_RELEASE`, `APT_ETC`, `SSH_ETC`, `FAIL2BAN_ETC`,
  `ROOT_HOME`, `SHIPIT_TEMPLATES`. In `lib/deploy.sh`: `BUILD_PATH` and the
  `HEALTH_*` timings. Lock helpers take the lock path.
- **Call commands by name** (no absolute paths, no `$EUID`): tests stub `id`, `mv`, `chown`,
  `setfacl`, `useradd`, `userdel`, `pkill`, `getent`, `runuser`, `systemctl`, `systemd-analyze`, `caddy`, `curl`, `gpg`,
  `apt-get`, `apt-config`, `dpkg-query`, `npm`, `corepack`, `ufw`, `sshd`, `journalctl` and
  `ssh` through `PATH`. Deploy tests run git for real: the `runuser` stub runs commands as the test
  user, `BUILD_PATH` gets the stubs prepended, and `url.<local repo>.insteadOf` in the build user's
  `~/.gitconfig` (`$SRV_ROOT/<name>/home`) stands in for GitHub.
- **No environment input.** shipit reads nothing from the environment; repo commands run under `env -i`.
  The only input is the first deploy's prompts (`ini_ask`, `env_ask`) and delete's confirmation
  (`delete_confirm`): lines from stdin, prompts on stderr, so every `as_build` call before them passes `</dev/null` and nothing else reads stdin.
- **Validators** are `check_<thing> <value>`: silent on success, print the reason to stderr and return
  1 on failure. Validate every value from `shipit.ini`, a site `.conf`, `host.conf` or the command line
  before using it. Every `shipit.ini` key has its own pattern; control characters are never allowed.
- **Root never runs or sources repo code.** It reads repo files as data only: `git show`/`git ls-tree`
  output of the build user's git parsed with `jq` or exact matches. `shipit.ini` isn't repo data: it's
  the admin's file in a root-only folder, read through `git config`, and still validated key by key.
  Repo commands (fetch, install, build) run as `<name>-build` through `as_build`; the
  site's process as `<name>`. Secrets reach the build on stdin, never on a command line, and never
  reach the install step. Config files (`.conf`, `host.conf`, `/etc/os-release`) are parsed, never
  sourced.
- **Templates go through `render <template> <VAR>...`** (envsubst with an explicit list). It fails,
  printing nothing, on an unset or empty variable. Never `sed` values into files. Variable-length
  files are rendered in parts and concatenated (decisions 46, 51).
- **Validate on a temp copy, then install**: render to a temp file, check it
  (`caddy validate` run as `caddy`, `systemd-analyze verify` on `<tmp>/unit/shipit-<name>.service`,
  `sshd -t -f`, `apt-config -c`), then install (`install_if_changed`).
- **Atomic switches** go through `atomic_link <target> <link>` (`ln -s target link.new && mv -T
  link.new link`); deploy's switch (C.1) and rollback point `previous` before `current` (decision 60).
- **Caddy is reloaded, never restarted.** Setup overwrites only files marked `# managed by shipit`
  (`//` in apt.conf files; `is_shipit_file`) or a package's untouched default (`may_replace`, dpkg's
  conffile md5); deploy refuses to replace an unmarked unit. Write through `install_if_changed`, so a
  re-run changes no file.
- **Messages** are plain sentences that say what happened and what to do next. Use the exact wording
  the plan gives, and keep README's quotes in step.

## Style and checks

- `shfmt -i 2 -ci -bn` formatting, shellcheck clean. Disable a check only on the line that needs it,
  with a reason.
- `make` = `make lint` (bash -n, shellcheck, shfmt) + `make test` (`bats --jobs 4`, so every test must use only its own `$BATS_TEST_TMPDIR`). GitHub Actions runs it on
  every push to `main` and every PR (Ubuntu, not as root); it passing is the gate before merging. On
  macOS, install `bash`, `bats-core`, `shellcheck`, `shfmt`, `gettext`, `flock` and `parallel` with Homebrew
  (`/bin/bash` is 3.2). Tests that need a missing tool or root skip with a stated reason, or stub it
  (macOS `mv` has no `-T`, so `atomic_mv` stubs it).
- Every rendered template gets a golden file in `test/golden/` and a test comparing against it.

## Making a change

Milestones M0–M7 (plan §8) are done; shipit 1.0.0 is complete.

1. Branch from `origin/main`.
2. Change the code and the plan together (add a decision to plan §9 for any new choice); update
   README.md and this file if what they say changes. Add bats tests for everything testable without
   root or a real host.
3. Run `make`.
4. Open a PR against `main` saying what changed, the decisions taken, and what `make` covers. Merge
   once CI passes.
