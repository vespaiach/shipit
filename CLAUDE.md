# CLAUDE.md

shipit is a bash tool that sets up a Debian 13 VPS (`shipit setup`) and deploys Next.js apps from
GitHub onto it (`shipit deploy`). **docs/plan.md is the spec**: read it before changing anything, and
keep it, README.md and this file in step with the code.

## Layout

- `bin/shipit` — dispatcher. Parses the command, refuses non-root (except `help`), sources
  `lib/common.sh`, then `lib/<command>.sh`, and calls `cmd_<command> "$@"`. A command whose library
  doesn't exist yet prints `shipit <command> is not implemented yet.` Adding a command's library is
  all it takes to wire it up.
- `lib/common.sh` — `log`/`err`/`die`, the validators (`check_*`), config reads (`conf_get`,
  `app_using`), `app_name_from_repo`, `allocate_port`, locks (`lock_try`/`lock_wait`/`lock_release`)
  and `render`.
- `lib/<command>.sh` — one file per command, defining `cmd_<command>`. `libexec/` holds what systemd
  runs; `templates/` holds what `render` fills in.
- `install.sh` — copies `bin lib libexec templates` to `/usr/local/lib/shipit`, links
  `/usr/local/bin/shipit`.
- `test/unit/*.bats` (`make test`), `test/golden/` (expected rendered output), `test/fixtures/`,
  `test/e2e/run.sh` plus `test/e2e/scenarios/*.sh` (Incus VM, by hand).
- `reference/tracklite-ops/` — the original scripts being generalised. Read-only; not linted.

## Engineering rules

- **Bash only**, Debian 13's bash 5. `set -euo pipefail` goes in entry points (`bin/shipit`,
  `install.sh`, `libexec/*`), never in libraries.
- **Libraries are side-effect free when sourced**: only constants and functions. Tests source them.
- **Test seams are plain constants** in `common.sh` (`DEPLOY_USER`, `SHIPIT_ETC`, `SHIPIT_VAR`,
  `SHIPIT_OWNER_UID`). Never read them from the environment or add flags for them. Tests reassign
  them after sourcing. Lock helpers take the lock path. Tests stub `getent`, `ss`, `systemctl` and
  `id` through `PATH`, so call those commands by name (no absolute paths, no `$EUID`).
- **Validators** are `check_<thing> <value> [app]`: silent on success, print the reason to stderr and
  return 1 on failure. Validate every value read from a config or typed by a person before using it.
- **Root never runs or sources repo content.** Read repo files as data only (`grep -E` with strict
  patterns, `jq`, `git show` as `$DEPLOY_USER`). Root sources only files under `$SHIPIT_ETC`, and only
  after `check_sourced_file` (or via `conf_get`, which does it).
- **Templates go through `render <template> <VAR>...`** (envsubst with an explicit list). It fails,
  printing nothing, on an unset or empty variable. Never `sed` values into files.
- **Validate on a temp copy, then install**: render to a temp file, check it (`visudo -cf`,
  `caddy validate`, `systemd-analyze verify`, `nft -c -f`, `sshd -t`), then `install -m`.
- **Atomic switches**: `ln -s target link.new && mv -T link.new link`.
- **Caddy is reloaded, never restarted.** Only overwrite files marked `# managed by shipit`.
- **Messages** are plain sentences that say what happened and what to do next. Use the exact wording
  the plan gives (for example the root message and the lock message).
- Keep changes small and in scope. No speculative options or abstractions.

## Style and checks

- `shfmt -i 2 -ci -bn` formatting, shellcheck clean. Disable a check only on the line that needs it,
  with a reason.
- `make lint` (bash -n, shellcheck, shfmt) and `make test` (bats). There's no hosted CI;
  `make` passing locally is the gate before merging. On macOS, `/bin/bash` is 3.2: install `bash`, `bats-core`, `shellcheck`,
  `shfmt`, `gettext` and `flock` with Homebrew so `env bash` finds bash 5. Tests that need GNU-only
  tools or root skip with a stated reason.
- Every rendered template gets a golden file in `test/golden/` and a unit test comparing against it.

## Milestone workflow

Milestones are in plan §8 (S0 … S7). For each one:

1. `git fetch origin && git checkout -B <branch> origin/main`.
2. Implement exactly that milestone's scope from plan §8 and the matching detail in §2–§5.
3. Add bats unit tests for everything testable without root or a VM (plan §7), with golden files for
   rendered templates.
4. Add the milestone's e2e scenarios (plan §7 table) as `test/e2e/scenarios/NN-name.sh`. Each runs
   inside the VM as root from `/root/shipit` after `install.sh`, and exits non-zero on failure.
5. Run `make` locally.
6. Commit, push, open a PR against `main`. The PR body says what's implemented, the decisions taken,
   and what's tested by `make` versus e2e only (and whether e2e was actually run).
7. Merge the PR into `main` once `make` passes, then start the next milestone.
