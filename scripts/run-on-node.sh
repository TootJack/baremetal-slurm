#!/usr/bin/env bash
# =====================================================================
# run-on-node.sh - ONE command to run on the bare-metal node.
#
# Since the agent cannot reach the node (eduVPN and FortiClient are
# mutually exclusive on the laptop), this collects everything into a
# single log you paste back.
#
# Usage (on the node, as ubuntu):
#     curl -fsSL <raw-url> | bash -s -- preflight
# or after copying the repo:
#     bash scripts/run-on-node.sh preflight|controller|all
#
# Output goes to stdout AND a file: /tmp/poc-<stage>-<ts>.log
# =====================================================================
set -o pipefail

STAGE="${1:-preflight}"
TS="$(date +%Y%m%d-%H%M%S)"
LOG="/tmp/poc-${STAGE}-${TS}.log"

# tee everything so the user can paste the tail
exec > >(tee -a "$LOG") 2>&1

hr() { printf '\n========== %s ==========\n' "$*"; }

hr "STAGE: ${STAGE}  host=$(hostname -s)  $(date -Is)"
echo "log file: ${LOG}"

case "$STAGE" in

# ---------------------------------------------------------------
preflight)
  hr "OS"
  cat /etc/os-release | grep -E '^(PRETTY_NAME|VERSION_ID)='
  uname -r
  echo "cgroup: $(stat -fc %T /sys/fs/cgroup)   <-- must be cgroup2fs for enroot"

  hr "HARDWARE"
  echo "CPUs: $(nproc)"
  awk '/MemTotal/{printf "RAM:  %.1f GiB\n", $2/1048576}' /proc/meminfo
  lspci 2>/dev/null | grep -iE "nvidia|mellanox|connectx" | head -12

  hr "GPU"
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --list-gpus
    echo "GPU count: $(nvidia-smi --list-gpus | wc -l)"
    nvidia-smi --query-gpu=driver_version,name,memory.total --format=csv
    echo "--- topology ---"
    nvidia-smi topo -m
  else
    echo "!! nvidia-smi NOT FOUND - NVIDIA driver not installed"
  fi

  hr "FABRIC MANAGER (required for H200/HGX NVSwitch)"
  systemctl is-active nvidia-fabricmanager 2>/dev/null || echo "not active / not installed"

  hr "NETWORK"
  ip -br addr
  ip -br link | grep -iE "ib|en" | head -10
  echo "--- default route ---"
  ip route | head -5

  hr "SLURM TOPOLOGY (what Slurm will use for NodeName)"
  if command -v slurmd >/dev/null 2>&1; then
    slurmd -C 2>&1 | head -3
    echo "--- GRES validation (must be non-empty & match GPU count) ---"
    if command -v nvidia-smi >/dev/null 2>&1; then
      echo "nvidia-smi count: $(nvidia-smi --list-gpus | wc -l)"
      echo "nvidia-smi name : $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
      echo "=> Gres Type should be a lowercase/underscored substring of that name"
    fi
    slurmd -G 2>&1 | head -5
  else
    echo "slurmd not installed yet"
  fi

  hr "DISK / SHARED"
  df -h / /shared 2>/dev/null | head -5
  ls -la /shared 2>/dev/null | head -5 || echo "/shared does not exist yet"

  hr "EXISTING SLURM"
  systemctl is-active slurmctld slurmd slurmdbd munge mariadb 2>/dev/null | paste -sd' ' -

  hr "SUDO"
  sudo -n true 2>/dev/null && echo "passwordless sudo: YES" || echo "passwordless sudo: NO (will need password)"
  ;;

# ---------------------------------------------------------------
controller)
  hr "RUNNING 01-base.sh"
  sudo bash "$(dirname "$0")/01-base.sh"

  hr "RUNNING 03-slurm-controller.sh"
  if [ -n "${NODE2_HOST:-}" ]; then
    sudo env NODE2_HOST="$NODE2_HOST" bash "$(dirname "$0")/03-slurm-controller.sh"
  else
    sudo bash "$(dirname "$0")/03-slurm-controller.sh"
  fi

  hr "RESULT: sinfo"
  sinfo -N -o "%N %T %C %G %m"
  hr "RESULT: scontrol show nodes"
  scontrol show nodes | grep -E "NodeName|State|CfgTRES|Gres|RealMemory|CPUTot"
  hr "RESULT: sacctmgr qos"
  sacctmgr show qos format=name,priority,preempt -n
  hr "RESULT: slurmd log tail"
  sudo journalctl -u slurmd -n 15 --no-pager
  hr "RESULT: slurmctld log tail"
  sudo journalctl -u slurmctld -n 15 --no-pager
  ;;

# ---------------------------------------------------------------
containers)
  hr "RUNNING 05-pyxis-enroot.sh"
  sudo bash "$(dirname "$0")/05-pyxis-enroot.sh"

  hr "RESULT: pyxis plugin"
  srun --help 2>&1 | grep -i "container-image" || echo "PYXIS FLAGS NOT FOUND"
  hr "RESULT: sqsh images"
  ls -lh /shared/containers/ 2>/dev/null
  ;;

# ---------------------------------------------------------------
verify)
  hr "CLUSTER STATE"
  sinfo -N -o "%N %T %C %G"
  hr "TEST JOB (as ubuntu user)"
  sbatch --wrap="hostname; nvidia-smi --list-gpus | head -2" -o /tmp/poc-test-%j.out 2>&1 | tail -1
  sleep 6
  cat /tmp/poc-test-*.out 2>/dev/null | tail -6
  hr "CONTAINER SMOKE (pyxis)"
  srun --container-image=/shared/containers/ubuntu-test.sqsh echo "CONTAINER OK" 2>&1 | tail -3
  ;;

*)
  echo "usage: $0 preflight|controller|containers|verify|all"
  exit 1
  ;;
esac

hr "DONE (${STAGE}) - log saved to ${LOG}"
echo "Paste the output (or: tail -n 200 ${LOG})"
