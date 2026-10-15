#!/usr/bin/env bats
# lib/config.sh: shipit.ini parsing and validation (plan §3), the type/clash checks of plan §5.2
# A.3, the ref and repo URL rules, and the site configs in $SHIPIT_ETC/sites (plan §4).

setup() {
  load helpers
  load_common
  # shellcheck source=lib/config.sh
  . "$REPO_ROOT/lib/config.sh"
  FIX=$REPO_ROOT/test/fixtures/ini
  mkdir -p "$SHIPIT_ETC/sites"
}

# refused <fixture> <expected message>: ini_load refuses the fixture with exactly that message.
refused() {
  run ini_load "$FIX/$1.ini"
  [ "$status" -eq 1 ] || {
    echo "accepted $1"
    return 1
  }
  [ "$output" = "$2" ] || {
    echo "got: $output"
    return 1
  }
}

# write_ini <section.key> <value>: writes $BATS_TEST_TMPDIR/s.ini, a nextjs site with that key set (or,
# for site.domain and site.type, replaced). The value is quoted, so git turns \t or \n into
# the real character.
write_ini() {
  local domain=blog.example.com type=nextjs extra=''
  case "$1" in
    site.domain) domain=$2 ;;
    site.type) type=$2 ;;
    *) extra=$(printf '[%s]\n%s = "%s"' "${1%%.*}" "${1#*.}" "$2") ;;
  esac
  printf '[site]\ndomain = "%s"\ntype = "%s"\n%s\n' "$domain" "$type" "$extra" \
    >"$BATS_TEST_TMPDIR/s.ini"
}

# conf <name> <content>: writes a site config.
conf() {
  printf '%s\n' "$2" >"$SHIPIT_ETC/sites/$1.conf"
}

# ---- The plan's examples -------------------------------------------------------------------------

@test "ini: the full example parses, silently" {
  run ini_load "$FIX/full.ini"
  [ "$status" -eq 0 ] && [ -z "$output" ]
  ini_load "$FIX/full.ini"
  [ "$INI_DOMAIN" = blog.example.com ] && [ "$INI_TYPE" = nextjs ]
  [ "${INI_ALIASES[*]}" = www.blog.example.com ]
  [ "${INI_ENV[*]}" = 'DATABASE_URL NEXT_PUBLIC_API' ]
  [ "$INI_INSTALL" = 'pnpm install --frozen-lockfile' ] && [ "$INI_BUILD" = 'pnpm build' ]
  [ "$INI_START" = 'pnpm start' ]
  [ "${INI_DIRS[*]}" = 'uploads db' ]
  [ -z "$INI_ROOT" ]
}

@test "ini: the minimal static example" {
  ini_load "$FIX/static.ini"
  [ "$INI_DOMAIN" = docs.example.com ] && [ "$INI_TYPE" = static ]
  [ "$INI_ROOT" = dist ]
  [ "${#INI_ALIASES[@]}" -eq 0 ] && [ "${#INI_ENV[@]}" -eq 0 ] && [ "${#INI_DIRS[@]}" -eq 0 ]
  [ -z "$INI_INSTALL" ] && [ -z "$INI_BUILD" ] && [ -z "$INI_START" ]
}

@test "ini: the minimal node example" {
  ini_load "$FIX/node.ini"
  [ "$INI_TYPE" = node ] && [ "$INI_START" = 'node server.js' ] && [ "${INI_DIRS[*]}" = uploads ]
}

@test "ini: the minimal nextjs example gets the start default" {
  ini_load "$FIX/nextjs.ini"
  # shellcheck disable=SC2016 # literal: systemd expands $PORT
  [ "$INI_START" = './node_modules/.bin/next start -p $PORT' ]
  # node.install and node.build defaults need the repo: left empty for the build step.
  [ -z "$INI_INSTALL" ] && [ -z "$INI_BUILD" ]
}

@test "ini: section and key names are case-insensitive" {
  ini_load "$FIX/uppercase.ini"
  [ "$INI_DOMAIN" = blog.example.com ]
}

