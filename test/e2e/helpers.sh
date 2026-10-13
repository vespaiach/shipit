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
