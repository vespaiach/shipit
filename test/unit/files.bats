#!/usr/bin/env bats
# install_if_changed and atomic_link.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  load_common
}

@test "install_if_changed installs new content and reports no change otherwise" {
  printf 'a\n' >"$BATS_TEST_TMPDIR/new"
  install_if_changed "$BATS_TEST_TMPDIR/new" "$BATS_TEST_TMPDIR/dest" 640
  [ "$(cat "$BATS_TEST_TMPDIR/dest")" = a ]
  run ! install_if_changed "$BATS_TEST_TMPDIR/new" "$BATS_TEST_TMPDIR/dest" 640
  printf 'b\n' >"$BATS_TEST_TMPDIR/new"
  install_if_changed "$BATS_TEST_TMPDIR/new" "$BATS_TEST_TMPDIR/dest" 640
  [ "$(cat "$BATS_TEST_TMPDIR/dest")" = b ]
}

@test "install_if_changed fixes the mode even when the content is unchanged" {
  printf 'a\n' >"$BATS_TEST_TMPDIR/new"
  install_if_changed "$BATS_TEST_TMPDIR/new" "$BATS_TEST_TMPDIR/dest" 644
  chmod 600 "$BATS_TEST_TMPDIR/dest"
  run ! install_if_changed "$BATS_TEST_TMPDIR/new" "$BATS_TEST_TMPDIR/dest" 644
  [ -z "$(find "$BATS_TEST_TMPDIR/dest" -perm 600)" ]
  [ -n "$(find "$BATS_TEST_TMPDIR/dest" -perm 644)" ]
}

@test "atomic_link creates a link that doesn't exist yet" {
  atomic_mv
  mkdir "$SRV_ROOT/a"
  atomic_link "$SRV_ROOT/a" "$SRV_ROOT/current"
  [ "$(readlink "$SRV_ROOT/current")" = "$SRV_ROOT/a" ]
  [ ! -e "$SRV_ROOT/current.new" ] && [ ! -L "$SRV_ROOT/current.new" ]
}

@test "atomic_link repoints an existing link, without following it into its target" {
  atomic_mv
  mkdir "$SRV_ROOT/a" "$SRV_ROOT/b"
  ln -s "$SRV_ROOT/a" "$SRV_ROOT/current"
  atomic_link "$SRV_ROOT/b" "$SRV_ROOT/current"
  [ "$(readlink "$SRV_ROOT/current")" = "$SRV_ROOT/b" ]
  [ -z "$(ls -A "$SRV_ROOT/a")" ]
  [ -z "$(ls -A "$SRV_ROOT/b")" ]
}

@test "atomic_link replaces a leftover link.new from an interrupted switch" {
  atomic_mv
  mkdir "$SRV_ROOT/a" "$SRV_ROOT/b"
  ln -s "$SRV_ROOT/a" "$SRV_ROOT/current.new"
  atomic_link "$SRV_ROOT/b" "$SRV_ROOT/current"
  [ "$(readlink "$SRV_ROOT/current")" = "$SRV_ROOT/b" ]
  [ ! -e "$SRV_ROOT/current.new" ] && [ ! -L "$SRV_ROOT/current.new" ]
}

@test "atomic_link renames with mv -T, so the switch is one rename(2)" {
  stub mv "printf '%s\\n' \"\$@\" >'$BATS_TEST_TMPDIR/mv.args'"
  atomic_link "$SRV_ROOT/a" "$SRV_ROOT/current"
  [ "$(cat "$BATS_TEST_TMPDIR/mv.args")" = "-T
--
$SRV_ROOT/current.new
$SRV_ROOT/current" ]
}

@test "atomic_link fails when the link can't be written" {
  atomic_mv
  run atomic_link "$SRV_ROOT/a" "$SRV_ROOT/missing/current"
  [ "$status" -ne 0 ]
}