@test "ini: a second load starts from scratch" {
  ini_load "$FIX/full.ini"
  ini_load "$FIX/static.ini"
  [ "${#INI_ALIASES[@]}" -eq 0 ] && [ -z "$INI_START" ]
}

# ---- Structure -----------------------------------------------------------------------------------

@test "ini: a syntax error fails with the line" {
  refused syntax-error 'shipit.ini has a syntax error on line 2.'
}

@test "ini: an unknown key is refused, naming it" {
  refused unknown-key 'shipit.ini has unknown keys: site.domian. Use only site.domain, site.alias, site.type, site.env, node.install, node.build, node.start, static.root and data.dir.'
}

@test "ini: an unknown section is refused" {
  run ini_load "$FIX/unknown-section.ini"
  [ "$status" -eq 1 ] && [[ $output == 'shipit.ini has unknown keys: build.cmd. '* ]]
}

@test "ini: a subsection is refused, even one that spells out allowed keys" {
  run ini_load "$FIX/subsection.ini"
  [ "$status" -eq 1 ] && [[ $output == 'shipit.ini has unknown keys: site.name site.domain. '* ]]
}

@test "ini: site.name is refused as an unknown key" {
  refused site-name 'shipit.ini has unknown keys: site.name. Use only site.domain, site.alias, site.type, site.env, node.install, node.build, node.start, static.root and data.dir.'
}

@test "ini: [include] is refused and never read" {
  # Read with includes, included.ini would supply the missing static.root and site.evil.
  run git config -f "$FIX/include.ini" --includes --list
  [[ $output == *static.root=dist* ]]
  refused include 'shipit.ini has unknown keys: include.path. Use only site.domain, site.alias, site.type, site.env, node.install, node.build, node.start, static.root and data.dir.'
}

@test "ini: a single-value key given twice is refused" {
  refused duplicate 'site.domain is set more than once in shipit.ini; only site.alias, site.env and data.dir may repeat.'
}

@test "ini: a key without a value is refused" {
  refused no-value 'site.type in shipit.ini has no value: write it as site.type = <value>.'
}

@test "ini: required keys" {
  printf '[site]\ntype = nextjs\n' >"$BATS_TEST_TMPDIR/s.ini"
  run ini_load "$BATS_TEST_TMPDIR/s.ini"
  [ "$status" -eq 1 ] && [ "$output" = 'shipit.ini needs site.domain.' ]
  : >"$BATS_TEST_TMPDIR/s.ini"
  run ini_load "$BATS_TEST_TMPDIR/s.ini"
  [ "$status" -eq 1 ] && [ "$output" = 'shipit.ini needs site.domain.' ]
  refused static-no-root 'A static site needs static.root in shipit.ini.'
  refused node-no-start 'A node site needs node.start in shipit.ini.'
}

# ---- Values --------------------------------------------------------------------------------------

@test "ini: an unquoted # cuts the value; a quoted one is kept" {
  ini_load "$FIX/hash-unquoted.ini"
  [ "$INI_START" = 'node server.js --tag=' ]
  ini_load "$FIX/hash-quoted.ini"
  [ "$INI_START" = 'node server.js --tag=#1' ]
}

@test "ini: node.start with \\n, ', % or \\ is refused" {
  refused start-newline "node.start in shipit.ini contains a control character (such as a newline or tab), which isn't allowed."
  refused start-quote "Invalid node.start 'node -e 'x'' in shipit.ini: it can't be empty or contain ', % or \\, because it goes into the systemd unit."
  refused start-percent "Invalid node.start 'node server.js %h' in shipit.ini: it can't be empty or contain ', % or \\, because it goes into the systemd unit."
  refused start-backslash "Invalid node.start 'node server.js \\' in shipit.ini: it can't be empty or contain ', % or \\, because it goes into the systemd unit."
}

