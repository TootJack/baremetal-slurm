#!/usr/bin/env bash
# =====================================================================
# run-on-node.sh - staged runner for the bare-metal nodes.
#
# Runs one stage of the deployment and tees everything to a single log,
# which makes a failed run easy to hand over for diagnosis.
#
# Usage (on the node, as ubuntu):
#     bash scripts/run-on-node.sh preflight|fabric|controller|containers|verify
#
# Output goes to stdout AND a file: /tmp/poc-<stage>-<ts>.log
# =====================================================================
set -o pipefail

STAGE="${1:-preflight}"
TS="$(date +%Y%m%d-%H%M%S)"
LOG="/tmp/poc-${STAGE}-${TS}.log"

# tee everything so a failed run leaves a complete log
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
fabric)
  hr "INTER-NODE IP CONNECTIVITY (bond0, 10.100.18.0/24)"
  for peer in hgx01 hgx20; do
    ip="$(getent hosts "$peer" 2>/dev/null | awk '{print $1}')"
    [ -z "$ip" ] && { echo "$peer: not in /etc/hosts"; continue; }
    if ping -c 2 -W 2 "$ip" >/dev/null 2>&1; then
      echo "$peer ($ip): PING OK"
    else
      echo "$peer ($ip): PING FAILED"
    fi
  done
  echo "--- bond0 link speed (this is the NCCL fallback path) ---"
  for b in /sys/class/net/bond0/bonding/slaves; do
    [ -f "$b" ] || continue
    for s in $(cat "$b"); do
      echo "  slave $s: $(cat /sys/class/net/$s/speed 2>/dev/null || echo '?') Mb/s"
    done
  done
  cat /proc/net/bonding/bond0 2>/dev/null | grep -E "Bonding Mode|Speed|Slave Interface|MII Status" | head -10

  hr "INFINIBAND / RDMA"
  if command -v ibstat >/dev/null 2>&1; then
    ibstat -l 2>/dev/null
    echo "--- port states (must be Active for multi-node NCCL over IB) ---"
    for d in /sys/class/infiniband/*/ports/*/state; do
      [ -f "$d" ] || continue
      echo "  $d = $(cat "$d")"
    done
    echo "--- link layer (InfiniBand vs Ethernet/RoCE) ---"
    for d in /sys/class/infiniband/*/ports/*/link_layer; do
      [ -f "$d" ] || continue
      echo "  $d = $(cat "$d")"
    done
  else
    echo "ibstat not installed (apt install infiniband-diags)"
  fi
  echo "--- rdma devices ---"
  rdma link 2>/dev/null || echo "rdma tool unavailable"
  echo "--- is a subnet manager needed? (IB ports stay DOWN without one) ---"
  systemctl is-active opensm 2>/dev/null || echo "opensm not running"
  echo "--- perftest present? ---"
  command -v ib_write_bw >/dev/null 2>&1 && echo "perftest installed" || echo "perftest NOT installed"

  hr "SHARED FILESYSTEM"
  echo "--- mounts ---"
  mount | grep -vE "^(proc|sysfs|cgroup|devpts|tmpfs|securityfs|debugfs|tracefs|pstore|bpf|configfs|fusectl|mqueue|hugetlbfs|nsfs|binfmt_misc|efivarfs|ramfs)" | head -15
  echo "--- lustre client? ---"
  lsmod 2>/dev/null | grep -i lustre || echo "no lustre module loaded"
  command -v lfs >/dev/null 2>&1 && lfs df 2>/dev/null | head -5 || echo "lfs not installed"
  echo "--- ~/lustre ---"
  ls -la ~/lustre 2>/dev/null | head -5
  echo "--- NFS exports/mounts ---"
  command -v showmount >/dev/null 2>&1 && showmount -e localhost 2>/dev/null | head -5 || echo "nfs-utils not installed"
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
  echo "usage: $0 preflight|controller|fabric|containers|verify|all"
  exit 1
  ;;
esac

hr "DONE (${STAGE}) - log saved to ${LOG}"
echo "Paste the output (or: tail -n 200 ${LOG})"
