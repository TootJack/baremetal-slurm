#!/usr/bin/env bash
# =====================================================================
# 05-pyxis-enroot.sh - Container runtime for Slurm (sqsh workflow)
# Run on ALL nodes (controller + compute).
#
# SOW: "jobs submitted with containers so no modules needed,
#        submitted with sqsh" -> Pyxis (SPANK plugin) + Enroot
#
# Usage:  sudo bash 05-pyxis-enroot.sh
# =====================================================================
set -euo pipefail

SLURM_VERSION="${SLURM_VERSION:-23.11}"   # match installed slurm-wlm
PYXIS_VERSION="${PYXIS_VERSION:-0.24.0}"  # check https://github.com/NVIDIA/pyxis/tags
ENROOT_VERSION="${ENROOT_VERSION:-4.2.1}" # check https://github.com/NVIDIA/enroot/tags

# Reuse the shared-storage decision made by 01-base.sh (Lustre when available)
if [[ -f /etc/slurm-poc-shared.conf ]]; then
  # shellcheck disable=SC1091
  source /etc/slurm-poc-shared.conf
fi
SHARED_ROOT="${SHARED_ROOT:-/shared}"
SHARED_IMGS="${SHARED_IMGS:-${SHARED_ROOT}/containers}"
echo "==> shared storage root: ${SHARED_ROOT}"

# ---------------------------------------------------------------
# 0. PRECHECK: enroot requires pure cgroup v2.
#    (Validated failure mode: WSL2 uses hybrid cgroups and
#     enroot-mount fails. Real Ubuntu 22.04+/systemd nodes are fine.)
# ---------------------------------------------------------------
if [[ "$(stat -fc %T /sys/fs/cgroup)" != "cgroup2fs" ]]; then
  echo "!!! /sys/fs/cgroup is not cgroup v2 (got: $(stat -fc %T /sys/fs/cgroup))"
  echo "!!! enroot cannot mount container overlays on hybrid cgroups."
  echo "!!! On Ubuntu this is fixed by: grub edit -> add systemd.unified_cgroup_hierarchy=1"
  echo "!!! (Standard on 22.04+; only old/custom kernels need this.)"
  exit 1
fi
echo "    cgroup v2 confirmed"

echo "==> Pyxis + Enroot install (Slurm ${SLURM_VERSION})"

# ---------------------------------------------------------------
# 1. Enroot (unprivileged container runtime, produces .sqsh)
# ---------------------------------------------------------------
if ! command -v enroot >/dev/null 2>&1; then
  echo "    installing enroot ${ENROOT_VERSION}"
  ARCH=$(dpkg --print-architecture)
  # NOTE: enroot+caps is only needed if you require setuid-style xattrs;
  #       plain enroot is sufficient for the sqsh workflow.
  curl -fSsL -o /tmp/enroot.deb \
    "https://github.com/NVIDIA/enroot/releases/download/v${ENROOT_VERSION}/enroot_${ENROOT_VERSION}-1_${ARCH}.deb"
  apt-get install -y -qq /tmp/enroot.deb
fi
# squashfuse is REQUIRED to mount .sqsh images (unprivileged FUSE)
apt-get install -y -qq squashfuse fuse3 >/dev/null
enroot version || true

# System enroot config: shared runtime dir + image cache on /shared
mkdir -p "${SHARED_IMGS}" /tmp/enroot-data /tmp/enroot-cache
cat > /etc/enroot/enroot.conf <<EOF
# Shared container store (both nodes see the same sqsh images via NFS)
ENROOT_RUNTIME_PATH=/tmp/enroot-data/\${UID}
ENROOT_CACHE_PATH=/tmp/enroot-cache
ENROOT_DATA_PATH=${SHARED_IMGS}/data/\${UID}
# GPU passthrough is automatic via nvidia-container-runtime hooks
EOF

# ---------------------------------------------------------------
# 2. Pyxis (SPANK plugin; must be compiled against the exact
#    installed Slurm version - this is the documented constraint)
# ---------------------------------------------------------------
if [[ ! -d /opt/pyxis ]]; then
  echo "    building pyxis ${PYXIS_VERSION} against installed Slurm headers"
  # libslurm-dev provides spank.h; pyxis must compile against the EXACT
  # installed Slurm version or slurmd will refuse to load the plugin.
  apt-get install -y -qq git make libslurm-dev >/dev/null
  git clone --depth 1 --branch "v${PYXIS_VERSION}" \
    https://github.com/NVIDIA/pyxis /opt/pyxis
fi
cd /opt/pyxis
make
make install
mkdir -p /etc/slurm/plugstack.conf.d
cat > /etc/slurm/plugstack.conf.d/pyxis.conf <<'EOF'
include /usr/local/share/pyxis/pyxis.conf
EOF

# ---------------------------------------------------------------
# 3. Restart slurmd to load the SPANK plugin
# ---------------------------------------------------------------
systemctl restart slurmd
sleep 2
systemctl is-active --quiet slurmd && echo "    slurmd restarted with pyxis" \
  || { journalctl -u slurmd --no-pager -n 10; exit 1; }

# ---------------------------------------------------------------
# 4. Sanity: build and cache a small test sqsh (both nodes)
# ---------------------------------------------------------------
mkdir -p "${SHARED_IMGS}"
if [[ ! -f "${SHARED_IMGS}/ubuntu-test.sqsh" ]]; then
  echo "    importing test image -> ${SHARED_IMGS}/ubuntu-test.sqsh"
  runuser -u "$(id -un 1000 2>/dev/null || echo nobody)" -- \
    enroot import -o "${SHARED_IMGS}/ubuntu-test.sqsh" docker://ubuntu:24.04 \
    || enroot import -o "${SHARED_IMGS}/ubuntu-test.sqsh" docker://ubuntu:24.04
fi

echo "==> 05-pyxis-enroot.sh DONE"
echo
echo "    Job submission (the sqsh workflow):"
echo "    \$ sbatch --container-image=${SHARED_IMGS}/ubuntu-test.sqsh job.sh"
echo "    or from a registry, cached into the same sqsh store:"
echo "    \$ sbatch --container-image=nvcr.io#nvidia/pytorch:26.04-py3 job.sh"
echo
echo "    Build a custom image once, reuse everywhere:"
echo "    \$ enroot import -o ${SHARED_IMGS}/megatron.sqsh docker://<registry>#<image>:<tag>"
