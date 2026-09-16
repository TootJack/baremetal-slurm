#!/usr/bin/env bash
# =====================================================================
# 02-users.sh - Create ML users with passwordless sudo + SSH pubkey auth
# Run ONCE on the CONTROLLER (node1). Home is on the shared FS so it
# propagates to both nodes; munge/slurm only need matching UIDs.
#
# Usage:  sudo bash 02-users.sh
#
# Before running: put each user's PUBLIC key (id_ed25519.pub content,
# one line per file) into ./pubkeys/<username>.pub
# =====================================================================
set -euo pipefail

PUBKEY_DIR="${PUBKEY_DIR:-./pubkeys}"
GROUP="slurmusers"

echo "==> Creating group ${GROUP}"
getent group "${GROUP}" >/dev/null || groupadd "${GROUP}"

# ---------------------------------------------------------------
# Users to create. Add more entries as needed.
# Each must have ${PUBKEY_DIR}/<name>.pub present.
# ---------------------------------------------------------------
USERS="${USERS:-mluser1 mluser2 mluser3}"

for u in ${USERS}; do
  echo "==> Setting up user: ${u}"

  # 1. Create the user with a fixed shell
  if ! id "${u}" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G "${GROUP}" "${u}"
    echo "    created uid=$(id -u ${u})"
  else
    usermod -aG "${GROUP}" "${u}"
  fi

  # 2. Lock password login completely (SSH keys are the only way in)
  passwd -d "${u}" 2>/dev/null || true
  passwd -l "${u}" 2>/dev/null || true

  # 3. Passwordless sudo (SOW: "all users also have sudo rights to test")
  cat > "/etc/sudoers.d/${u}" <<EOF
${u} ALL=(ALL) NOPASSWD:ALL
EOF
  chmod 440 "/etc/sudoers.d/${u}"
  visudo -cf "/etc/sudoers.d/${u}" >/dev/null || {
    echo "!!! sudoers syntax error for ${u}, aborting"; exit 1; }

  # 4. Install the user's ed25519 public key
  KEYFILE="${PUBKEY_DIR}/${u}.pub"
  if [[ -f "${KEYFILE}" ]]; then
    install -d -m 700 -o "${u}" -g "${u}" "/home/${u}/.ssh"
    install -m 600 -o "${u}" -g "${u}" "${KEYFILE}" "/home/${u}/.ssh/authorized_keys"
    echo "    installed ${KEYFILE}"
  else
    echo "    !!! WARNING: ${KEYFILE} not found - user will have no SSH access"
    echo "    !!! Generate on the user's machine: ssh-keygen -t ed25519"
  fi
done

# ---------------------------------------------------------------
# Slurm admin account (operator) - same treatment
# ---------------------------------------------------------------
if ! id "slurmadmin" >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G "${GROUP}" slurmadmin
  passwd -d slurmadmin 2>/dev/null || true
  passwd -l slurmadmin 2>/dev/null || true
  cat > /etc/sudoers.d/slurmadmin <<'EOF'
slurmadmin ALL=(ALL) NOPASSWD:ALL
EOF
  chmod 440 /etc/sudoers.d/slurmadmin
  KEYFILE="${PUBKEY_DIR}/slurmadmin.pub"
  if [[ -f "${KEYFILE}" ]]; then
    install -d -m 700 -o slurmadmin -g slurmadmin /home/slurmadmin/.ssh
    install -m 600 -o slurmadmin -g slurmadmin "${KEYFILE}" /home/slurmadmin/.ssh/authorized_keys
  fi
  echo "==> Created slurmadmin (operator account)"
fi

echo "==> 02-users.sh DONE"
echo "    Verify with: ssh -i ~/.ssh/id_ed25519 <user>@<node> 'sudo -n whoami'"
