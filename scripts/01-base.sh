#!/usr/bin/env bash
# =====================================================================
# 01-base.sh - OS preparation for i3D.net H200 nodes (run on ALL nodes)
# Scope of Work: 2-Week MLOps POC, Ubuntu 22.04/24.04
#
# Usage:  sudo bash 01-base.sh
# =====================================================================
set -euo pipefail

# shared helpers (needrestart, defensive users, shared storage)
source "$(dirname "$0")/lib.sh"
disable_needrestart


# ---------------------------------------------------------------
# Node roles - adjust if your hostnames differ
# ---------------------------------------------------------------
SLURM_CONTROLLER="${SLURM_CONTROLLER:-node1}"     # runs slurmctld + slurmdbd
SLURM_COMPUTE="${SLURM_COMPUTE:-node1,node2}"     # comma-separated slurmd nodes

echo "==> Base OS prep for Slurm cluster"
echo "    Controller: ${SLURM_CONTROLLER}"
echo "    Compute:    ${SLURM_COMPUTE}"

# ---------------------------------------------------------------
# 1. Hostname resolution across the two nodes
#    Real values for this cluster: hgx01=10.100.18.5, hgx20=10.100.18.8
#    Both nodes are 10.100.18.0/24 on bond0, so they CAN reach each other.
# ---------------------------------------------------------------
# Slurm resolves SlurmctldHost=<name> through /etc/hosts (there is no DNS for
# these names). The controller and every compute node MUST map the name to the
# SAME address, or RPCs fail - the exact failure mode we hit in testing:
#   sinfo: error: Unable to contact slurm controller (connect failure)
#   slurm_load_partitions: Socket timed out on send/recv operation
HOSTS_BLOCK="${HOSTS_BLOCK:-10.100.18.5  hgx01
10.100.18.8  hgx20}"

# Debian/Ubuntu ship a `127.0.1.1 <hostname>` line. That makes the node's OWN
# name resolve to LOOPBACK, so on the controller `SlurmctldHost=hgx01` binds
# 127.0.1.1 and no other node can reach it:
#   sinfo: error: Unable to contact slurm controller (connect failure)
#   slurm_load_partitions: Socket timed out on send/recv operation
# gethostbyname returns the FIRST match, so appending the LAN mapping is not
# enough - the loopback line must go. Remove any line that maps a cluster node
# name to a loopback address before installing the real mapping.
for _node in $(echo "$HOSTS_BLOCK" | awk '{print $2}'); do
  if grep -qE "^[[:space:]]*127\.[0-9.]+[[:space:]]+.*\b${_node}\b" /etc/hosts 2>/dev/null; then
    echo "    removing loopback entry for ${_node} (it would shadow the LAN IP)"
    sed -i -E "/^[[:space:]]*127\.[0-9.]+[[:space:]]+.*\b${_node}\b/d" /etc/hosts
  fi
done

# Rebuild the block whenever it is missing OR does not match the expected
# mapping. A plain "is the marker present?" guard would silently keep a stale
# or partial block from an earlier run forever.
if [[ "$(sed -n '/# BEGIN i3d-slurm-cluster/,/# END i3d-slurm-cluster/p' /etc/hosts 2>/dev/null \
        | grep -v '^#')" != "$HOSTS_BLOCK" ]]; then
  echo "==> Updating cluster hosts in /etc/hosts"
  sed -i '/# BEGIN i3d-slurm-cluster/,/# END i3d-slurm-cluster/d' /etc/hosts
  { echo "# BEGIN i3d-slurm-cluster"
    echo "$HOSTS_BLOCK"
    echo "# END i3d-slurm-cluster"
  } >> /etc/hosts
  echo "    set: $(echo "$HOSTS_BLOCK" | tr '\n' ' ')"
else
  echo "    /etc/hosts cluster block already correct"
fi

# Verify the mapping matches on THIS node - do not just probe for existence.
hosts_ok=1
while read -r ip name; do
  [[ -z "$ip" || -z "$name" ]] && continue
  # `getent ahostsv4` returns the IPv4 for the name; take the first field.
  resolved="$(getent ahostsv4 "$name" 2>/dev/null | awk '{print $1}' | head -1)"
  if [[ "$resolved" != "$ip" ]]; then
    echo "    !! ${name} resolves to '${resolved}', expected '${ip}'"
    hosts_ok=0
  fi
done <<<"$HOSTS_BLOCK"
if [[ "$hosts_ok" == "1" ]]; then
  echo "    hostname resolution OK ($(hostname -s) sees both nodes)"
else
  echo "    !! hostname resolution FAILED - Slurm will not reach the controller"
  echo "       fix /etc/hosts so every node maps the cluster names identically"
  exit 1
fi

# ---------------------------------------------------------------
# 2. Time sync (required for munge authentication)
#    `timedatectl set-ntp true` fails on these images with
#    "NTP not supported" because systemd-timesyncd is absent; chrony is
#    installed in step 3 and started here instead.
# ---------------------------------------------------------------
echo "==> Enabling time sync (chrony)"
timedatectl set-ntp true 2>/dev/null || echo "    timedatectl NTP unavailable - relying on chrony"
if ! systemctl is-active --quiet chrony 2>/dev/null; then
  systemctl enable --now chrony 2>/dev/null || true
fi
sleep 2
if command -v chronyc >/dev/null 2>&1; then
  chronyc tracking 2>/dev/null | grep -E "Reference ID|Stratum|System time" | sed 's/^/    /' || true
  chronyc sources 2>/dev/null | head -5 | sed 's/^/    /' || true
