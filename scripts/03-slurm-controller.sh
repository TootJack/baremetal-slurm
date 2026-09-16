#!/usr/bin/env bash
# =====================================================================
# 03-slurm-controller.sh - Slurm control plane on node1
# Installs: munge, MariaDB, slurmdbd, slurmctld, QoS, partitions
#
# Usage:  sudo bash 03-slurm-controller.sh
# Assumes: 01-base.sh and 02-users.sh already run
# =====================================================================
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-i3dpoc}"
CTRL_HOST="${CTRL_HOST:-node1}"
NODE1="${NODE1:-node1}"
NODE2="${NODE2:-node2}"
# H200: 8 GPUs, 141GB HBM each. Set to actual values from `slurmd -C` if different.
NODE1_CPUS="${NODE1_CPUS:-104}"    # 2x52c Xeon; adjust after `slurmd -C`
NODE2_CPUS="${NODE2_CPUS:-104}"
NODE1_MEM="${NODE1_MEM:-1000000}"  # MiB; adjust after `slurmd -C`
NODE2_MEM="${NODE2_MEM:-1000000}"
DB_PASS="${DB_PASS:-$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 24)}"

echo "==> Slurm controller setup on ${CTRL_HOST}"

# ---------------------------------------------------------------
# 1. Install packages
# ---------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq slurm-wlm slurmdbd munge mariadb-server \
  libmunge-dev libmariadb-dev

# ---------------------------------------------------------------
# 2. Munge (single-node key generation; copy to node2 afterwards)
# ---------------------------------------------------------------
if [[ ! -s /etc/munge/munge.key ]] || [[ $(stat -c%a /etc/munge/munge.key) != "400" ]]; then
  dd if=/dev/urandom bs=1 count=1024 of=/etc/munge/munge.key 2>/dev/null
fi
chown munge: /etc/munge/munge.key
chmod 400 /etc/munge/munge.key
systemctl enable --now munge
sleep 1
munge -n | unmunge | grep -q "STATUS:.*Success" && echo "    munge OK"

# ---------------------------------------------------------------
# 3. MariaDB accounting database
# ---------------------------------------------------------------
mysql -e "CREATE DATABASE IF NOT EXISTS slurm_acct_db;"
mysql -e "CREATE USER IF NOT EXISTS 'slurm'@'localhost' IDENTIFIED BY '${DB_PASS}';"
mysql -e "GRANT ALL ON slurm_acct_db.* TO 'slurm'@'localhost'; FLUSH PRIVILEGES;"
mysql -e "SET GLOBAL innodb_buffer_pool_size=4096*1024*1024;"
mysql -e "SET GLOBAL innodb_lock_wait_timeout=900;"
echo "    DB pass: ${DB_PASS} (store securely)"

# ---------------------------------------------------------------
# 4. slurmdbd.conf  (mode 600, owner-adjusted; validated in test bed)
# ---------------------------------------------------------------
mkdir -p /var/log/slurm
cat > /etc/slurm/slurmdbd.conf <<EOF
# Slurm DBD - i3D POC
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
systemctl is-active --quiet slurmdbd && echo "    slurmdbd OK" || {
  journalctl -u slurmdbd --no-pager -n 10; exit 1; }

# ---------------------------------------------------------------
# 5. slurm.conf  (template validated end-to-end in WSL test bed;
#    preemption REQUEUE + JobRequeue=1 + cons_tres + backfill)
# ---------------------------------------------------------------
cat > /etc/slurm/slurm.conf <<EOF
# Slurm config - i3D.net H200 POC (2 nodes x 8 GPUs)
ClusterName=${CLUSTER_NAME}
SlurmctldHost=${CTRL_HOST}(127.0.0.1)

AuthType=auth/munge
CryptoType=crypto/munge
SlurmctldPidFile=/run/slurmctld.pid
SlurmdPidFile=/run/slurmd.pid
SlurmdSpoolDir=/var/spool/slurmd
StateSaveLocation=/var/spool/slurmctld
SlurmctldTimeout=120
SlurmdTimeout=120
InactiveLimit=0
MinJobAge=300
KillWait=30
WaitTime=0
SlurmctldParameters=enable_configless
FastSchedule=1