@test "ini: control characters are refused in every key" {
  local key
  for key in site.domain site.alias site.type site.env node.install node.build node.start \
    static.root data.dir; do
    write_ini "$key" 'a\tb'
    run ini_load "$BATS_TEST_TMPDIR/s.ini"
    [ "$status" -eq 1 ] && [ "$output" = "$key in shipit.ini contains a control character (such as a newline or tab), which isn't allowed." ] || {
      echo "$key: $output"
      return 1
    }
  done
}

@test "ini: data.dir must be a plain folder name" {
  refused dir-dotdot "Invalid data.dir '../x' in shipit.ini: use a folder name of lowercase letters, digits, _ and -, with no /."
  refused dir-slash "Invalid data.dir 'a/b' in shipit.ini: use a folder name of lowercase letters, digits, _ and -, with no /."
  refused dir-duplicate 'data.dir = db appears more than once in shipit.ini.'
}

@test "ini: [data] on a static site is refused" {
  refused data-static "data.dir isn't allowed for a static site: there's no process to run."
}

@test "ini: static.root must stay inside the release" {
  refused root-dotdot "Invalid static.root '../x' in shipit.ini: use a folder inside the release, like dist or build/out, with no . or .. part."
  local root
  for root in . .. ./dist dist/. a/../b /dist dist/ 'a b' a//b; do
    printf '[site]\ndomain = d.example.com\ntype = static\n[static]\nroot = "%s"\n' "$root" \
      >"$BATS_TEST_TMPDIR/s.ini"
    run ini_load "$BATS_TEST_TMPDIR/s.ini"
    [ "$status" -eq 1 ] || {
      echo "accepted $root"
      return 1
    }
  done
  for root in dist build/out .output/public a..b v1.2; do
    printf '[site]\ndomain = d.example.com\ntype = static\n[static]\nroot = "%s"\n' "$root" \
      >"$BATS_TEST_TMPDIR/s.ini"
    ini_load "$BATS_TEST_TMPDIR/s.ini" || {
      echo "refused $root"
      return 1
    }
  done
}

@test "ini: site.health is an unknown key" {
  printf '[site]\ndomain = blog.example.com\ntype = nextjs\nhealth = /api/health\n' >"$BATS_TEST_TMPDIR/s.ini"
  run ini_load "$BATS_TEST_TMPDIR/s.ini"
  [ "$status" -eq 1 ]
  [ "$output" = 'shipit.ini has unknown keys: site.health. Use only site.domain, site.alias, site.type, site.env, node.install, node.build, node.start, static.root and data.dir.' ]
}

@test "ini: other per-key patterns" {
  local kv
  for kv in site.domain=localhost site.type=php \
    site.alias=-x.example.com site.env=1X site.env=A-B; do
    write_ini "${kv%%=*}" "${kv#*=}"
    run ini_load "$BATS_TEST_TMPDIR/s.ini"
    [ "$status" -eq 1 ] || {
      echo "accepted $kv"
      return 1
    }
  done
  write_ini site.type php
  run ini_load "$BATS_TEST_TMPDIR/s.ini"
  [ "$output" = "Invalid site.type 'php' in shipit.ini: use static, node or nextjs." ]
  write_ini site.env A-B
  run ini_load "$BATS_TEST_TMPDIR/s.ini"
  [ "$output" = "Invalid site.env 'A-B' in shipit.ini: use an environment variable name (letters, digits and _, not starting with a digit)." ]
  write_ini node.install ''
  run ini_load "$BATS_TEST_TMPDIR/s.ini"
  [ "$output" = 'node.install in shipit.ini is empty: give a command, or leave the key out to use the default.' ]
}

@test "ini: an alias equal to the domain, or given twice, is refused" {
  refused alias-is-domain 'site.alias blog.example.com in shipit.ini is the same as site.domain; remove the alias.'
  printf '[site]\ndomain = b.example.com\ntype = nextjs\nalias = w.example.com\nalias = w.example.com\n' \
    >"$BATS_TEST_TMPDIR/s.ini"
  run ini_load "$BATS_TEST_TMPDIR/s.ini"
  [ "$status" -eq 1 ] && [ "$output" = 'site.alias = w.example.com appears more than once in shipit.ini.' ]
}

