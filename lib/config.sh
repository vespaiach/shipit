# shellcheck shell=bash
# shipit.ini reading and validation (git config, plan §3), and reading and writing the site configs in
# $SHIPIT_ETC/sites/<name>.conf (plan §4). Sourcing this file only defines constants and functions.
# Needs lib/common.sh (err, check_domain, check_port).

# The keys shipit.ini may contain (plan §3), and those that may repeat.
INI_KEYS=(site.name site.domain site.alias site.type site.health site.env node.install node.build
  node.start static.root data.dir)
INI_MULTI_KEYS=(site.alias site.env data.dir)

# nextjs's node.start default: `next` isn't on the unit's PATH (plan §3).
# shellcheck disable=SC2016 # $PORT is expanded by systemd, not here
INI_NEXTJS_START='./node_modules/.bin/next start -p $PORT'

# ---- Validators ----------------------------------------------------------------------------------

# check_site_name <name>: ^[a-z][a-z0-9-]{0,24}$, so <name>-build fits a 32-character username.
check_site_name() {
  local LC_ALL=C
  [[ $1 =~ ^[a-z][a-z0-9-]{0,24}$ ]] && return 0
  err "Invalid site name '$1': use a lowercase letter, then up to 24 lowercase letters, digits or dashes."
  return 1
}

# check_ref <ref>: a 40-hex commit SHA, or a branch or tag name accepted by
# `git check-ref-format --branch` that doesn't start with '-' (plan §5.2). '@{' is refused before git
# sees it, because --branch would expand @{-N} inside a repo.
check_ref() {
  local LC_ALL=C
  [[ $1 =~ ^[0-9a-f]{40}$ ]] && return 0
  if [[ $1 != -* && $1 != *'@{'* ]] && git check-ref-format --branch "$1" >/dev/null 2>&1; then
    return 0
  fi
  err "Invalid ref '$1': use a 40-character commit SHA or a branch name."
  return 1
}

