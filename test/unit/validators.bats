#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2034 # stub bodies are single-quoted on purpose; tests set lib variables
# Validators from plan §2 "Validation", with getent, ss and systemctl stubbed through PATH.

setup() {
  load helpers
  load_common
}

@test "app name: accepts valid names" {
  for name in a tracklite my_app app2 "a$(printf 'b%.0s' {1..30})"; do
    run check_app_name "$name"
    [ "$status" -eq 0 ] || {
      echo "refused $name"
      return 1
    }
  done
}

@test "app name: refuses invalid names" {
  for name in '' 1app _app My_app my-app my.app 'a b' "a$(printf 'b%.0s' {1..31})" 'app;rm' 'äpp'; do
    run check_app_name "$name"
    [ "$status" -eq 1 ] || {
      echo "accepted $name"
      return 1
    }
  done
  [[ $output == *"Invalid app name"* ]]
}

@test "app user: a missing user is fine" {
  stub getent 'exit 2'
  run check_app_user tracklite
  [ "$status" -eq 0 ]
}

@test "app user: a user marked 'shipit app' is fine" {
  stub getent 'echo "tracklite:x:998:998:shipit app:/home/tracklite:/usr/sbin/nologin"'
  run check_app_user tracklite
  [ "$status" -eq 0 ]
}

@test "app user: an unmarked user is refused" {
  stub getent 'echo "postgres:x:105:110:PostgreSQL administrator,,,:/var/lib/postgresql:/bin/bash"'
  run check_app_user postgres
  [ "$status" -eq 1 ]
  [[ $output == *"wasn't created by shipit"* ]]
}

@test "app units: no existing units is fine" {
  stub systemctl 'echo "No files found for $2." >&2; exit 1'
  run check_app_units myapp
  [ "$status" -eq 0 ]
}

@test "app units: units marked as shipit's are fine" {
  stub systemctl 'printf "# /etc/systemd/system/%s\n# managed by shipit\n[Unit]\n" "$3"'
  run check_app_units myapp
  [ "$status" -eq 0 ]
}

@test "app units: a foreign template unit is refused" {
  stub systemctl '[ "$3" = "getty@.service" ] || exit 1; printf "# /usr/lib/systemd/system/getty@.service\n#  SPDX-License-Identifier: LGPL-2.1-or-later\n[Unit]\n"'
  run check_app_units getty
  [ "$status" -eq 1 ]
  [[ $output == *"getty@.service already exists"* ]]
}

@test "app units: a foreign target is refused" {
  stub systemctl '[ "$3" = "user.target" ] || exit 1; printf "# /usr/lib/systemd/system/user.target\n[Unit]\n"'
  run check_app_units user
  [ "$status" -eq 1 ]
  [[ $output == *"user.target already exists"* ]]
}

@test "process name: accepts and refuses" {
  for name in web worker web_2 w; do
    run check_process_name "$name"
    [ "$status" -eq 0 ]
  done
  for name in '' Web 2web _web web-2 'web;x' '$(id)'; do
    run check_process_name "$name"
    [ "$status" -eq 1 ] || {
      echo "accepted $name"
      return 1
    }
  done
}

@test "domain: accepts valid hostnames" {
  for d in app.example.com a.b x-1.example.co.uk app.localhost "$(printf 'a%.0s' {1..63}).com"; do
    run check_domain "$d"
    [ "$status" -eq 0 ] || {
      echo "refused $d"
      return 1
    }
  done
}

@test "domain: refuses invalid hostnames" {
  for d in '' localhost App.example.com example.com. '*.example.com' -a.example.com a-.example.com \
    'a..example.com' .example.com 'a_b.example.com' 'a b.com' "$(printf 'a%.0s' {1..64}).com" 'a.com;x'; do
    run check_domain "$d"
    [ "$status" -eq 1 ] || {
      echo "accepted $d"
      return 1
    }
  done
}

@test "domain: refuses one another app uses, allows the app's own" {
  write_app_conf one 'DOMAIN=one.example.com' 'PORT=3001'
  run check_domain one.example.com two
  [ "$status" -eq 1 ]
  [[ $output == *"already used by the app one"* ]]
  run check_domain one.example.com one
  [ "$status" -eq 0 ]
  run check_domain two.example.com two
  [ "$status" -eq 0 ]
}

@test "port: accepts and refuses by syntax and range" {
  for p in 1024 3001 65535; do
    run check_port "$p"
    [ "$status" -eq 0 ]
  done
  for p in '' 0 80 1023 65536 99999 03001 3001x ' 3001' -1 100000000000000000000; do
    run check_port "$p"
    [ "$status" -eq 1 ] || {
      echo "accepted $p"
      return 1
    }
  done
}