@test "ini: keys that don't fit the type are refused" {
  printf '[site]\ndomain = d.example.com\ntype = static\n[node]\nstart = x\n[static]\nroot = dist\n' \
    >"$BATS_TEST_TMPDIR/s.ini"
  run ini_load "$BATS_TEST_TMPDIR/s.ini"
  [ "$output" = "node.start isn't allowed for a static site: there's no process to run." ]
  printf '[site]\ndomain = b.example.com\ntype = nextjs\n[static]\nroot = out\n' >"$BATS_TEST_TMPDIR/s.ini"
  run ini_load "$BATS_TEST_TMPDIR/s.ini"
  [ "$output" = 'static.root is only for static sites; remove it from shipit.ini.' ]
  # A static site may still have node.install and node.build.
  printf '[site]\ndomain = d.example.com\ntype = static\n[node]\nbuild = vite build\n[static]\nroot = dist\n' \
    >"$BATS_TEST_TMPDIR/s.ini"
  ini_load "$BATS_TEST_TMPDIR/s.ini"
  [ "$INI_BUILD" = 'vite build' ]
}

# ---- Asking for a shipit.ini (plan §5.2 A.2b) ----------------------------------------------------

@test "ask: a static site (domain, type, root) gives a file ini_load accepts" {
  run ini_ask "$BATS_TEST_TMPDIR/a.ini" <<<$'docs.example.com\nstatic\ndist'
  [ "$status" -eq 0 ]
  [[ $output == *'Domain (for example blog.example.com):'* ]]
  [[ $output == *'Folder Caddy serves, inside the release (for example dist):'* ]]
  ini_load "$BATS_TEST_TMPDIR/a.ini"
  [ "$INI_DOMAIN" = docs.example.com ] && [ "$INI_TYPE" = static ] && [ "$INI_ROOT" = dist ]
  [ "${#INI_DIRS[@]}" -eq 0 ] && [ -z "$INI_BUILD" ] && [ -z "$INI_START" ]
}

@test "ask: a node site (build, start, two data sub-folders)" {
  run ini_ask "$BATS_TEST_TMPDIR/a.ini" <<<$'api.example.com\nnode\nnpm run build\nnode server.js\nuploads\ndb\n'
  [ "$status" -eq 0 ]
  [[ $output == *'Build command (Enter for the default):'* ]]
  # shellcheck disable=SC2016 # literal: the prompt shows $PORT
  [[ $output == *'Start command; it must listen on $PORT (for example node server.js):'* ]]
  [[ $output == *'Data sub-folder the site can write to, kept across deploys (for example uploads; Enter for none):'* ]]
  [[ $output == *'Another data sub-folder (Enter when done):'* ]]
  ini_load "$BATS_TEST_TMPDIR/a.ini"
  [ "$INI_DOMAIN" = api.example.com ] && [ "$INI_TYPE" = node ]
  [ "$INI_BUILD" = 'npm run build' ] && [ "$INI_START" = 'node server.js' ]
  [ "${INI_DIRS[*]}" = 'uploads db' ] && [ -z "$INI_ROOT" ]
}

