#!/usr/bin/env bash
# =====================================================================
# 03-slurm-controller.sh - Slurm control plane (run on node 1)
#
# Auto-detects hostname, CPU/RAM, and GPU count so it works on any node
# without editing. Node 2 is included ONLY if NODE2_HOST is set.
#
# Usage:
#   sudo bash 03-slurm-controller.sh                     # single node now
#   sudo NODE2_HOST=<name> bash 03-slurm-controller.sh   # once node2 is up
# =====================================================================
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-i3dpoc}"
DB_PASS="${DB_PASS:-$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 24)}"

# ---------------------------------------------------------------
# 0. Detect this node's real identity (Slurm NodeName MUST match)
# ---------------------------------------------------------------
NODE1="${NODE1:-$(hostname -s)}"
NODE2_HOST="${NODE2_HOST:-}"          # empty = single-node config

echo "==> Slurm controller setup"
echo "    cluster:    ${CLUSTER_NAME}"
echo "    controller: ${NODE1} $(hostname -I 2>/dev/null | awk '{print $1}')"

# ---------------------------------------------------------------
# 1. Packages
# ---------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq slurm-wlm slurmdbd munge mariadb-server \
  libmunge-dev libmariadb-dev

# ---------------------------------------------------------------
# 2. Munge
# ---------------------------------------------------------------
if [[ ! -s /etc/munge/munge.key ]]; then
  dd if=/dev/urandom bs=1 count=1024 of=/etc/munge/munge.key 2>/dev/null
fi
chown munge: /etc/munge/munge.key
chmod 400 /etc/munge/munge.key
systemctl enable --now munge
sleep 1
munge -n | unmunge | grep -q "STATUS:.*Success" && echo "    munge OK"

# ---------------------------------------------------------------
# 3. MariaDB accounting DB
# ---------------------------------------------------------------
systemctl enable --now mariadb
mysql -e "CREATE DATABASE IF NOT EXISTS slurm_acct_db;"
mysql -e "CREATE USER IF NOT EXISTS 'slurm'@'localhost' IDENTIFIED BY '${DB_PASS}';"
mysql -e "GRANT ALL ON slurm_acct_db.* TO 'slurm'@'localhost'; FLUSH PRIVILEGES;"
mysql -e "SET GLOBAL innodb_lock_wait_timeout=900;"

# ---------------------------------------------------------------
# 4. slurmdbd
# ---------------------------------------------------------------
mkdir -p /var/log/slurm
cat > /etc/slurm/slurmdbd.conf <<EOF
ArchiveEvents=yes
ArchiveJobs=yes
ArchiveSteps=yes
PurgeJobAfter=90d
AuthType=auth/munge
DbdHost=localhost
DebugLevel=info
LogFile=/var/log/slurm/slurmdbd.log
StorageType=accounting_storage/mysql
StorageHost=127.0.0.1
StorageLoc=slurm_acct_db
StorageUser=slurm
StoragePass=${DB_PASS}
EOF
chmod 600 /etc/slurm/slurmdbd.conf
systemctl enable --now slurmdbd
sleep 2
systemctl is-active --quiet slurmdbd || { journalctl -u slurmdbd -n 10 --no-pager; exit 1; }
echo "    slurmdbd OK"

# ---------------------------------------------------------------
# 5. Detect hardware for NodeName lines
#    slurmd -C prints the authoritative topology Slurm expects.
# ---------------------------------------------------------------
# Slurm normalizes a detected GPU name the same way: lowercase, spaces -> "_".
# The Type in Gres= must be an exact match OR a substring of that name, else
# the node registers fewer GPUs than configured and goes to DRAIN.
gpu_type_and_count() {   # echoes "<type> <count>"; empty if undetectable
  local name count
  command -v nvidia-smi >/dev/null 2>&1 || return 0
  count="$(nvidia-smi --list-gpus 2>/dev/null | wc -l | tr -d ' ')"
  [[ -z "$count" || "$count" == "0" ]] && return 0
  if [[ -n "${GPU_TYPE:-}" ]]; then
    echo "${GPU_TYPE} ${count}"; return 0
  fi
  name="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
  name="$(tr 'A-Z ' 'a-z_' <<<"$name" | tr -s '_' | sed 's/^_//;s/_$//')"
  echo "${name:-gpu} ${count}"
}

detect_node() {  # $1 = hostname  -> echoes "NodeName=.. CPUs=.. RealMemory=.. [Gres=..]"
  local host="$1" line cpus mem gres="" gtype="" gcount=""
  line="$(slurmd -C 2>/dev/null | grep -m1 '^NodeName=' || true)"
  if [[ -n "$line" ]]; then
    cpus="$(sed -E 's/.*CPUs=([0-9]+).*/\1/' <<<"$line")"
    mem="$(sed -E 's/.*RealMemory=([0-9]+).*/\1/' <<<"$line")"
  else
    cpus="$(nproc)"; mem="$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 ))"
  fi
  read -r gtype gcount <<<"$(gpu_type_and_count)"
  if [[ -n "$gtype" && -n "$gcount" ]]; then
    gres=" Gres=gpu:${gtype}:${gcount}"
  fi
  echo "NodeName=${host} CPUs=${cpus} RealMemory=${mem}${gres} State=UNKNOWN"
}