@test "port: refuses one another app uses, allows the app's own" {
  write_app_conf one 'DOMAIN=one.example.com' 'PORT=3001'
  run check_port 3001 two
  [ "$status" -eq 1 ]
  [[ $output == *"already used by the app one"* ]]
  run check_port 3001 one
  [ "$status" -eq 0 ]
}

@test "port free: refuses a port something listens on" {
  stub ss 'printf "LISTEN 0 511 127.0.0.1:3001 0.0.0.0:*\nLISTEN 0 128 [::]:22 [::]:*\n"'
  stub systemctl 'exit 1'
  run check_port_free 3001 myapp
  [ "$status" -eq 1 ]
  [[ $output == *"already listening on port 3001"* ]]
  run check_port_free 22 myapp
  [ "$status" -eq 1 ]
  run check_port_free 3002 myapp
  [ "$status" -eq 0 ]
}

@test "port free: a port is not matched by its suffix" {
  stub ss 'echo "LISTEN 0 511 127.0.0.1:13001 0.0.0.0:*"'
  stub systemctl 'exit 1'
  run check_port_free 3001 myapp
  [ "$status" -eq 0 ]
}

@test "port free: skips the listening check when the app's unit already sets that port" {
  stub ss 'echo "LISTEN 0 511 127.0.0.1:3001 0.0.0.0:*"'
  stub systemctl '[ "$3" = "myapp@.service" ] || exit 1; printf "# /etc/systemd/system/myapp@.service\n# managed by shipit\nEnvironment=NODE_ENV=production PORT=3001\n"'
  run check_port_free 3001 myapp
  [ "$status" -eq 0 ]
  run check_port_free 3001 other
  [ "$status" -eq 1 ]
}

@test "port free: a unit with a different port doesn't skip the check" {
  stub ss 'echo "LISTEN 0 511 127.0.0.1:3001 0.0.0.0:*"'
  stub systemctl 'printf "# /etc/systemd/system/myapp@.service\nEnvironment=NODE_ENV=production PORT=30011\n"'
  run check_port_free 3001 myapp
  [ "$status" -eq 1 ]
}

@test "repo: accepts GitHub, ssh and file URLs" {
  for r in https://github.com/vespaiach/tracklite https://github.com/vespaiach/tracklite.git \
    git@github.com:vespaiach/tracklite.git ssh://git@localhost/srv/git/app.git file:///srv/git/app.git; do
    run check_repo "$r"
    [ "$status" -eq 0 ] || {
      echo "refused $r"
      return 1
    }
  done
}

@test "repo: refuses other URLs" {
  for r in '' https://gitlab.com/a/b http://github.com/a/b https://github.com/a git@github.com:a/b \
    'https://github.com/a/b c' 'https://github.com/a/b;rm' 'file:///a b' --upload-pack=x github.com/a/b \
    https://github.com/a/b/c; do
    run check_repo "$r"
    [ "$status" -eq 1 ] || {
      echo "accepted $r"
      return 1
    }
  done
}

@test "env value: accepts plain values, including blank" {
  for v in '' abc 'postgres://u:p@localhost:5432/db?ssl=1' 'a b c' 'x=$y' 'a#b'; do
    run check_env_value "$v"
    [ "$status" -eq 0 ] || {
      echo "refused $v"
      return 1
    }
  done
}

@test "env value: refuses quotes, backslashes, newlines and edge whitespace" {
  for v in 'a"b' "a'b" 'a\b' $'a\nb' ' a' 'a ' $'\ta' $'a\t'; do
    run check_env_value "$v"
    [ "$status" -eq 1 ] || {
      echo "accepted [$v]"
      return 1
    }
  done
}

@test "sourced file: accepts an owned file not writable by others" {
  write_app_conf one 'PORT=3001'
  run check_sourced_file "$SHIPIT_ETC/apps/one.conf"
  [ "$status" -eq 0 ]
}

@test "sourced file: refuses group- or world-writable files" {
  write_app_conf one 'PORT=3001'
  for mode in 664 646 666; do
    chmod "$mode" "$SHIPIT_ETC/apps/one.conf"
    run check_sourced_file "$SHIPIT_ETC/apps/one.conf"
    [ "$status" -eq 1 ] || {
      echo "accepted mode $mode"
      return 1
    }
  done
}