# --- Accounting (required for QoS/preemption) ---
AccountingStorageType=accounting_storage/slurmdbd
AccountingStorageHost=127.0.0.1
AccountingStoragePort=6819
AccountingStorageEnforce=associations,qos
AccountingStorageTRES=gres/gpu
JobAcctGatherType=jobacct_gather/cgroup
JobAcctGatherFrequency=30

# --- Scheduler ---
SchedulerType=sched/backfill
SchedulerParameters=kill_invalid_depend,permit_job_expansion
SelectType=select/cons_tres
SelectTypeParameters=CR_Core_Memory
DefMemPerCPU=0

# --- Priority + QoS + Preemption (SOW: priorities/QoS, preemption, requeue) ---
PriorityType=priority/multifactor
PriorityWeightQOS=1000
PriorityWeightFairshare=100000
PreemptType=preempt/qos
PreemptMode=REQUEUE
JobRequeue=1
RequeueExit=0
RequeueExitHold=16

# --- GPU GRES ---
GresTypes=gpu
AccountingStorageTRES=gres/gpu

# --- Logging ---
SlurmctldDebug=info
SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdDebug=info
SlurmdLogFile=/var/log/slurm/slurmd.log

# --- Nodes (H200: 8xGPU each; verify with 'slurmd -C' and adjust) ---
NodeName=${NODE1} CPUs=${NODE1_CPUS} RealMemory=${NODE1_MEM} Gres=gpu:h200:8 State=UNKNOWN
NodeName=${NODE2} CPUs=${NODE2_CPUS} RealMemory=${NODE2_MEM} Gres=gpu:h200:8 State=UNKNOWN

# --- Partitions ---
PartitionName=gpu Nodes=${NODE1},${NODE2} Default=YES MaxTime=INFINITE State=UP OverSubscribe=EXCLUSIVE
PartitionName=debug Nodes=${NODE1},${NODE2} MaxTime=02:00:00 State=UP OverSubscribe=YES:2
EOF
mkdir -p /var/spool/slurmctld /var/spool/slurmd
chown -R root:root /var/spool/slurmctld /var/spool/slurmd

# gres.conf on controller (compute nodes get their own in 04)
cat > /etc/slurm/gres.conf <<'EOF'
# GPU autodetection - matches driver-reported devices
AutoDetect=nvml
EOF

# ---------------------------------------------------------------
# 6. Register cluster + users in accounting (validated sequence)
# ---------------------------------------------------------------
sleep 2
sacctmgr -i create cluster "${CLUSTER_NAME}" 2>&1 | head -2 || true
sacctmgr -i create account root 2>&1 | head -2 || true
# slurmadmin = SlurmAdmin, everyone else = user
if id slurmadmin >/dev/null 2>&1; then
  sacctmgr -i create user slurmadmin account=root adminlevel=admin 2>&1 | head -2 || true
fi
for u in mluser1 mluser2 mluser3; do
  id "${u}" >/dev/null 2>&1 && \
    sacctmgr -i create user "${u}" account=root 2>&1 | head -2 || true
done

# ---------------------------------------------------------------
# 7. QoS definitions (high preempts low; validated in test bed)
# ---------------------------------------------------------------
sacctmgr -i create qos normal priority=0   2>&1 | head -2 || true
sacctmgr -i create qos high  priority=1000 2>&1 | head -2 || true
sacctmgr -i create qos low   priority=100  2>&1 | head -2 || true
sacctmgr -i modify qos high set preempt=low 2>&1 | head -2 || true
for u in slurmadmin mluser1 mluser2 mluser3; do
  sacctmgr -i modify user "${u}" set qos=high,low 2>&1 | head -2 >/dev/null || true
done

# ---------------------------------------------------------------
# 8. Start controller
# ---------------------------------------------------------------
systemctl enable --now slurmctld
sleep 3
systemctl is-active --quiet slurmctld && echo "    slurmctld OK" || {
  journalctl -u slurmctld --no-pager -n 10; exit 1; }

cat > /root/.slurm_db_pass <<EOF
DB_PASS=${DB_PASS}
EOF
chmod 600 /root/.slurm_db_pass

echo "==> 03-slurm-controller.sh DONE"
echo "    Copy munge key to node2 NOW:"
echo "      sudo scp /etc/munge/munge.key ${NODE2}:/etc/munge/"
echo "    then run 04-slurm-compute.sh on ${NODE2}"
echo "    then: sinfo  (nodes should show idle once slurmd registers)"
