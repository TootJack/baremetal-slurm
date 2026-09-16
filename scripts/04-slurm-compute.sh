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

# SLURM_MODE must match the controller's choice. 'source' builds the same
# 25.11 to /opt/slurm so both nodes run an identical version (required by
# Slurm, and Pyxis must compile against the same headers).
SLURM_MODE="${SLURM_MODE:-source}"
if [[ "$SLURM_MODE" == "source" ]]; then
  echo "    SLURM_MODE=source -> building Slurm ${SLURM_VER:-25.11.8} at ${PREFIX:-/opt/slurm}"
  if [[ ! -x "${PREFIX:-/opt/slurm}/sbin/slurmd" ]]; then
    SLURM_MODE=source bash "$(dirname "$0")/slurm-source.sh"
  else
    echo "    already installed at ${PREFIX:-/opt/slurm}"
    [[ -f /etc/profile.d/slurm.sh ]] || SLURM_MODE=source bash "$(dirname "$0")/slurm-source.sh"
  fi
  if [[ -n "$(dpkg -l 2>/dev/null | awk '/^ii/ && $2 ~ /^slurm[0-9]/ {print $2}')" ]]; then
    echo "    removing vendor Slurm packages"
    for p in $(dpkg -l 2>/dev/null | awk '/^ii/ && $2 ~ /^slurm[0-9]/ {print $2}'); do
      apt-get remove -y -qq "$p" 2>&1 | tail -1 || true
    done
  fi
  apt-get install -y -qq munge libmunge-dev 2>&1 | tail -2
  export PATH="${PREFIX:-/opt/slurm}/bin:${PREFIX:-/opt/slurm}/sbin:$PATH"
else
  apt-get update -qq
  apt-get install -y -qq slurmd slurm-client munge 2>&1 | tail -3
fi

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

# A vendor stack leaves /etc/default/munge pointing at ITS OWN key, e.g.
#   OPTIONS="--key-file=/cm/shared/apps/slurm/var/munge/keys/munge.key"
# The munge unit runs `munged $OPTIONS`, so that would override our key and
# break authentication (or fail outright if the vendor tree is gone).
cat > /etc/default/munge <<'EOF'
# MUNGE configuration - managed by the i3D Slurm POC scripts.
# Pinned to the standard key path; a vendor --key-file here would override
# /etc/munge/munge.key because the unit runs `munged $OPTIONS`.
OPTIONS="--key-file=/etc/munge/munge.key"
EOF
if [[ -d /etc/systemd/system/munge.service.d ]]; then
  rm -f /etc/systemd/system/munge.service.d/*.conf 2>/dev/null || true
  rmdir /etc/systemd/system/munge.service.d 2>/dev/null || true
  systemctl daemon-reload
fi

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
systemctl reset-failed munge 2>/dev/null || true
systemctl enable munge >/dev/null 2>&1 || true
systemctl restart munge
sleep 2
if ! munge -n | unmunge 2>/dev/null | grep -q "STATUS:.*Success"; then
  echo "!! munge failed. Diagnostics:"
  systemctl status munge --no-pager 2>/dev/null | head -10
  journalctl -u munge -n 10 --no-pager 2>/dev/null | tail -8
  exit 1
fi
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