# check_repo_url <url>: only https://github.com/<owner>/<repo>, optionally ending in .git (plan
# §5.2). Owner: GitHub's user and organisation rule (letters, digits and inner dashes, at most 39).
# Repo: letters, digits, '.', '_' and '-', at most 100, and not '.' or '..'.
check_repo_url() {
  local LC_ALL=C owner='[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?' repo
  repo=${1%.git}
  repo=${repo##*/}
  if [[ $1 =~ ^https://github\.com/$owner/[A-Za-z0-9._-]{1,100}(\.git)?$ ]] \
    && [ "$repo" != . ] && [ "$repo" != .. ] && [ -n "$repo" ]; then
    return 0
  fi
  err "Invalid repo URL '$1': use https://github.com/<owner>/<repo>."
  return 1
}

# repo_slug <url>: prints <owner>/<repo> (without .git) from a URL check_repo_url accepted.
repo_slug() {
  local path=${1#https://github.com/}
  printf '%s\n' "${path%.git}"
}

# repo_ssh_url <url>: prints the SSH URL git uses with a deploy key, git@github.com:<owner>/<repo>.git.
repo_ssh_url() {
  printf 'git@github.com:%s.git\n' "$(repo_slug "$1")"
}

# ---- shipit.ini ----------------------------------------------------------------------------------

# in_list <word> <list>...: whether word is exactly one of the list (a key may contain spaces, from a
# subsection name, so no substring matching).
in_list() {
  local w=$1 item
  shift
  for item; do
    [ "$item" = "$w" ] && return 0
  done
  return 1
}

# ini_value_ok <key> <value>: the per-key pattern of plan §3. Control characters are refused earlier.
ini_value_ok() {
  local LC_ALL=C key=$1 v=$2
  case "$key" in
    site.name) check_site_name "$v" ;;
    site.domain | site.alias) check_domain "$v" ;;
    site.type)
      case "$v" in
        static | node | nextjs) return 0 ;;
      esac
      err "Invalid site.type '$v' in shipit.ini: use static, node or nextjs."
      return 1
      ;;
    site.health)
      [[ $v =~ ^/[A-Za-z0-9._~/-]*$ ]] && return 0
      err "Invalid site.health '$v' in shipit.ini: use a path starting with /, made of letters, digits and . _ ~ / -."
      return 1
      ;;
    site.env)
      [[ $v =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && return 0
      err "Invalid site.env '$v' in shipit.ini: use an environment variable name (letters, digits and _, not starting with a digit)."
      return 1
      ;;
    node.install | node.build)
      [ -n "$v" ] && return 0
      err "$key in shipit.ini is empty: give a command, or leave the key out to use the default."
      return 1
      ;;
    node.start)
      if [ -n "$v" ] && [[ $v != *[\'%\\]* ]]; then
        return 0
      fi
      err "Invalid node.start '$v' in shipit.ini: it can't be empty or contain ', % or \\, because it goes into the systemd unit."
      return 1
      ;;
    static.root)
      if [[ $v =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ && /$v/ != */./* && /$v/ != */../* ]]; then
        return 0
      fi
      err "Invalid static.root '$v' in shipit.ini: use a folder inside the release, like dist or build/out, with no . or .. part."
      return 1
      ;;
    data.dir)
      [[ $v =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]] && return 0
      err "Invalid data.dir '$v' in shipit.ini: use a folder name of lowercase letters, digits, _ and -, with no /."
      return 1
      ;;
  esac
}

# ini_load <file>: parses and validates a shipit.ini (plan §3) with `git config --no-includes -z
# --list`; it's never sourced. On success it sets:
#   INI_NAME INI_DOMAIN INI_TYPE  site.name, site.domain, site.type
#   INI_ALIASES INI_ENV INI_DIRS  arrays: site.alias, site.env, data.dir
#   INI_HEALTH                    site.health, default /
#   INI_HEALTH_STRICT             1 if site.health was set (health_ok's strict mode), else empty
#   INI_INSTALL INI_BUILD         node.install, node.build; empty = use the default, which needs the
#                                 repo (lockfile, package.json) and is picked by the build step
#   INI_START                     node.start; for nextjs defaults to INI_NEXTJS_START
#   INI_ROOT                      static.root
# On failure it prints why and returns 1.
# shellcheck disable=SC2034 # INI_HEALTH_STRICT, INI_INSTALL and INI_BUILD are read by deploy
ini_load() {
  local LC_ALL=C file=$1 out entry key value k bad=() pairs=() line=''
  local -A count=()
  INI_NAME='' INI_DOMAIN='' INI_TYPE='' INI_HEALTH='' INI_HEALTH_STRICT=''
  INI_INSTALL='' INI_BUILD='' INI_START='' INI_ROOT=''
  INI_ALIASES=() INI_ENV=() INI_DIRS=()

  if ! out=$(git config -f "$file" --no-includes --list 2>&1 >/dev/null); then
    [[ $out =~ line\ ([0-9]+) ]] && line=${BASH_REMATCH[1]}
    if [ -n "$line" ]; then
      err "shipit.ini has a syntax error on line $line."
    else
      err "Can't read shipit.ini: ${out#fatal: }"
    fi
    return 1
  fi

  local -a entries keys=() values=()
  # -z: each entry is "key\nvalue" ended by NUL (just "key" when it has no value), so a value can't
  # fake an extra line.
  mapfile -d '' entries < <(git config -f "$file" --no-includes -z --list)
  for entry in "${entries[@]}"; do
    key=${entry%%$'\n'*}
    if [ "$key" = "$entry" ]; then
      err "$key in shipit.ini has no value: write it as $key = <value>."
      return 1
    fi
    keys+=("$key")
    values+=("${entry#*$'\n'}")
  done

  # Unknown keys, all at once. A subsection ([site "x"]) shows up as site.x.<key>, so it's unknown too.
  for key in "${keys[@]}"; do
    in_list "$key" "${INI_KEYS[@]}" || bad+=("$key")
  done
  if [ "${#bad[@]}" -gt 0 ]; then
    err "shipit.ini has unknown keys: ${bad[*]}. Use only site.name, site.domain, site.alias, site.type, site.health, site.env, node.install, node.build, node.start, static.root and data.dir."
    return 1
  fi

  local i
  for i in "${!keys[@]}"; do
    key=${keys[i]} value=${values[i]}
    count[$key]=$((${count[$key]-0} + 1))
    if [ "${count[$key]}" -gt 1 ] && ! in_list "$key" "${INI_MULTI_KEYS[@]}"; then
      err "$key is set more than once in shipit.ini; only site.alias, site.env and data.dir may repeat."
      return 1
    fi
    if [[ $value == *[[:cntrl:]]* ]]; then
      err "$key in shipit.ini contains a control character (such as a newline or tab), which isn't allowed."
      return 1
    fi
    ini_value_ok "$key" "$value" || return 1
    # Repeatable keys: a value given twice is refused rather than silently merged.
    if in_list "$key" "${INI_MULTI_KEYS[@]}"; then
      for k in "${pairs[@]}"; do
        if [ "$k" = "$key=$value" ]; then
          err "$key = $value appears more than once in shipit.ini."
          return 1
        fi
      done
      pairs+=("$key=$value")
    fi
    case "$key" in
      site.name) INI_NAME=$value ;;
      site.domain) INI_DOMAIN=$value ;;
      site.alias) INI_ALIASES+=("$value") ;;
      site.type) INI_TYPE=$value ;;
      site.health) INI_HEALTH=$value INI_HEALTH_STRICT=1 ;;
      site.env) INI_ENV+=("$value") ;;
      node.install) INI_INSTALL=$value ;;
      node.build) INI_BUILD=$value ;;
      node.start) INI_START=$value ;;
      static.root) INI_ROOT=$value ;;
      data.dir) INI_DIRS+=("$value") ;;
    esac
  done

  for key in site.name site.domain site.type; do
    if [ -z "${count[$key]-}" ]; then
      err "shipit.ini needs $key."
      return 1
    fi
  done
  for value in "${INI_ALIASES[@]}"; do
    if [ "$value" = "$INI_DOMAIN" ]; then
      err "site.alias $value in shipit.ini is the same as site.domain; remove the alias."
      return 1
    fi
  done

  case "$INI_TYPE" in
    static)
      if [ -z "$INI_ROOT" ]; then
        err "A static site needs static.root in shipit.ini."
        return 1
      fi
      for key in node.start site.health data.dir; do
        if [ -n "${count[$key]-}" ]; then
          err "$key isn't allowed for a static site: there's no process to run."
          return 1
        fi
      done
      ;;
    node | nextjs)
      if [ -n "$INI_ROOT" ]; then
        err "static.root is only for static sites; remove it from shipit.ini."
        return 1
      fi
      if [ -z "$INI_START" ]; then
        if [ "$INI_TYPE" = node ]; then
          err "A node site needs node.start in shipit.ini."
          return 1
        fi
        INI_START=$INI_NEXTJS_START
      fi
      ;;
  esac
  [ -n "$INI_HEALTH" ] || INI_HEALTH=/
}

# ini_check_name <name> <first deploy: yes|no>: site.name must equal the name the site is deployed as
# (plan §5.2 A.3).
ini_check_name() {
  [ "$INI_NAME" = "$1" ] && return 0
  if [ "$2" = yes ]; then
    err "shipit.ini says the site name is $INI_NAME, but you asked to deploy it as $1."
  else
    err "shipit.ini says the site name is $INI_NAME, but this repo is deployed as $1. Renaming a site isn't supported; change site.name back."
  fi
  return 1
}

# ini_check_type <deployed type>: site.type can't change after the first deploy (decision 15).
ini_check_type() {
  [ "$INI_TYPE" = "$1" ] && return 0
  err "shipit.ini says the site type is $INI_TYPE, but this site is deployed as $1. Changing a site's type isn't supported."
  return 1
}

# ini_check_clash <name>: site.domain and every site.alias must not be the DOMAIN or one of the ALIASES
# of any other site in $SHIPIT_ETC/sites (plan §5.2 A.3). Clashes within shipit.ini are refused by
# ini_load. A broken config of another site fails the check too.
ini_check_clash() {
  local f other hosts host mine
  for f in "$SHIPIT_ETC"/sites/*.conf; do
    [ -e "$f" ] || continue
    other=${f##*/}
    other=${other%.conf}
    [ "$other" = "$1" ] && continue
    hosts=$(
      conf_parse "$f" || exit 1
      [ -z "$CONF_DOMAIN" ] || printf '%s\n' "$CONF_DOMAIN" "${CONF_ALIASES[@]}"
    ) || return 1
    for mine in "$INI_DOMAIN" "${INI_ALIASES[@]}"; do
      while IFS= read -r host; do
        if [ "$host" = "$mine" ]; then
          err "The hostname $mine is already used by the site $other. Remove it from shipit.ini or from $other."
          return 1
        fi
      done <<<"$hosts"
    done
  done
}

# ---- Site configs: $SHIPIT_ETC/sites/<name>.conf -------------------------------------------------
# KEY=value lines (REPO, TYPE, DOMAIN, ALIASES space-separated, PORT), read as data, never sourced.
# A config may hold only REPO (and PORT) while a first deploy is in progress (plan §5.2 A.1).

# conf_parse <file>: sets CONF_REPO CONF_TYPE CONF_DOMAIN CONF_ALIASES (array) CONF_PORT, validating
# every line and value. Blank lines and # comments are allowed; anything else is refused. REPO is
# required; TYPE and DOMAIN come together, and node/nextjs sites need PORT.
conf_parse() {
  local LC_ALL=C file=$1 line key value n=0 alias
  local -A seen=()
  CONF_REPO='' CONF_TYPE='' CONF_DOMAIN='' CONF_PORT='' CONF_ALIASES=()
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    err "Can't read $file."
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [ -z "$line" ] || [[ $line == '#'* ]] && continue
    if [[ ! $line =~ ^(REPO|TYPE|DOMAIN|ALIASES|PORT)=(.*)$ ]] || [ -n "${seen[${BASH_REMATCH[1]}]-}" ]; then
      err "Line $n of $file isn't valid: use each of REPO, TYPE, DOMAIN, ALIASES and PORT at most once, as KEY=value."
      return 1
    fi
    key=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
    seen[$key]=1
    case "$key" in
      REPO)
        check_repo_url "$value" || return 1
        CONF_REPO=$value
        ;;
      TYPE)
        case "$value" in
          static | node | nextjs) CONF_TYPE=$value ;;
          *)
            err "Invalid TYPE '$value' in $file: use static, node or nextjs."
            return 1
            ;;
        esac
        ;;
      DOMAIN)
        check_domain "$value" || return 1
        CONF_DOMAIN=$value
        ;;
      ALIASES)
        read -ra CONF_ALIASES <<<"$value"
        for alias in "${CONF_ALIASES[@]}"; do
          check_domain "$alias" || return 1
        done
        ;;
      PORT)
        if ! [[ $value =~ ^3[0-9]{3}$ ]]; then
          err "Invalid PORT '$value' in $file: use a number from 3000 to 3999."
          return 1
        fi
        CONF_PORT=$value
        ;;
    esac
  done <"$file"
  if [ -z "$CONF_REPO" ]; then
    err "$file has no REPO line."
    return 1
  fi
  if [[ -n $CONF_TYPE && -z $CONF_DOMAIN || -z $CONF_TYPE && -n $CONF_DOMAIN ]]; then
    err "$file must have both TYPE and DOMAIN, or neither."
    return 1
  fi
  if [ -z "$CONF_DOMAIN" ] && [ "${#CONF_ALIASES[@]}" -gt 0 ]; then
    err "$file has ALIASES but no DOMAIN."
    return 1
  fi
  if [[ $CONF_TYPE == node || $CONF_TYPE == nextjs ]] && [ -z "$CONF_PORT" ]; then
    err "$file has no PORT, which a $CONF_TYPE site needs."
    return 1
  fi
}

