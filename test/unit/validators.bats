#!/usr/bin/env bats
# check_domain and check_port (syntax only; clashes with other sites come with lib/config.sh), health_ok
# and check_env_key.

setup() {
  load helpers
  load_common
}

@test "domain: accepts valid hostnames, silently" {
  for d in app.example.com a.b x-1.example.co.uk app.localhost "$(printf 'a%.0s' {1..63}).com"; do
    run check_domain "$d"
    [ "$status" -eq 0 ] && [ -z "$output" ] || {
      echo "refused $d"
      return 1
    }
  done
}

@test "domain: refuses invalid hostnames, saying why" {
  for d in '' localhost App.example.com example.com. '*.example.com' -a.example.com a-.example.com \
    'a..example.com' .example.com 'a_b.example.com' 'a b.com' "$(printf 'a%.0s' {1..64}).com" 'a.com;x' \
    $'a.com\nb.com'; do
    run check_domain "$d"
    [ "$status" -eq 1 ] || {
      echo "accepted $d"
      return 1
    }
  done
  run check_domain App.example.com
  [ "$output" = "Invalid domain 'App.example.com': use a lowercase hostname with at least one dot, like app.example.com." ]
}

@test "domain: the message goes to stderr" {
  run bash -c '. "$1/lib/common.sh"; check_domain bad 2>/dev/null' _ "$REPO_ROOT"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "port: accepts 1024 to 65535, silently" {
  for p in 1024 3000 3999 65535; do
    run check_port "$p"
    [ "$status" -eq 0 ] && [ -z "$output" ] || {
      echo "refused $p"
      return 1
    }
  done
}

@test "port: refuses anything else, saying why" {
  for p in '' 0 80 1023 65536 99999 03001 3001x ' 3001' -1 100000000000000000000 $'3001\n3002'; do
    run check_port "$p"
    [ "$status" -eq 1 ] || {
      echo "accepted $p"
      return 1
    }
  done
  run check_port 80
  [ "$output" = "Invalid port '80': use a number from 1024 to 65535." ]
}

# ---- Health --------------------------------------------------------------------------------------

@test "health: any answer below 500 counts" {
  local code
  for code in 200 204 301 308 401 404 499; do
    run health_ok "$code"
    [ "$status" -eq 0 ] || {
      echo "refused $code"
      return 1
    }
  done
  for code in 500 502 503 000 '' abc 99 600; do
    run health_ok "$code"
    [ "$status" -eq 1 ] || {
      echo "accepted $code"
      return 1
    }
  done
}

# ---- Environment variable names --------------------------------------------------------------------

@test "env key: letters, digits and _, not starting with a digit" {
  . "$REPO_ROOT/lib/config.sh"
  local k
  for k in DATABASE_URL _x a1 A; do
    run check_env_key "$k"
    [ "$status" -eq 0 ] && [ -z "$output" ] || {
      echo "refused $k"
      return 1
    }
  done
  for k in '' 1A A-B 'A B' /q 'A=b' $'A\nB'; do
    run check_env_key "$k"
    [ "$status" -eq 1 ] || {
      echo "accepted $k"
      return 1
    }
  done
  run check_env_key 1A
  [ "$output" = "Invalid name '1A': use letters, digits and _, not starting with a digit." ]
}