NODE_LINES="$(detect_node "$NODE1")"
NODE_NAMES="$NODE1"
if [[ -n "$NODE2_HOST" ]]; then
  NODE_LINES="${NODE_LINES}
$(detect_node "$NODE2_HOST")"
  NODE_NAMES="${NODE1},${NODE2_HOST}"
else
  echo "    NODE2_HOST not set -> single-node config (re-run with NODE2_HOST=<name> when node 2 is up)"
fi
echo "    node config:"
sed 's/^/      /' <<<"$NODE_LINES"

# ---------------------------------------------------------------
# 6. slurm.conf  (validated end-to-end in a real test cluster:
#    preemption REQUEUE + JobRequeue + cons_tres + backfill)
# ---------------------------------------------------------------
GRES_TYPES_LINE=""
GRES_LINE=""
if grep -q "Gres=gpu" <<<"$NODE_LINES"; then
  GRES_TYPES_LINE="GresTypes=gpu"
  GRES_LINE="AccountingStorageTRES=gres/gpu"
fi

cat > /etc/slurm/slurm.conf <<EOF
# Slurm config - i3D H200 POC (generated $(date -Iseconds))
ClusterName=${CLUSTER_NAME}
SlurmctldHost=${NODE1}(127.0.0.1)

AuthType=auth/munge
CryptoType=crypto/munge
StateSaveLocation=/var/spool/slurmctld
SlurmdSpoolDir=/var/spool/slurmd
SlurmctldPidFile=/run/slurmctld.pid
SlurmdPidFile=/run/slurmd.pid
SlurmctldTimeout=120
SlurmdTimeout=120
MinJobAge=300
KillWait=30
WaitTime=0
ReturnToService=2

# --- Accounting (required for QoS / preemption) ---
AccountingStorageType=accounting_storage/slurmdbd
AccountingStorageHost=127.0.0.1
AccountingStoragePort=6819
AccountingStorageEnforce=associations,qos
JobAcctGatherType=jobacct_gather/cgroup
${GRES_LINE}

# --- Scheduler ---
SchedulerType=sched/backfill
SelectType=select/cons_tres
SelectTypeParameters=CR_Core_Memory

# --- Priority + QoS + Preemption (SOW) ---
PriorityType=priority/multifactor
PriorityWeightQOS=1000
PreemptType=preempt/qos
PreemptMode=REQUEUE
JobRequeue=1
${GRES_TYPES_LINE}

# --- Logging ---
SlurmctldDebug=info
SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdDebug=info
SlurmdLogFile=/var/log/slurm/slurmd.log

# --- Nodes ---
${NODE_LINES}

# --- Partitions ---
PartitionName=gpu Nodes=${NODE_NAMES} Default=YES MaxTime=INFINITE State=UP
PartitionName=debug Nodes=${NODE_NAMES} MaxTime=02:00:00 State=UP
EOF

mkdir -p /var/spool/slurmctld /var/spool/slurmd
chown -R root:root /var/spool/slurmctld /var/spool/slurmd
cat > /etc/slurm/gres.conf <<'EOF'
AutoDetect=nvml
EOF

# ---------------------------------------------------------------
# 7. Register cluster + users + QoS
# ---------------------------------------------------------------
sleep 2
sacctmgr -i create cluster "${CLUSTER_NAME}" 2>&1 | head -1 || true
sacctmgr -i create account root 2>&1 | head -1 || true
for u in slurmadmin mluser1 mluser2 mluser3 ubuntu; do
  id "$u" >/dev/null 2>&1 && \
    sacctmgr -i create user "$u" account=root 2>&1 | head -1 || true
done
# slurmadmin gets admin rights
id slurmadmin >/dev/null 2>&1 && \
  sacctmgr -i modify user slurmadmin set adminlevel=admin 2>&1 | head -1 || true

sacctmgr -i create qos normal priority=0   2>&1 | head -1 || true
sacctmgr -i create qos high  priority=1000 2>&1 | head -1 || true
sacctmgr -i create qos low   priority=100  2>&1 | head -1 || true
sacctmgr -i modify qos high set preempt=low 2>&1 | head -1 || true
for u in slurmadmin mluser1 mluser2 mluser3 ubuntu root; do
  sacctmgr -i modify user "$u" set qos=normal,high,low 2>&1 >/dev/null || true
done

# ---------------------------------------------------------------
# 8. Start controller + local slurmd
# ---------------------------------------------------------------
systemctl enable --now slurmctld
sleep 3
systemctl is-active --quiet slurmctld || { journalctl -u slurmctld -n 15 --no-pager; exit 1; }
echo "    slurmctld OK"

# start slurmd on this node too (node1 also computes)
systemctl enable --now slurmd 2>/dev/null || true
sleep 3

cat > /root/.slurm_db_pass <<EOF
DB_PASS=${DB_PASS}
EOF
chmod 600 /root/.slurm_db_pass

echo
echo "==> 03-slurm-controller.sh DONE"
echo "    --- sinfo ---"
sinfo -N -o "%N %T %C %G" 2>/dev/null || sinfo
echo
echo "    Next:"
echo "      * copy munge key to node 2:  sudo scp /etc/munge/munge.key ${NODE2_HOST:-<node2>}:/etc/munge/"
echo "      * on node 2:                 sudo NODE2_HOST=... bash 04-slurm-compute.sh"
echo "      * containers (both nodes):   sudo bash 05-pyxis-enroot.sh"
