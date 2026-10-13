# shellcheck shell=bash
# Shared helpers for the e2e scenarios. Sourced inside the VM, as root, from /root/shipit.

E2E_KEY=/root/.ssh/e2e_key
SSH_COMMON=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# e2e_ssh_ready: openssh-server and sshpass installed, and E2E_KEY in root's authorized_keys.
e2e_ssh_ready() {
  if ! command -v sshd >/dev/null || ! command -v sshpass >/dev/null; then
    apt-get update -q >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q openssh-server sshpass >/dev/null
  fi
  install -d -m 700 /root/.ssh
  [ -f "$E2E_KEY" ] || ssh-keygen -q -t ed25519 -N '' -f "$E2E_KEY"
  grep -qxF "$(cat "$E2E_KEY.pub")" /root/.ssh/authorized_keys 2>/dev/null \
    || cat "$E2E_KEY.pub" >>/root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
  systemctl enable --now ssh >/dev/null 2>&1
}

# key_ssh <user> <command>: runs the command over SSH to localhost, logging in with E2E_KEY only.
key_ssh() {
  local user=$1
  shift
  ssh "${SSH_COMMON[@]}" -o BatchMode=yes -o PasswordAuthentication=no -i "$E2E_KEY" "$user@localhost" "$@"
}

# password_ssh <user> <password> <command>: the same, logging in with a password only.
password_ssh() {
  local user=$1 password=$2
  shift 2
  sshpass -p "$password" ssh "${SSH_COMMON[@]}" -o PubkeyAuthentication=no \
    -o PreferredAuthentications=password,keyboard-interactive "$user@localhost" "$@"
}

# etc_checksums: one line per file in /etc, to compare before and after a run.
etc_checksums() {
  find /etc -xdev -type f -print0 | sort -z | xargs -0 sha256sum
}

# setup sleeps first in SSH sessions, so journald has the session's "Accepted publickey" line.
# shellcheck disable=SC2034 # used by the scenarios that source this file
SETUP_OVER_SSH='sleep 2; shipit setup'

# make_repo <name> <fixture dir>: a bare repo at /srv/git/<name>.git holding the fixture as one commit
# on main, owned by deployer (git refuses to fetch from a repo another user owns). Prints its file://
# URL.
make_repo() {
  local name=$1 src=$2 work
  work=$(mktemp -d)
  cp -R "$src/." "$work/"
  git -C "$work" init -q -b main
  git -C "$work" add -A
  git -C "$work" -c user.name=e2e -c user.email=e2e@localhost commit -q -m fixture
  rm -rf "/srv/git/$name.git"
  install -d -m 755 /srv/git
  git clone -q --bare "$work" "/srv/git/$name.git"
  rm -rf "$work"
  chown -R deployer: "/srv/git/$name.git"
  printf 'file:///srv/git/%s.git\n' "$name"
}

# short_sha <name>: the 7-character sha of main in /srv/git/<name>.git.
short_sha() {
  git -c safe.directory='*' -C "/srv/git/$1.git" rev-parse --short=7 main
}

# served <domain>: prints the page Caddy serves for the domain over HTTPS (Caddy's own CA for *.localhost).
served() {
  curl -fsSk --max-time 20 --resolve "$1:443:127.0.0.1" "https://$1/"
}

# add_line <bare repo> <file> <line>: commits <line> appended to <file> on main of the bare repo, keeping
# the repo's owner. Prints the new commit's 7-character sha.
add_line() {
  local repo=$1 file=$2 line=$3 owner work
  owner=$(stat -c %U "$repo")
  work=$(mktemp -d)
  git -c safe.directory='*' clone -q "$repo" "$work"
  printf '%s\n' "$line" >>"$work/$file"
  git -C "$work" add -A
  git -C "$work" -c user.name=e2e -c user.email=e2e@localhost commit -q -m "add $line to $file"
  git -c safe.directory='*' -C "$work" push -q origin main
  git -C "$work" rev-parse --short=7 HEAD
  rm -rf "$work"
  chown -R "$owner:" "$repo"
}

# remove_file <bare repo> <file>: commits the file's removal on main of the bare repo, keeping the repo's
# owner. Prints the new commit's 7-character sha.
remove_file() {
  local repo=$1 file=$2 owner work
  owner=$(stat -c %U "$repo")
  work=$(mktemp -d)
  git -c safe.directory='*' clone -q "$repo" "$work"
  git -C "$work" rm -q "$file"
  git -C "$work" -c user.name=e2e -c user.email=e2e@localhost commit -q -m "remove $file"
  git -c safe.directory='*' -C "$work" push -q origin main
  git -C "$work" rev-parse --short=7 HEAD
  rm -rf "$work"
  chown -R "$owner:" "$repo"
}

# deploy_ok <app or url> [args...]: deploys with no terminal, printing the output, and fails the scenario
# if the deploy fails. Leaves the output in $out.
deploy_ok() {
  out=$(shipit deploy "$@" </dev/null 2>&1) || {
    echo "$out"
    fail "shipit deploy $* failed"
  }
  echo "$out"
}

# in_terminal <command>: runs the command in a pseudo-terminal, so deploy's hidden prompts are asked,
# feeding it this function's stdin as typed answers. Exits with the command's status.
in_terminal() {
  script -qec "$1" /dev/null
}