fi
timedatectl 2>/dev/null | grep -E "synchronized|NTP service" | sed 's/^/    /' || true

# ---------------------------------------------------------------
# 3. Base packages
# ---------------------------------------------------------------
echo "==> Installing base packages"
export DEBIAN_FRONTEND=noninteractive
# hgx20 hit "E: Unmet dependencies" because a pending kernel upgrade left
# dpkg half-configured. Repair first, then install.
if ! dpkg --audit >/dev/null 2>&1 || dpkg --audit 2>/dev/null | grep -q .; then
  echo "    dpkg has half-configured packages - running --configure -a"
  dpkg --configure -a 2>&1 | tail -3 || true
fi
apt-get -f install -y -qq 2>&1 | tail -3 || true
apt-get update -qq
apt-get install -y -qq \
  build-essential wget curl git vim jq \
  chrony \
  nfs-common \
  python3 python3-pip \
  hwloc \
  cgroup-tools 2>&1 | tail -5
# `needrestart` can return non-zero on GPU nodes with a pending kernel
# update and abort the script under `set -e`. It is advisory only.
dpkg -l needrestart >/dev/null 2>&1 && {
  echo "    needrestart present - disabling its interactive prompt"
  sed -i 's/^#\?\$nrconf{restart}.*/$nrconf{restart} = '"'"'a'"'"';/' \
    /etc/needrestart/needrestart.conf 2>/dev/null || true
}

# ---------------------------------------------------------------
# 4. Kernel settings for GPU training nodes
#    - cgroup v2 (Slurm 25.x + Pyxis need it)
#    - memlock for CUDA pinned memory
#    - max_map_count for shared memory / NCCL
#    - core dumps off (job checkpoints are handled by the app)
# ---------------------------------------------------------------
echo "==> Applying /etc/sysctl.d/99-slurm-gpu.conf"
cat > /etc/sysctl.d/99-slurm-gpu.conf <<'EOF'
# Slurm + GPU training node tuning (i3D H200 POC)
# unlimited memlock for CUDA pinned memory (NCCL, cuDNN)
memlock = unlimited 2>/dev/null || echo "skip"
EOF
# memlock is an rlimit not a sysctl; do it properly via limits.conf
cat > /etc/security/limits.d/99-slurm-gpu.conf <<'EOF'
*    soft  memlock  unlimited
*    hard  memlock  unlimited
*    soft  nofile   1048576
*    hard  nofile   1048576
*    soft  stack    unlimited
*    hard  stack    unlimited
root soft  memlock  unlimited
root hard  memlock  unlimited
EOF
cat > /etc/sysctl.d/99-slurm-gpu.conf <<'EOF'
vm.max_map_count = 1048576
kernel.core_pattern = |/bin/false
fs.file-max = 2097152
vm.swappiness = 10
EOF
sysctl --system >/dev/null 2>&1 || true

# ---------------------------------------------------------------
# 5. Disable unattended-upgrades (GPU driver stability)
#    NVIDIA explicitly recommends this for GPU nodes
# ---------------------------------------------------------------
echo "==> Disabling unattended-upgrades (NVIDIA recommendation for GPU nodes)"
systemctl disable --now unattended-upgrades 2>/dev/null || true
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
EOF

# ---------------------------------------------------------------
# 6. SSH hardening: key auth only, no root password login
#    Access is via FortiClient VPN + ed25519 keys (no Tailscale for a 30-day POC)
# ---------------------------------------------------------------
echo "==> Configuring sshd: pubkey auth on, password auth off"
SSHD_CONFIG="/etc/ssh/sshd_config"
# Ubuntu 24.04 uses /etc/ssh/sshd_config.d/; set a drop-in to win
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-poc.conf <<'EOF'
PubkeyAuthentication yes
PasswordAuthentication no
PermitRootLogin prohibit-password
# keep sessions alive during long training jobs
ClientAliveInterval 120
ClientAliveCountMax 10
EOF
systemctl restart ssh || systemctl restart sshd

# ---------------------------------------------------------------
# 7. Shared directories for jobs / containers / checkpoints
#
#    This cluster has Lustre mounted at /mnt/i3d_20tb (over IB), which is
#    already shared between both nodes - far better than a local /shared.
#    We use it when present, and only fall back to local /shared otherwise.
# ---------------------------------------------------------------
LUSTRE_MOUNT="${LUSTRE_MOUNT:-/mnt/i3d_20tb}"
if mountpoint -q "$LUSTRE_MOUNT" 2>/dev/null; then
  echo "==> Using shared Lustre at ${LUSTRE_MOUNT}"
  SHARED_ROOT="${LUSTRE_MOUNT}/slurm-poc"
else
  echo "==> No Lustre at ${LUSTRE_MOUNT}; using LOCAL /shared (NOT shared between nodes!)"
  SHARED_ROOT="/shared"
fi
for d in containers ckpt data scratch; do
  mkdir -p "${SHARED_ROOT}/${d}" 2>/dev/null || true
done
# world-writable scratch so all 3 users can use it
chmod 1777 "${SHARED_ROOT}/scratch" 2>/dev/null || true

# Record the decision for scripts 03/05 to reuse
echo "SHARED_ROOT=${SHARED_ROOT}" > /etc/slurm-poc-shared.conf 2>/dev/null || true
echo "    SHARED_ROOT=${SHARED_ROOT}"
ls -ld "${SHARED_ROOT}" "${SHARED_ROOT}/containers" 2>/dev/null | sed 's/^/    /'

echo "==> 01-base.sh DONE"
echo "    Next: 02-users.sh on the controller, then 03-slurm-controller.sh"