@test "ask: a nextjs site can skip everything; a skipped build and start leave their keys out" {
  run ini_ask "$BATS_TEST_TMPDIR/a.ini" <<<$'blog.example.com\nnextjs\n\n\n\n'
  [ "$status" -eq 0 ]
  [ "$(git config -f "$BATS_TEST_TMPDIR/a.ini" --list)" = 'site.domain=blog.example.com
site.type=nextjs' ]
  ini_load "$BATS_TEST_TMPDIR/a.ini"
  # shellcheck disable=SC2016 # literal: systemd expands $PORT
  [ "$INI_START" = './node_modules/.bin/next start -p $PORT' ]
  [ -z "$INI_BUILD" ] && [ "${#INI_DIRS[@]}" -eq 0 ]
}

@test "ask: a bad or empty required answer is asked again" {
  run ini_ask "$BATS_TEST_TMPDIR/a.ini" <<<$'Docs.example.com\n\ndocs.example.com\nphp\n\nstatic\n\n../x\ndist'
  [ "$status" -eq 0 ]
  [[ $output == *"Invalid domain 'Docs.example.com'"* ]]
  [[ $output == *"Invalid domain ''"* ]]
  [[ $output == *"Invalid site.type 'php' in shipit.ini"* ]]
  [[ $output == *"Invalid static.root '' in shipit.ini"* ]]
  [[ $output == *"Invalid static.root '../x' in shipit.ini"* ]]
  ini_load "$BATS_TEST_TMPDIR/a.ini"
  [ "$INI_DOMAIN" = docs.example.com ] && [ "$INI_ROOT" = dist ]
  # A node site must give node.start, but the build is optional.
  run ini_ask "$BATS_TEST_TMPDIR/b.ini" <<<$'api.example.com\nnode\n\n\nnode server.js\n\n'
  [ "$status" -eq 0 ]
  [[ $output == *"Invalid node.start '' in shipit.ini"* ]]
  ini_load "$BATS_TEST_TMPDIR/b.ini"
  [ -z "$INI_BUILD" ] && [ "$INI_START" = 'node server.js' ]
}

@test "ask: an invalid data sub-folder is asked again, a repeated one is kept once" {
  run ini_ask "$BATS_TEST_TMPDIR/a.ini" <<<$'api.example.com\nnode\n\nnode server.js\nUp/loads\nuploads\ndb\nuploads\n\n'
  [ "$status" -eq 0 ]
  [[ $output == *"Invalid data.dir 'Up/loads' in shipit.ini"* ]]
  ini_load "$BATS_TEST_TMPDIR/a.ini"
  [ "${INI_DIRS[*]}" = 'uploads db' ]
}

@test "ask: a control character is refused and asked again" {
  run ini_ask "$BATS_TEST_TMPDIR/a.ini" <<<$'docs.example.com\nstatic\nd\tist\ndist'
  [ "$status" -eq 0 ]
  [[ $output == *"static.root in shipit.ini contains a control character"* ]]
  ini_load "$BATS_TEST_TMPDIR/a.ini"
  [ "$INI_ROOT" = dist ]
}

@test "ask: a value with # and ; round-trips" {
  run ini_ask "$BATS_TEST_TMPDIR/a.ini" <<<$'api.example.com\nnode\nmake "a" ; echo #1\nnode server.js --tag=#1\n\n'
  [ "$status" -eq 0 ]
  ini_load "$BATS_TEST_TMPDIR/a.ini"
  [ "$INI_BUILD" = 'make "a" ; echo #1' ] && [ "$INI_START" = 'node server.js --tag=#1' ]
}

@test "ask: the end of input returns 1 and leaves no file" {
  run ini_ask "$BATS_TEST_TMPDIR/a.ini" </dev/null
  [ "$status" -eq 1 ] && [ ! -e "$BATS_TEST_TMPDIR/a.ini" ]
  run ini_ask "$BATS_TEST_TMPDIR/a.ini" < <(printf 'docs.example.com\nstatic\n')
  [ "$status" -eq 1 ] && [ ! -e "$BATS_TEST_TMPDIR/a.ini" ]
  run ini_ask "$BATS_TEST_TMPDIR/a.ini" < <(printf 'api.example.com\nnode\n\nnode server.js\n')
  [ "$status" -eq 1 ] && [ ! -e "$BATS_TEST_TMPDIR/a.ini" ]
}

@test "ask: a last answer without a newline counts" {
  run ini_ask "$BATS_TEST_TMPDIR/a.ini" < <(printf 'docs.example.com\nstatic\ndist')
  [ "$status" -eq 0 ]
  ini_load "$BATS_TEST_TMPDIR/a.ini"
  [ "$INI_ROOT" = dist ]
}

# ---- Type (plan §5.2 A.3) ---------------------------------------------------------------

@test "type: a changed type is refused" {
  ini_load "$FIX/full.ini"
  run ini_check_type nextjs
  [ "$status" -eq 0 ] && [ -z "$output" ]
  run ini_check_type static
  [ "$status" -eq 1 ]
  [ "$output" = "shipit.ini says the site type is nextjs, but this site is deployed as static. Changing a site's type isn't supported." ]
}

# ---- Validators ----------------------------------------------------------------------------------

@test "site name: the plan's pattern" {
  local n
  for n in a blog my-site a1 abcdefghijklmnopqrstuvwxy; do
    run check_site_name "$n"
    [ "$status" -eq 0 ] && [ -z "$output" ] || {
      echo "refused $n"
      return 1
    }
  done
  for n in '' 1a -a Blog my_site 'a b' abcdefghijklmnopqrstuvwxyz $'a\nb' ../a; do
    run check_site_name "$n"
    [ "$status" -eq 1 ] || {
      echo "accepted $n"
      return 1
    }
  done
  run check_site_name Blog
  [ "$output" = "Invalid site name 'Blog': use a lowercase letter, then up to 24 lowercase letters, digits or dashes." ]
}

@test "ref: SHAs and branch names are accepted" {
  local r
  for r in 0123456789abcdef0123456789abcdef01234567 main feature/x v1.0.0 release-2026; do
    run check_ref "$r"
    [ "$status" -eq 0 ] && [ -z "$output" ] || {
      echo "refused $r"
      return 1
    }
  done
}

@test "ref: anything starting with - and invalid names are refused" {
  local r
  for r in -x --upload-pack=x '' 'a b' a..b 'x.lock' '@{-1}' 'a@{1}' HEAD $'a\nb' 'a~1' 'a^' 'a:b'; do
    run check_ref "$r"
    [ "$status" -eq 1 ] || {
      echo "accepted $r"
      return 1
    }
  done
  run check_ref --upload-pack=x
  [ "$output" = "Invalid ref '--upload-pack=x': use a 40-character commit SHA or a branch name." ]
}

@test "repo url: only https://github.com/<owner>/<repo>[.git]" {
  local u
  for u in https://github.com/vespaiach/shipit https://github.com/vespaiach/shipit.git \
    https://github.com/a/b https://github.com/my-org/my.repo_1 https://github.com/o/.github; do
    run check_repo_url "$u"
    [ "$status" -eq 0 ] && [ -z "$output" ] || {
      echo "refused $u"
      return 1
    }
  done
  for u in '' http://github.com/a/b https://gitlab.com/a/b https://github.com/a https://github.com/a/b/ \
    https://github.com/a/b/c git@github.com:a/b.git https://github.com/-a/b https://github.com/a-/b \
    https://github.com/a/.. https://github.com/a/. https://github.com/a/..git https://github.com/a/.git \
    'https://github.com/a/b c' https://github.com/a/b?x https://user@github.com/a/b \
    "https://github.com/$(printf 'a%.0s' {1..40})/b" $'https://github.com/a/b\nx'; do
    run check_repo_url "$u"
    [ "$status" -eq 1 ] || {
      echo "accepted $u"
      return 1
    }
  done
  run check_repo_url http://github.com/a/b
  [ "$output" = "Invalid repo URL 'http://github.com/a/b': use https://github.com/<owner>/<repo>." ]
}

@test "repo url: slug and SSH URL" {
  [ "$(repo_slug https://github.com/vespaiach/shipit)" = vespaiach/shipit ]
  [ "$(repo_slug https://github.com/vespaiach/shipit.git)" = vespaiach/shipit ]
  [ "$(repo_ssh_url https://github.com/vespaiach/shipit)" = git@github.com:vespaiach/shipit.git ]
  [ "$(repo_ssh_url https://github.com/vespaiach/shipit.git)" = git@github.com:vespaiach/shipit.git ]
}

# ---- Site configs --------------------------------------------------------------------------------

@test "conf: write then read gives back the same values" {
  CONF_REPO=https://github.com/me/blog CONF_TYPE=nextjs CONF_DOMAIN=blog.example.com
  CONF_ALIASES=(www.blog.example.com blog.example.org) CONF_PORT=3001
  site_conf_write blog
  [ "$(stat -c %a "$SHIPIT_ETC/sites/blog.conf" 2>/dev/null || stat -f %Lp "$SHIPIT_ETC/sites/blog.conf")" = 644 ]
  [ "$(cat "$SHIPIT_ETC/sites/blog.conf")" = "# managed by shipit (shipit deploy writes this file)
REPO=https://github.com/me/blog
TYPE=nextjs
DOMAIN=blog.example.com
ALIASES=www.blog.example.com blog.example.org
PORT=3001" ]
  CONF_REPO='' CONF_TYPE='' CONF_DOMAIN='' CONF_ALIASES=() CONF_PORT=''
  site_conf_read blog
  [ "$CONF_REPO" = https://github.com/me/blog ] && [ "$CONF_TYPE" = nextjs ]
  [ "$CONF_DOMAIN" = blog.example.com ] && [ "$CONF_PORT" = 3001 ]
  [ "${CONF_ALIASES[*]}" = 'www.blog.example.com blog.example.org' ]
  # No temp files left behind.
  [ "$(find "$SHIPIT_ETC/sites" -type f | wc -l | tr -d ' ')" = 1 ]
}

@test "conf: a first deploy in progress holds only REPO" {
  CONF_REPO=https://github.com/me/docs CONF_TYPE='' CONF_DOMAIN='' CONF_ALIASES=() CONF_PORT=''
  site_conf_write docs
  [ "$(grep -v '^#' "$SHIPIT_ETC/sites/docs.conf")" = REPO=https://github.com/me/docs ]
  CONF_REPO=x
  site_conf_read docs
  [ "$CONF_REPO" = https://github.com/me/docs ] && [ -z "$CONF_TYPE" ] && [ "${#CONF_ALIASES[@]}" -eq 0 ]
}

@test "conf: an unchanged write leaves the file alone" {
  CONF_REPO=https://github.com/me/docs CONF_TYPE=static CONF_DOMAIN=docs.example.com CONF_ALIASES=() CONF_PORT=''
  site_conf_write docs
  touch -t 202001010000 "$SHIPIT_ETC/sites/docs.conf"
  site_conf_write docs
  [ -z "$(find "$SHIPIT_ETC/sites/docs.conf" -newermt 2021-01-01)" ]
}

@test "conf: invalid values aren't written" {
  CONF_REPO=https://github.com/me/blog CONF_TYPE=nextjs CONF_DOMAIN=blog.example.com CONF_ALIASES=() CONF_PORT=80
  run site_conf_write blog
  [ "$status" -eq 1 ] && [[ $output == "Invalid PORT '80' in "* ]]
  [ ! -e "$SHIPIT_ETC/sites/blog.conf" ]
  [ -z "$(ls -A "$SHIPIT_ETC/sites")" ]
  run site_conf_write ../x
  [ "$status" -eq 1 ]
}

@test "conf: junk lines, unknown or repeated keys and bad values are refused" {
  local body
  for body in 'REPO=https://github.com/me/a
junk' 'REPO=https://github.com/me/a
NAME=a' 'REPO=https://github.com/me/a
REPO=https://github.com/me/b' ' REPO=https://github.com/me/a' 'REPO = https://github.com/me/a' \
    'REPO=https://github.com/me/a
TYPE=php
DOMAIN=a.example.com' 'REPO=https://github.com/me/a
TYPE=static
DOMAIN=A.example.com' 'REPO=https://github.com/me/a
TYPE=static
DOMAIN=a.example.com
ALIASES=www.a.example.com bad' 'REPO=https://github.com/me/a
TYPE=node
DOMAIN=a.example.com
PORT=4000' 'REPO=https://github.com/me/a
TYPE=node
DOMAIN=a.example.com' 'REPO=https://github.com/me/a
TYPE=static' 'TYPE=static
DOMAIN=a.example.com' 'REPO=https://github.com/me/a;x' 'REPO=https://github.com/me/a
PORT=3000x'; do
    conf a "$body"
    run site_conf_read a
    [ "$status" -eq 1 ] || {
      echo "accepted: $body"
      return 1
    }
  done
  conf a 'REPO=https://github.com/me/a
NAME=a'
  run site_conf_read a
  [ "$output" = "Line 2 of $SHIPIT_ETC/sites/a.conf isn't valid: use each of REPO, TYPE, DOMAIN, ALIASES and PORT at most once, as KEY=value." ]
}

@test "conf: a missing site or a bad name" {
  run site_conf_read nosuch
  [ "$status" -eq 1 ]
  [ "$output" = "There's no site named nosuch. Deploy it first with: shipit deploy <repo-url> nosuch" ]
  run site_conf_read ../etc
  [ "$status" -eq 1 ] && [[ $output == "Invalid site name '../etc'"* ]]
}

# ---- Clashes and ports ---------------------------------------------------------------------------

@test "clash: another site's domain is refused, naming the hostname and the site" {
  conf docs 'REPO=https://github.com/me/docs
TYPE=static
DOMAIN=blog.example.com'
  ini_load "$FIX/full.ini"
  run ini_check_clash blog
  [ "$status" -eq 1 ]
  [ "$output" = 'The hostname blog.example.com is already used by the site docs. Remove it from shipit.ini or from docs.' ]
}

@test "clash: another site's alias is refused, also against our alias" {
  conf docs 'REPO=https://github.com/me/docs
TYPE=static
DOMAIN=docs.example.com
ALIASES=x.example.com www.blog.example.com'
  ini_load "$FIX/full.ini"
  run ini_check_clash blog
  [ "$status" -eq 1 ]
  [ "$output" = 'The hostname www.blog.example.com is already used by the site docs. Remove it from shipit.ini or from docs.' ]
}

@test "clash: the site's own config and unrelated sites don't clash" {
  conf blog 'REPO=https://github.com/me/blog
TYPE=nextjs
DOMAIN=blog.example.com
ALIASES=www.blog.example.com
PORT=3000'
  conf docs 'REPO=https://github.com/me/docs
TYPE=static
DOMAIN=docs.example.com'
  conf new 'REPO=https://github.com/me/new'
  ini_load "$FIX/full.ini"
  run ini_check_clash blog
  [ "$status" -eq 0 ] && [ -z "$output" ]
}

@test "clash: a broken config of another site fails the check" {
  conf docs 'junk'
  ini_load "$FIX/full.ini"
  run ini_check_clash blog
  [ "$status" -eq 1 ]
}

@test "port: the lowest port no site has" {
  run site_next_port
  [ "$output" = 3000 ]
  conf a 'REPO=https://github.com/me/a
TYPE=node
DOMAIN=a.example.com
PORT=3000'
  conf b 'REPO=https://github.com/me/b
PORT=3001'
  conf c 'REPO=https://github.com/me/c
TYPE=node
DOMAIN=c.example.com
PORT=3003'
  conf d 'REPO=https://github.com/me/d'
  run site_next_port
  [ "$status" -eq 0 ] && [ "$output" = 3002 ]
}

@test "port: none left" {
  local p
  for ((p = 3000; p <= 3999; p++)); do
    conf "s$p" "REPO=https://github.com/me/s
PORT=$p"
  done
  run site_next_port
  [ "$status" -eq 1 ] && [ "$output" = 'No free port left from 3000 to 3999: every one is taken by a site.' ]
}
