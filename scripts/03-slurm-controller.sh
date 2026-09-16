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

# shared helpers (needrestart, defensive users, shared storage)
source "$(dirname "$0")/lib.sh"
disable_needrestart


# ---------------------------------------------------------------
# 0a. Must run as root. `NODE2_HOST=x sudo -E bash 03...` is fine;
#     plain `sudo bash 03...` is fine. But if someone runs it WITHOUT
#     sudo, fail immediately with a clear message instead of silently
#     erroring later on apt/permissions.
# ---------------------------------------------------------------
if [[ "${EUID}" -ne 0 ]]; then
  echo "!! This script must run as root."
  echo "   Use:  sudo bash $0"
  echo "   or:   NODE2_HOST=hgx20 sudo -E bash $0"
  exit 1
fi

CLUSTER_NAME="${CLUSTER_NAME:-i3dpoc}"

# Generate the DB password SAFELY and IDEMPOTENTLY.
# Bug 1: `tr -dc ... </dev/urandom | head -c 24` dies from SIGPIPE (141)
#        under `set -o pipefail`, aborting the whole script silently.
# Bug 2: regenerating the password on every run broke re-runs, because
#        `CREATE USER IF NOT EXISTS` does NOT update an existing password,
#        so slurmdbd.conf disagreed with the DB -> "Access denied".
# Fix: reuse the stored password if we have one; always force it into MySQL.
DB_PASS_FILE=/root/.slurm_db_pass
if [[ -z "${DB_PASS:-}" ]]; then
  if [[ -r "$DB_PASS_FILE" ]]; then
    DB_PASS="$(sed -n 's/^DB_PASS=//p' "$DB_PASS_FILE")"
    echo "==> reusing existing DB password from ${DB_PASS_FILE}"
  fi
fi
if [[ -z "${DB_PASS:-}" ]]; then
  DB_PASS="$(head -c 512 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | cut -c1-24)"
  [[ -n "$DB_PASS" ]] || { echo "!! failed to generate DB password"; exit 1; }
  echo "==> generated a new DB password"
fi

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
#
# IMPORTANT: these nodes ship a VENDOR Slurm stack (seen on hgx01:
#   slurm23.02-client 23.02.8-100881-cm10.0-48e305b89c
# which is a Bright/BaseCommand-style build). A naive
# `apt-get install slurm-wlm` REMOVES that client and installs Ubuntu's
# 21.08.5 instead - a downgrade that also loses features the SOW needs
# (JobRequeue/PreemptMode semantics, newer gres.conf options).
# Detect it and stop, rather than silently replacing someone's stack.
# ---------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
VENDOR_SLURM="$(dpkg -l 2>/dev/null | awk '/^ii/ && $2 ~ /^slurm[0-9]/ {print $2" "$3}' | head -5)"
if [[ -n "$VENDOR_SLURM" ]]; then
  echo "    !! A vendor Slurm stack is already installed:"
  sed 's/^/       /' <<<"$VENDOR_SLURM"
  echo
  echo "    Installing Ubuntu's slurm-wlm would REPLACE it (and downgrade"
  echo "    to 21.08). Choose one and re-run with the matching mode:"
  echo
  echo "      SLURM_MODE=vendor   keep/configure the existing vendor stack"
  echo "                          (packages untouched; only slurm.conf + dbd)"
  echo "      SLURM_MODE=distro   install Ubuntu slurm-wlm (replaces vendor)"
  echo "      SLURM_MODE=source   build Slurm 25.11 from source (PMC/SOW"
  echo "                          target, needs build deps + ~10 min)"
  echo
  echo "    Refusing to guess. Set SLURM_MODE and re-run."
  exit 1
fi

apt-get update -qq
apt-get install -y -qq slurm-wlm slurmdbd munge mariadb-server \
  libmunge-dev libmariadb-dev 2>&1 | tail -3

# ---------------------------------------------------------------
# 2. Munge
#    The munge package normally creates the user, but on hgx01 a vendor
#    stack was being replaced and the user was absent, so `chown munge:`
#    failed with "invalid spec" and killed the script under `set -e`.
#    Create the user/group defensively, and name the group explicitly.
# ---------------------------------------------------------------
getent group munge >/dev/null 2>&1 || groupadd -r munge
if ! getent passwd munge >/dev/null 2>&1; then
  useradd -r -g munge -d /var/lib/munge -s /usr/sbin/nologin munge 2>/dev/null \
    || useradd -r -g munge -d /var/lib/munge -s /bin/false munge
fi
mkdir -p /etc/munge /var/lib/munge /var/log/munge /run/munge
chown -R munge:munge /etc/munge /var/lib/munge /var/log/munge 2>/dev/null || true
chmod 0700 /etc/munge /var/lib/munge
if [[ ! -s /etc/munge/munge.key ]]; then
  dd if=/dev/urandom bs=1 count=1024 of=/etc/munge/munge.key 2>/dev/null
fi
chown munge:munge /etc/munge/munge.key
chmod 400 /etc/munge/munge.key
systemctl enable --now munge 2>/dev/null || systemctl restart munge
sleep 1
munge -n | unmunge 2>/dev/null | grep -q "STATUS:.*Success" \
  && echo "    munge OK" \
  || { echo "    !! munge failed"; journalctl -u munge -n 10 --no-pager; exit 1; }

