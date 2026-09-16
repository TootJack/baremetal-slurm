#!/usr/bin/env bash
# =====================================================================
# 01-base.sh - OS preparation for i3D.net H200 nodes (run on ALL nodes)
# Scope of Work: 2-Week MLOps POC, Ubuntu 22.04/24.04
#
# Usage:  sudo bash 01-base.sh
# =====================================================================
set -euo pipefail

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
#    (i3D gives you IPs; add them to /etc/hosts on BOTH nodes)
# ---------------------------------------------------------------
if ! grep -q "i3d-slurm-cluster" /etc/hosts; then
  echo "==> Adding cluster hosts to /etc/hosts (EDIT IPs BEFORE RUNNING)"
  echo "# BEGIN i3d-slurm-cluster"
  echo "# 10.0.0.11  node1 i3d-slurm-cluster"
  echo "# 10.0.0.12  node2"
  echo "# END i3d-slurm-cluster" >> /etc/hosts
  echo "!!! Edit /etc/hosts with real IPs and uncomment, then re-run"
fi

# ---------------------------------------------------------------
# 2. Time sync (required for munge authentication)
# ---------------------------------------------------------------
echo "==> Enabling NTP time sync"
timedatectl set-ntp true || true
timedatectl | grep -E "synchronized|NTP" || true

# ---------------------------------------------------------------
# 3. Base packages
# ---------------------------------------------------------------
echo "==> Installing base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  build-essential wget curl git vim jq \
  chrony \
  nfs-common \
  python3 python3-pip \
  hwloc \
  cgroup-tools

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
#    (Tailscale handles network access; this is defense in depth)
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
# 7. Tailscale (per SOW: access like the Nebius setup)
# ---------------------------------------------------------------
if ! command -v tailscale >/dev/null 2>&1; then
  echo "==> Installing Tailscale"
  curl -fsSL https://tailscale.com/install.sh | sh
  echo "!!! Run 'tailscale up' manually with your tailnet auth key:"
  echo "    sudo tailscale up --auth-key=tskey-xxx"
fi

# ---------------------------------------------------------------
# 8. Shared directories for jobs / containers / checkpoints
#    (NFS exports are set up on the controller in 03-controller.sh;
#     compute nodes mount them - see 04-compute.sh)
# ---------------------------------------------------------------
for d in /shared/containers /shared/ckpt /shared/data /shared/scratch /shared/home; do
  mkdir -p "$d"
done
chmod 1777 /shared/scratch

echo "==> 01-base.sh DONE"
echo "    Next: 02-users.sh on the controller, then 03-slurm-controller.sh"