@test "sourced file: refuses a file owned by someone else" {
  write_app_conf one 'PORT=3001'
  SHIPIT_OWNER_UID=0
  [ "$(id -u)" -ne 0 ] || skip "running as root, so the file is owned by root"
  run check_sourced_file "$SHIPIT_ETC/apps/one.conf"
  [ "$status" -eq 1 ]
  [[ $output == *"must be owned by root"* ]]
}

@test "sourced file: refuses missing files, directories and symlinks" {
  write_app_conf one 'PORT=3001'
  ln -s "$SHIPIT_ETC/apps/one.conf" "$SHIPIT_ETC/link.conf"
  for f in "$SHIPIT_ETC/missing.conf" "$SHIPIT_ETC/apps" "$SHIPIT_ETC/link.conf"; do
    run check_sourced_file "$f"
    [ "$status" -eq 1 ] || {
      echo "accepted $f"
      return 1
    }
  done
}

@test "uniqueness checks refuse to source an unsafe config" {
  write_app_conf one 'DOMAIN=one.example.com'
  chmod 666 "$SHIPIT_ETC/apps/one.conf"
  run check_domain two.example.com two
  [ "$status" -eq 1 ]
  [[ $output == *"not writable by group or others"* ]]
}

@test "admin user: accepts root and login names" {
  for name in root ops my-admin a_1 "a$(printf 'b%.0s' {1..31})"; do
    run check_admin_user "$name"
    [ "$status" -eq 0 ] || {
      echo "refused $name"
      return 1
    }
  done
}

@test "admin user: refuses invalid names and the deploy account" {
  for name in '' Ops 1ops -ops 'o ps' 'ops;id' deployer "a$(printf 'b%.0s' {1..32})"; do
    run check_admin_user "$name"
    [ "$status" -eq 1 ] || {
      echo "accepted $name"
      return 1
    }
  done
}

@test "email: accepts plain addresses" {
  for email in owner@example.com first.last+tls@mail.example.co.uk a_b%c@x-y.io; do
    run check_email "$email"
    [ "$status" -eq 0 ] || {
      echo "refused $email"
      return 1
    }
  done
}

@test "email: refuses anything that could break host.conf or the Caddyfile" {
  for email in '' owner owner@example 'a b@example.com' 'a@example.com }' '$(id)@example.com' 'a@b.com;x' "a@b.com
x"; do
    run check_email "$email"
    [ "$status" -eq 1 ] || {
      echo "accepted $email"
      return 1
    }
  done
}

@test "branch: accepts usual branch names" {
  for b in main master develop release/1.2 feature_x v2.0; do
    run check_branch "$b"
    [ "$status" -eq 0 ] || {
      echo "refused $b"
      return 1
    }
  done
}

@test "branch: refuses names git or a shell would misread" {
  for b in '' -main 'a..b' 'main/' main.lock 'a b' 'main;rm' '$(id)' .hidden; do
    run check_branch "$b"
    [ "$status" -eq 1 ] || {
      echo "accepted $b"
      return 1
    }
  done
}

@test "redact query: accepts names separated by single spaces" {
  for q in token 'token code' 'a.b x-y z_1'; do
    run check_redact_query "$q"
    [ "$status" -eq 0 ] || {
      echo "refused $q"
      return 1
    }
  done
}

@test "redact query: refuses anything that could break the Caddy site" {
  for q in '' ' token' 'token ' 'a  b' 'a}' 'a{' '*' 'a;b' $'a\nb'; do
    run check_redact_query "$q"
    [ "$status" -eq 1 ] || {
      echo "accepted $q"
      return 1
    }
  done
}

@test "database: accepts Postgres-safe names up to 63 characters" {
  for name in a tracklite my_app2 "a$(printf 'b%.0s' {1..62})"; do
    run check_database "$name"
    [ "$status" -eq 0 ] || {
      echo "refused $name"
      return 1
    }
  done
}

@test "database: refuses names that need quoting or are too long" {
  for name in '' 1db My_db my-db 'a b' 'db;drop' 'a"b' "a'b" "a$(printf 'b%.0s' {1..63})"; do
    run check_database "$name"
    [ "$status" -eq 1 ] || {
      echo "accepted $name"
      return 1
    }
  done
  [[ $output == *"Invalid DATABASE"* ]]
}

@test "database: unique across apps, except the app's own" {
  write_app_conf one 'DATABASE=shared'
  run check_database shared two
  [ "$status" -eq 1 ]
  [[ $output == *"already used by the app one"* ]]
  run check_database shared one
  [ "$status" -eq 0 ]
}