# ---------------------------------------------------------------
# 3. MariaDB accounting DB
# ALTER USER (not just CREATE USER IF NOT EXISTS) so re-runs converge
# on the same password instead of silently keeping a stale one.
# ---------------------------------------------------------------
systemctl enable --now mariadb
mysql -e "CREATE DATABASE IF NOT EXISTS slurm_acct_db;"
mysql -e "CREATE USER IF NOT EXISTS 'slurm'@'localhost' IDENTIFIED BY '${DB_PASS}';"
mysql -e "ALTER USER 'slurm'@'localhost' IDENTIFIED BY '${DB_PASS}';"
mysql -e "GRANT ALL ON slurm_acct_db.* TO 'slurm'@'localhost'; FLUSH PRIVILEGES;"
mysql -e "SET GLOBAL innodb_lock_wait_timeout=900;"

# verify the credential actually works before starting slurmdbd.
# IMPORTANT: mysql -p"$PASS" PROMPTS if the user does not exist yet, which
# hangs the script forever on a non-tty. Use --defaults-extra-file so the
# password is never a prompt candidate, and add a timeout as a belt.
MYSQL_CNF="$(mktemp)"
chmod 600 "$MYSQL_CNF"
cat > "$MYSQL_CNF" <<EOF
[client]
user=slurm
password=${DB_PASS}
EOF
if timeout 15 mysql --defaults-extra-file="$MYSQL_CNF" -e "SELECT 1" slurm_acct_db >/dev/null 2>&1; then
  echo "    DB credentials verified"
  rm -f "$MYSQL_CNF"
else
  rm -f "$MYSQL_CNF"
  echo "    !! DB credentials FAILED - slurmdbd will not start"
  exit 1
fi

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
systemctl enable slurmdbd >/dev/null 2>&1 || true
# restart (not just start): on a re-run the daemon may be holding the old
# config/password, which produced "Access denied" against the new one.
systemctl restart slurmdbd
# wait for slurmdbd to actually accept connections before any sacctmgr call.
# Timeout every probe: sacctmgr can block indefinitely if the daemon is up
# but not yet serving, which would hang the script.
for i in $(seq 1 30); do
  systemctl is-active --quiet slurmdbd || { sleep 1; continue; }
  if timeout 5 sacctmgr -n show cluster >/dev/null 2>&1; then break; fi
  sleep 1
done
systemctl is-active --quiet slurmdbd || { journalctl -u slurmdbd -n 15 --no-pager; exit 1; }
timeout 10 sacctmgr -n show cluster >/dev/null 2>&1 \
  && echo "    slurmdbd OK (accepting connections)" \
  || { echo "    !! slurmdbd up but not answering - aborting before sacctmgr spam"
       journalctl -u slurmdbd -n 15 --no-pager; exit 1; }

