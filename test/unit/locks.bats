#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2034 # stub bodies are single-quoted on purpose; tests set lib variables
# Lock helpers: they take the lock file's path, so tests use a temp file.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  load_common
  command -v flock >/dev/null || skip "flock (util-linux) isn't installed"
  lock=$BATS_TEST_TMPDIR/app.lock
}

# hold_lock: holds $lock in a background process until $BATS_TEST_TMPDIR/release exists.
hold_lock() {
  flock "$lock" bash -c "touch '$BATS_TEST_TMPDIR/held'; while [ ! -e '$BATS_TEST_TMPDIR/release' ]; do sleep 0.1; done" &
  while [ ! -e "$BATS_TEST_TMPDIR/held" ]; do sleep 0.1; done
}

teardown() {
  touch "$BATS_TEST_TMPDIR/release"
  wait || true
}

@test "lock_try takes a free lock and creates the file" {
  lock_try "$lock"
  [ -e "$lock" ]
  [ -n "$LOCK_FD" ]
  run ! flock -n "$lock" true
}

@test "lock_try fails at once when the lock is held" {
  hold_lock
  run lock_try "$lock"
  [ "$status" -eq 1 ]
}

@test "lock_release frees the lock" {
  lock_try "$lock"
  lock_release
  flock -n "$lock" true
}

@test "two locks can be held at once" {
  lock_try "$lock"
  app_fd=$LOCK_FD
  lock_try "$BATS_TEST_TMPDIR/build.lock"
  [ "$app_fd" != "$LOCK_FD" ]
  run ! flock -n "$lock" true
  run ! flock -n "$BATS_TEST_TMPDIR/build.lock" true
}

@test "lock_wait takes a free lock silently" {
  run lock_wait "$lock" "Waiting for another app's build…"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "lock_wait prints its message and waits for a held lock" {
  hold_lock
  (sleep 1 && touch "$BATS_TEST_TMPDIR/release") &
  run lock_wait "$lock" "Waiting for another app's build…"
  [ "$status" -eq 0 ]
  [ "$output" = "Waiting for another app's build…" ]
}

@test "the lock is released when the holder exits" {
  (lock_try "$lock")
  flock -n "$lock" true
}
