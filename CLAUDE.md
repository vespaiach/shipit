# CLAUDE.md

shipit is a bash tool that sets up a Debian 13 VPS (`shipit setup`) and deploys Next.js apps from
GitHub onto it (`shipit deploy`). **docs/plan.md is the spec**: read it before changing anything, and
keep it, README.md and this file in step with the code.

## Layout

- `bin/shipit` — dispatcher. Checks the command against its list, refuses non-root (except `help`),
  sources `lib/common.sh` and `lib/<command>.sh`, and calls `cmd_<command> "$@"`. A new command needs
  its library, an entry in the dispatcher's `case` and a line in `usage`.
- `lib/common.sh` — logging (`log`/`err`/`die`), validators (`check_*`), config reads (`conf_get`),
  locks, prompts, `install_if_changed`, `render`, and the test-seam constants.
- `lib/<command>.sh` — one per command, defining `cmd_<command>`. `lib/deploy.sh` follows plan §3's
  A–D steps (`deploy_*`, called in order by `cmd_deploy`) and also holds the rollback steps
  (`switch_back`), because `HEALTH_FAIL=rollback` runs them. `rollback`, `status`, `logs` and `env`
  source `lib/deploy.sh` to reuse its readers; `restore` sources `lib/backup.sh` and `lib/deploy.sh`. Logic lives in small
  stdin/argument-driven helpers the tests call; the host-touching steps stay thin.
- `libexec/` — what systemd runs: `run` (the process launcher), `backup` (run as `postgres`) and
  `state-backup` (root with only `CAP_SETUID`/`CAP_SETGID`; `tar` runs as the app's user). Each runs its
  main function only when executed, so the tests source it.
- `templates/` — what `render` fills in.
- `install.sh` — copies `bin lib libexec templates` to `/usr/local/lib/shipit`, links
  `/usr/local/bin/shipit`.
- `test/unit/*.bats`, `test/golden/` (expected rendered output), `test/fixtures/`, and
  `test/e2e/run.sh` with `test/e2e/scenarios/NN-name.sh` (Incus VM, by hand). The scenarios share one
  VM and run in name order, so each leaves the VM as the next expects.
- `.github/workflows/check.yml` — CI: runs `make`.
- `reference/tracklite-ops/` — the original scripts being generalised. Read-only; not linted.

## Engineering rules

- **Bash only**, Debian 13's bash 5. `set -euo pipefail` goes in entry points (`bin/shipit`,
  `install.sh`, `libexec/*`), never in libraries.
- **Libraries are side-effect free when sourced**: only constants and functions. Tests source them.
- **Test seams are plain constants** in `common.sh` (`DEPLOY_USER`, `SHIPIT_ETC`, `SHIPIT_VAR`,
  `SHIPIT_OPT`, `SHIPIT_OWNER_UID`, `BACKUP_ROOT`, `STATE_ROOT`). Never read them from the environment or
  add flags for them; tests reassign them after sourcing. Lock helpers take the lock path. Tests stub
  `getent`, `ss`, `systemctl`, `id`, `runuser` and `setpriv` through `PATH`, so call commands by name (no absolute paths,
  no `$EUID`).
- **Validators** are `check_<thing> <value> [app]`: silent on success, print the reason to stderr and
  return 1 on failure. Validate every value read from a config or typed by a person before using it.
- **Root never runs or sources repo content.** It reads repo files as data only (`grep -E`/`awk` with
  strict patterns, `jq`, `git show` as `$DEPLOY_USER`), and release files through `release_cat`. Repo
  commands run through `as_deployer`; secrets reach the build on stdin, never on a command line. Root
  sources only files under `$SHIPIT_ETC`, and only after `check_sourced_file` (or via `conf_get`).
  Root never reads or writes inside an app's state folder (`/var/lib/<app>`): that goes through
  `as_app`, as the app's user.
- **SQL** is built by `sql_*` functions, with names quoted by `sql_ident`/`sql_literal`, and piped to
  `pg_psql`.
- **Templates go through `render <template> <VAR>...`** (envsubst with an explicit list). It fails,
  printing nothing, on an unset or empty variable. Never `sed` values into files.
- **Validate on a temp copy, then install**: render to a temp file, check it (`visudo -cf`,
  `caddy validate`, `systemd-analyze verify`, `nft -c -f`, `sshd -t`), then `install -m`.
- **Atomic switches**: `ln -s target link.new && mv -T link.new link`.
- **Caddy is reloaded, never restarted.** Only overwrite files marked `# managed by shipit` (setup also
  replaces a package's untouched default config, checked against dpkg's conffile md5). Write through
  `install_if_changed`, so a re-run changes no file.
- **Messages** are plain sentences that say what happened and what to do next. Use the exact wording
  the plan gives.

## Style and checks

- `shfmt -i 2 -ci -bn` formatting, shellcheck clean. Disable a check only on the line that needs it,
  with a reason.
- `make lint` (bash -n, shellcheck, shfmt) and `make test` (bats). GitHub Actions runs `make` on every
  push to `main` and every PR (`.github/workflows/check.yml`, Ubuntu, not as root); it passing is the
  gate before merging. On macOS, install `bash`, `bats-core`, `shellcheck`,
  `shfmt`, `gettext` and `flock` with Homebrew (`/bin/bash` is 3.2). Tests that need GNU-only tools or
  root skip with a stated reason.
- Every rendered template gets a golden file in `test/golden/` and a unit test comparing against it.

## Making a change

Milestones S0–S8 (plan §8) are implemented; S5.5 and S7.5 are by-hand Tracklite steps (plan §6) and
aren't done.

1. Branch from `origin/main`.
2. Change the code and the plan together; add bats tests for everything testable without root or a
   VM, and an e2e scenario for anything that needs one.
3. Run `make`.
4. Open a PR against `main` saying what changed, the decisions taken, and what's covered by `make`
   versus e2e only (and whether e2e was actually run). Merge once CI passes.
