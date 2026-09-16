#!/usr/bin/env bash
# =====================================================================
# 04-slurm-compute.sh - slurmd on a compute node (run on NODE 2)
#
# Usage:
#   sudo CTRL_HOST=<node1-hostname> bash 04-slurm-compute.sh
# =====================================================================
set -euo pipefail

# shared helpers (needrestart, defensive users, shared storage)
source "$(dirname "$0")/lib.sh"
disable_needrestart


# CTRL_HOST is now OPTIONAL: munge.key and slurm.conf are read from shared
# storage (Lustre), so this node needs no ssh access to the controller.
CTRL_HOST="${CTRL_HOST:-hgx01}"
CLUSTER_NAME="${CLUSTER_NAME:-i3dpoc}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "!! This script must run as root.  Use:  sudo bash $0"
  exit 1
fi

echo "==> Slurm compute node setup on $(hostname -s)"
echo "    controller: ${CTRL_HOST}"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq slurmd slurm-client munge

# ---------------------------------------------------------------
# Resolve shared storage (Lustre). 01-base.sh wrote this on both nodes.
# Using Lustre means node 2 needs NO ssh access to the controller.
# ---------------------------------------------------------------
[[ -f /etc/slurm-poc-shared.conf ]] && source /etc/slurm-poc-shared.conf
SHARED_ROOT="${SHARED_ROOT:-/shared}"
STAGE="${SHARED_ROOT}/cluster-config"       # controller publishes to here

# ---------------------------------------------------------------
# 1. Munge - key must be IDENTICAL to the controller's
#    Create the user/group defensively: on these nodes a vendor Slurm
#    replacement left `chown munge:` failing with "invalid spec".
# ---------------------------------------------------------------
getent group munge >/dev/null 2>&1 || groupadd -r munge
if ! getent passwd munge >/dev/null 2>&1; then
  useradd -r -g munge -d /var/lib/munge -s /usr/sbin/nologin munge 2>/dev/null \
    || useradd -r -g munge -d /var/lib/munge -s /bin/false munge
fi
mkdir -p /etc/munge /var/lib/munge /var/log/munge /run/munge
chown -R munge:munge /etc/munge /var/lib/munge /var/log/munge 2>/dev/null || true
chmod 0700 /etc/munge /var/lib/munge

if [[ -s "${STAGE}/munge.key" ]]; then
  echo "    taking munge key from shared storage (${STAGE})"
  install -o munge -g munge -m 400 "${STAGE}/munge.key" /etc/munge/munge.key
elif [[ ! -s /etc/munge/munge.key ]]; then
  echo "    !! no munge key in shared storage and none locally."
  echo "       Run 03-slurm-controller.sh on ${CTRL_HOST} first - it publishes"
  echo "       the key to ${STAGE}/munge.key"
  exit 1
fi
chown munge:munge /etc/munge/munge.key
chmod 400 /etc/munge/munge.key
systemctl enable --now munge 2>/dev/null || systemctl restart munge
sleep 1
munge -n | unmunge 2>/dev/null | grep -q "STATUS:.*Success" \
  || { echo "!! munge failed"; journalctl -u munge -n 10 --no-pager; exit 1; }
echo "    munge OK  (md5: $(md5sum < /etc/munge/munge.key | cut -c1-16))"

# ---------------------------------------------------------------
# 2. slurm.conf - must be byte-identical to the controller's
# ---------------------------------------------------------------
mkdir -p /etc/slurm /var/spool/slurmd /var/log/slurm
if [[ -f "${STAGE}/slurm.conf" ]]; then
  echo "    taking slurm.conf from shared storage"
  install -m 644 "${STAGE}/slurm.conf" /etc/slurm/slurm.conf
else
  echo "    !! ${STAGE}/slurm.conf missing - run 03 on ${CTRL_HOST} first"
  exit 1
fi

cat > /etc/slurm/gres.conf <<'EOF'
AutoDetect=nvml
EOF

# ---------------------------------------------------------------
# 3. Check GPUs before starting
# ---------------------------------------------------------------
if command -v nvidia-smi >/dev/null 2>&1; then
  echo "    GPUs detected: $(nvidia-smi --list-gpus | wc -l)"
else
  echo "    !! nvidia-smi missing - install the NVIDIA driver, else the"
  echo "       node will not register any GPUs"
fi

# ---------------------------------------------------------------
# 4. Start slurmd
# ---------------------------------------------------------------
systemctl enable --now slurmd
sleep 3
systemctl is-active --quiet slurmd || { journalctl -u slurmd -n 15 --no-pager; exit 1; }

echo "==> 04-slurm-compute.sh DONE on $(hostname -s)"
echo "    On the controller run: sinfo -N -o '%N %T %C %G'"
