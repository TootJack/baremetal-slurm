#!/usr/bin/env bash
# =====================================================================
# 04-slurm-compute.sh - slurmd on each compute node (node1 AND node2)
#
# Usage:  sudo bash 04-slurm-compute.sh
# Assumes: 01-base.sh run; munge key copied from controller
# =====================================================================
set -euo pipefail

CTRL_HOST="${CTRL_HOST:-node1}"
CLUSTER_NAME="${CLUSTER_NAME:-i3dpoc}"

echo "==> Slurm compute node setup"

# ---------------------------------------------------------------
# 1. Packages
# ---------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq slurmd slurm-client munge

# ---------------------------------------------------------------
# 2. Verify munge key matches the controller
# ---------------------------------------------------------------
systemctl enable --now munge
sleep 1
munge -n | unmunge | grep -q "STATUS:.*Success" \
  && echo "    munge OK (verify SAME key as controller: md5sum /etc/munge/munge.key on both)" \
  || { echo "!!! munge failed - copy the key first"; exit 1; }

# ---------------------------------------------------------------
# 3. slurm.conf - identical to controller (configless also works,
#    but a local copy lets slurmd start before ctld is reachable)
# ---------------------------------------------------------------
if [[ ! -f /etc/slurm/slurm.conf ]] || ! grep -q "${CLUSTER_NAME}" /etc/slurm/slurm.conf; then
  echo "    copying slurm.conf from ${CTRL_HOST}"
  scp "${CTRL_HOST}:/etc/slurm/slurm.conf" /etc/slurm/slurm.conf
fi
mkdir -p /var/spool/slurmd /var/log/slurm

# gres.conf - GPU autodetection on this node
cat > /etc/slurm/gres.conf <<'EOF'
AutoDetect=nvml
EOF

# ---------------------------------------------------------------
# 4. Verify GPU visibility before starting slurmd
# ---------------------------------------------------------------
if command -v nvidia-smi >/dev/null 2>&1; then
  echo "    detected GPUs: $(nvidia-smi --list-gpus | wc -l)"
  nvidia-smi --list-gpus | head -3
else
  echo "    !!! nvidia-smi not found - install the NVIDIA driver first"
  echo "    !!! expected 8x H200 per node"
fi

# ---------------------------------------------------------------
# 5. Start slurmd
# ---------------------------------------------------------------
systemctl enable --now slurmd
sleep 3
systemctl is-active --quiet slurmd && echo "    slurmd OK" || {
  journalctl -u slurmd --no-pager -n 10; exit 1; }

echo "==> 04-slurm-compute.sh DONE"
echo "    On the controller run: sinfo -N -o '%N %T %G'  (expect gpu:h200:8 per node)"
