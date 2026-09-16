#!/bin/bash
# Validate 02-users.sh logic in the WSL test bed for mluser2
set -euo pipefail
PUBKEY_DIR=/tmp/pubtest
GROUP=slurmusers

getent group ${GROUP} >/dev/null || groupadd ${GROUP}

id mluser2 >/dev/null 2>&1 && userdel -r mluser2 2>/dev/null || true

for u in mluser2; do
  useradd -m -s /bin/bash -G ${GROUP} ${u}
  passwd -d ${u} 2>/dev/null || true
  passwd -l ${u} 2>/dev/null || true
  cat > /etc/sudoers.d/${u} <<EOF2
${u} ALL=(ALL) NOPASSWD:ALL
EOF2
  chmod 440 /etc/sudoers.d/${u}
  visudo -cf /etc/sudoers.d/${u} >/dev/null
  KEYFILE=${PUBKEY_DIR}/${u}.pub
  if [[ -f "${KEYFILE}" ]]; then
    install -d -m 700 -o ${u} -g ${u} /home/${u}/.ssh
    install -m 600 -o ${u} -g ${u} "${KEYFILE}" /home/${u}/.ssh/authorized_keys
    echo "key installed"
  else
    echo "NO KEY"
  fi
done
echo USERS_OK
