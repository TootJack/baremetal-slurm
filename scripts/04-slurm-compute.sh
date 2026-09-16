#!/usr/bin/env bash
# =====================================================================
# 04-slurm-compute.sh - slurmd on a compute node (run on NODE 2)
#
# Usage:
#   sudo CTRL_HOST=<node1-hostname> bash 04-slurm-compute.sh
# =====================================================================
set -euo pipefail

CTRL_HOST="${CTRL_HOST:?set CTRL_HOST to the controller hostname, e.g. CTRL_HOST=$(hostname -s)}"
CLUSTER_NAME="${CLUSTER_NAME:-i3dpoc}"

echo "==> Slurm compute node setup on $(hostname -s)"
echo "    controller: ${CTRL_HOST}"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq slurmd slurm-client munge

# ---------------------------------------------------------------
# 1. Munge - key must be IDENTICAL to the controller's
# ---------------------------------------------------------------
if [[ ! -s /etc/munge/munge.key ]]; then
  echo "    fetching munge key from ${CTRL_HOST}"
  scp -o StrictHostKeyChecking=accept-new \
      "root@${CTRL_HOST}:/etc/munge/munge.key" /etc/munge/munge.key \
  || scp -o StrictHostKeyChecking=accept-new \
      "${CTRL_HOST}:/etc/munge/munge.key" /etc/munge/munge.key
fi
chown munge: /etc/munge/munge.key
chmod 400 /etc/munge/munge.key
systemctl enable --now munge
sleep 1
munge -n | unmunge | grep -q "STATUS:.*Success" || { echo "!! munge failed"; exit 1; }
echo "    munge OK"
echo "    (verify identical: md5sum /etc/munge/munge.key on both nodes)"

# ---------------------------------------------------------------
# 2. slurm.conf - must be byte-identical to the controller's
# ---------------------------------------------------------------
mkdir -p /etc/slurm /var/spool/slurmd /var/log/slurm
scp -o StrictHostKeyChecking=accept-new \
    "root@${CTRL_HOST}:/etc/slurm/slurm.conf" /etc/slurm/slurm.conf \
|| scp -o StrictHostKeyChecking=accept-new \
    "${CTRL_HOST}:/etc/slurm/slurm.conf" /etc/slurm/slurm.conf

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