# site_conf_read <name>: conf_parse of $SHIPIT_ETC/sites/<name>.conf.
site_conf_read() {
  check_site_name "$1" || return 1
  if [ ! -e "$SHIPIT_ETC/sites/$1.conf" ]; then
    err "There's no site named $1. Deploy it first with: shipit deploy <repo-url> $1"
    return 1
  fi
  conf_parse "$SHIPIT_ETC/sites/$1.conf"
}

# site_conf_write <name>: writes the CONF_* globals to $SHIPIT_ETC/sites/<name>.conf (root, 0644: it
# holds nothing secret). The new content is checked with conf_parse first, and replaces the old file in
# one rename(2), so another deploy reading it for its clash check never sees half a file. An unchanged
# file isn't touched.
site_conf_write() {
  local dest=$SHIPIT_ETC/sites/$1.conf tmp
  check_site_name "$1" || return 1
  tmp=$(mktemp "$SHIPIT_ETC/sites/.$1.conf.XXXXXX") || return 1
  {
    printf '# managed by shipit (shipit deploy and rollback write this file)\n'
    printf 'REPO=%s\n' "$CONF_REPO"
    [ -z "$CONF_TYPE" ] || printf 'TYPE=%s\n' "$CONF_TYPE"
    [ -z "$CONF_DOMAIN" ] || printf 'DOMAIN=%s\n' "$CONF_DOMAIN"
    [ "${#CONF_ALIASES[@]}" -eq 0 ] || printf 'ALIASES=%s\n' "${CONF_ALIASES[*]}"
    [ -z "$CONF_PORT" ] || printf 'PORT=%s\n' "$CONF_PORT"
  } >"$tmp"
  if ! (conf_parse "$tmp") || ! chmod 644 "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
    rm -f -- "$tmp"
    chmod 644 "$dest"
    return 0
  fi
  mv -f -- "$tmp" "$dest"
}

# site_next_port: prints the lowest port from 3000 to 3999 that no site config has. Only the site
# configs are checked, not listening sockets: 3000-3999 is kept for shipit's sites.
site_next_port() {
  local f port
  local -A used=()
  for f in "$SHIPIT_ETC"/sites/*.conf; do
    [ -e "$f" ] || continue
    port=$(conf_parse "$f" && printf '%s' "$CONF_PORT") || return 1
    [ -z "$port" ] || used[$port]=1
  done
  for ((port = 3000; port <= 3999; port++)); do
    if [ -z "${used[$port]-}" ]; then
      printf '%s\n' "$port"
      return 0
    fi
  done
  err "No free port left from 3000 to 3999: every one is taken by a site."
  return 1
}