# ---------------------------------------------------------------
# 5. Detect hardware for NodeName lines
#    slurmd -C prints the authoritative topology Slurm expects.
# ---------------------------------------------------------------
# Prefer the GRES string Slurm itself reports. `slurmd -C` emits a `Gres=`
# field ONLY when it can actually talk to the GPU via NVML - which is the
# exact thing slurmctld compares against. Guessing the type from nvidia-smi
# risks a mismatch, and a mismatch DRAINs the node with
# "gres/gpu count reported lower than configured".
gpu_type_and_count() {   # echoes "<type> <count>"; EMPTY if not authoritative
  local line name count
  # 1. AUTHORITATIVE: slurmd's own NVML detection. slurmctld compares its
  #    registration against this exact value, so using it guarantees a match.
  line="$(slurmd -C 2>/dev/null | grep -m1 -o 'Gres=[^ ]*' || true)"
  if [[ -n "$line" ]]; then
    # Gres=gpu:type:N  or  Gres=gpu:N
    echo "${line#Gres=}" | sed 's|^gpu:||' | awk -F: '{if (NF==2) print $1, $2; else print "gpu", $1}'
    return 0
  fi
  # 2. EXPLICIT override only. We deliberately do NOT fall back to
  #    nvidia-smi: if slurmd cannot see the GPU via NVML, configuring any
  #    Gres= count makes slurmctld DRAIN the node with
  #    "gres/gpu count reported lower than configured". Better to register
  #    with no GRES and warn loudly than to silently break scheduling.
  if [[ -n "${GPU_TYPE:-}" ]] && command -v nvidia-smi >/dev/null 2>&1; then
    count="$(nvidia-smi --list-gpus 2>/dev/null | wc -l | tr -d ' ')"
    [[ -n "$count" && "$count" != "0" ]] && { echo "${GPU_TYPE} ${count}"; return 0; }
  fi
  return 0   # caller treats empty as "no GRES configured"
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

# Loudly flag the dangerous case: GPUs physically present, but Slurm's own
# NVML detection returned no Gres= (e.g. libnvidia-ml.so not visible to
# slurmd). Configuring a GRES count in that state DRAINs the node.
if command -v nvidia-smi >/dev/null 2>&1; then
  PHYS="$(nvidia-smi --list-gpus 2>/dev/null | wc -l | tr -d ' ')"
  if [[ -n "$PHYS" && "$PHYS" != "0" ]] && ! grep -q "Gres=" <<<"$NODE_LINES"; then
    echo
    echo "    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "    !! ${PHYS} GPUs present, but 'slurmd -C' reported NO Gres."
    echo "    !! Slurm cannot see NVML, so no GRES is configured."
    echo "    !! Jobs requesting --gres=gpu will NOT schedule."
    echo "    !!"
    echo "    !! Check:  slurmd -G"
    echo "    !!   'We were configured with nvml functionality, but that"
    echo "    !!    lib wasn't found on the system.'"
    echo "    !! Fix:  ensure the NVIDIA driver's libnvidia-ml.so.1 is on the"
    echo "    !!       loader path, then re-run this script:"
    echo "    !!         ldconfig; ls /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.*"
    echo "    !! Override only if you know the driver name:"
    echo "    !!         GPU_TYPE=h200 sudo -E bash \$0"
    echo "    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo
  fi
fi

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

# Slurm refuses to start if StateSaveLocation holds state from a DIFFERENT
# ClusterName ("fatal: CLUSTER NAME MISMATCH"). That happens when this script
# is re-run against an old state dir. Detect and clear it.
if [[ -f /var/spool/slurmctld/clustername ]]; then
  OLD_NAME="$(cat /var/spool/slurmctld/clustername 2>/dev/null | tr -d '[:space:]')"
  if [[ -n "$OLD_NAME" && "$OLD_NAME" != "$CLUSTER_NAME" ]]; then
    echo "    !! state dir holds cluster '${OLD_NAME}', we want '${CLUSTER_NAME}'"
    echo "       archiving old state so slurmctld can start"
    mv /var/spool/slurmctld "/var/spool/slurmctld.bak.$(date +%s)"
    mkdir -p /var/spool/slurmctld
    chown root:root /var/spool/slurmctld
  fi
fi
cat > /etc/slurm/gres.conf <<'EOF'
AutoDetect=nvml
EOF

# ---------------------------------------------------------------
# 6b. Publish cluster artifacts to shared storage (Lustre) so node 2
#     needs NO ssh access to this controller. Read by 04-slurm-compute.sh.
# ---------------------------------------------------------------
LUSTRE_MOUNT="${LUSTRE_MOUNT:-/mnt/i3d_20tb}"
if mountpoint -q "$LUSTRE_MOUNT" 2>/dev/null; then
  SHARED_ROOT="${LUSTRE_MOUNT}/slurm-poc"
else
  SHARED_ROOT="/shared"
fi
STAGE="${SHARED_ROOT}/cluster-config"
mkdir -p "$STAGE"
install -o root -g root -m 400 /etc/munge/munge.key "${STAGE}/munge.key"
install -o root -g root -m 644 /etc/slurm/slurm.conf  "${STAGE}/slurm.conf"
echo "SHARED_ROOT=${SHARED_ROOT}" > /etc/slurm-poc-shared.conf
echo "    published munge.key + slurm.conf -> ${STAGE}"
ls -l "$STAGE" | sed 's/^/      /'

# ---------------------------------------------------------------
# 7. Register cluster + users + QoS
# ---------------------------------------------------------------
sleep 2
timeout 15 sacctmgr -i create cluster "${CLUSTER_NAME}" 2>&1 | head -1 || true
timeout 15 sacctmgr -i create account root 2>&1 | head -1 || true
for u in slurmadmin mluser1 mluser2 mluser3 ubuntu; do
  id "$u" >/dev/null 2>&1 && \
    timeout 15 sacctmgr -i create user "$u" account=root 2>&1 | head -1 || true
done
# slurmadmin gets admin rights
id slurmadmin >/dev/null 2>&1 && \
  timeout 15 sacctmgr -i modify user slurmadmin set adminlevel=admin 2>&1 | head -1 || true

timeout 15 sacctmgr -i create qos normal priority=0   2>&1 | head -1 || true
timeout 15 sacctmgr -i create qos high  priority=1000 2>&1 | head -1 || true
timeout 15 sacctmgr -i create qos low   priority=100  2>&1 | head -1 || true
timeout 15 sacctmgr -i modify qos high set preempt=low 2>&1 | head -1 || true
for u in slurmadmin mluser1 mluser2 mluser3 ubuntu root; do
  timeout 15 sacctmgr -i modify user "$u" set qos=normal,high,low 2>&1 >/dev/null || true
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
echo "    Cluster artifacts published to: ${STAGE}"
echo "    Next:"
echo "      * on node 2 (NO ssh needed - it reads from shared storage):"
if [[ -n "$NODE2_HOST" ]]; then
  echo "          sudo bash 04-slurm-compute.sh"
else
  echo "          sudo bash 04-slurm-compute.sh"
  echo "        then re-run here with NODE2_HOST=<node2> to add it to slurm.conf"
fi
echo "      * containers (both nodes):  sudo bash 05-pyxis-enroot.sh"
