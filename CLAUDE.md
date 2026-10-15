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
  `render`, `install_if_changed`, `atomic_link`, `health_ok`, and the test-seam constants.
- `lib/config.sh` — `shipit.ini` reading and validation (`git config`), and the site configs in
  `/etc/shipit/sites/<name>.conf`.
- `lib/<command>.sh` — one per command (`setup`, `deploy`, `rollback`, `remote`), defining
  `cmd_<command>`. Logic lives in small stdin/argument-driven helpers the tests call; the host-touching
  steps stay thin.
- `templates/` — what `render` fills in.
- `install.sh` — copies `bin lib templates` to `/usr/local/lib/shipit`, links `/usr/local/bin/shipit`.
- `test/unit/*.bats` (bats-core, shared set-up in `test/unit/helpers.bash`), `test/golden/` (expected
  rendered output), `test/fixtures/`.
- `.github/workflows/check.yml` — CI: runs `make`.

## Engineering rules

- **Bash only**, bash 5 as on Debian 13 and Ubuntu 26.04. `set -euo pipefail` goes in entry points
  (`bin/shipit`, `install.sh`), never in libraries.
- **Libraries are side-effect free when sourced**: only constants and functions. Tests source them.
- **Test seams are plain constants** in `common.sh`: `SHIPIT_ETC` (`/etc/shipit`), `SHIPIT_VAR`
  (`/var/lib/shipit`), `SRV_ROOT` (`/srv`) and `SHIPIT_TEMPLATES` (`templates/` next to `lib/`). Never
  read them from the environment or add flags for them; tests reassign them after sourcing. Lock
  helpers take the lock path. Tests stub commands such as `id` and `mv` through `PATH`, so call
  commands by name (no absolute paths, no `$EUID`).
- **Validators** are `check_<thing> <value>`: silent on success, print the reason to stderr and return
  1 on failure. Validate every value read from a config or `shipit.ini`, or typed by a person, before
  using it.
- **Root never runs or sources repo code.** It reads repo files as data only (`shipit.ini` through
  `git config`, never sourced). Repo commands (fetch, install, build) run as `<name>-build`, and the
  site's process as `<name>`. Secrets reach the build on stdin, never on a command line.
- **Templates go through `render <template> <VAR>...`** (envsubst with an explicit list). It fails,
  printing nothing, on an unset or empty variable. Never `sed` values into files.
- **Validate on a temp copy, then install**: render to a temp file, check it (`visudo -cf`,
  `caddy validate`, `systemd-analyze verify`, `sshd -t`), then `install -m`.
- **Atomic switches** go through `atomic_link <target> <link>` (`ln -s target link.new && mv -T
  link.new link`).
- **Caddy is reloaded, never restarted.** Only overwrite files marked `# managed by shipit` (setup
  also replaces a package's untouched default config, checked against dpkg's conffile md5). Write
  through `install_if_changed`, so a re-run changes no file.
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

Milestones M0–M7 are in plan §8. M0 (skeleton, dispatcher, helpers) is implemented; M1–M7 are to do.

1. Branch from `origin/main`.
2. Change the code and the plan together; add bats tests for everything testable without root.
3. Run `make`.
4. Open a PR against `main` saying what changed, the decisions taken, and what's covered by `make`.
   Merge once CI passes.
