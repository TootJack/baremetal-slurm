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

# SLURM_MODE decides how we get Slurm. Default is 'source' (25.11) because
# these nodes ship a vendor 23.02 stack that lacks SOW features, and the
# distro package is only 21.08.
SLURM_MODE="${SLURM_MODE:-source}"

if [[ -n "$VENDOR_SLURM" ]]; then
  echo "    vendor Slurm present:"
  sed 's/^/       /' <<<"$VENDOR_SLURM"
fi

case "$SLURM_MODE" in
  source)
    echo "    SLURM_MODE=source -> building Slurm from source at ${PREFIX:-/opt/slurm}"
    # Run slurm-source.sh when Slurm is missing OR when the systemd units /
    # PATH wiring are missing (e.g. units deleted, or a fresh shell after a
    # reboot). It is idempotent: it skips the compile if the version matches.
    NEED_BUILD=0
    if [[ ! -x "${PREFIX:-/opt/slurm}/sbin/slurmctld" ]]; then
      NEED_BUILD=1
    elif ! "${PREFIX:-/opt/slurm}/sbin/slurmctld" -V 2>/dev/null | grep -q "${SLURM_VER:-25.11}"; then
      NEED_BUILD=1
    elif [[ ! -f /etc/systemd/system/slurmctld.service ]] \
      || [[ ! -f /etc/systemd/system/slurmd.service ]] \
      || [[ ! -f /etc/systemd/system/slurmdbd.service ]] \
      || [[ ! -f /etc/profile.d/slurm.sh ]] \
      || [[ ! -L /usr/local/bin/sinfo ]] \
      || [[ ! -L /usr/local/bin/slurmd ]]; then
      echo "    Slurm present but systemd units / PATH wiring missing -> repairing"
      NEED_BUILD=1
    fi
    if [[ "$NEED_BUILD" == "1" ]]; then
      SLURM_MODE=source bash "$(dirname "$0")/slurm-source.sh"
    else
      echo "    Slurm ${SLURM_VER:-25.11} already installed and wired at ${PREFIX:-/opt/slurm}"
    fi
    # Remove the vendor packages so they cannot conflict with /opt/slurm
    # on PATH or in ld.so.
    if [[ -n "$VENDOR_SLURM" ]]; then
      echo "    removing vendor Slurm packages (they would shadow /opt/slurm)"
      for p in $(awk '{print $1}' <<<"$VENDOR_SLURM"); do
        apt-get remove -y -qq "$p" 2>&1 | tail -1 || true
      done
    fi
    # munge + mariadb come from distro packages; the rest of the stack is ours
    apt-get install -y -qq munge mariadb-server libmunge-dev libmariadb-dev 2>&1 | tail -2
    # ensure our binaries win in this shell
    export PATH="${PREFIX:-/opt/slurm}/bin:${PREFIX:-/opt/slurm}/sbin:$PATH"
    ;;
  distro)
    echo "    SLURM_MODE=distro -> Ubuntu slurm-wlm (replaces any vendor stack)"
    apt-get update -qq
    apt-get install -y -qq slurm-wlm slurmdbd munge mariadb-server \
      libmunge-dev libmariadb-dev 2>&1 | tail -3
    ;;
  vendor)
    echo "    SLURM_MODE=vendor -> keeping the existing vendor stack"
    echo "    !! not implemented for this POC; use source or distro"
    exit 1
    ;;
  *)
    echo "!! unknown SLURM_MODE='${SLURM_MODE}' (use source|distro)"
    exit 1
    ;;
esac

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

# A vendor stack leaves /etc/default/munge with OPTIONS pointing at ITS key
# path, e.g.:
#   OPTIONS="--key-file=/cm/shared/apps/slurm/var/munge/keys/munge.key"
# The Ubuntu munge unit does `ExecStart=/usr/sbin/munged $OPTIONS`, so that
# OPTIONS WINS over our key. When the vendor tree is gone (or holds a
# different key) munged fails with "Job for munge.service failed" and the
# whole cluster stops authenticating. Neutralise it explicitly.
if [[ -f /etc/default/munge ]] && grep -qE '^\s*OPTIONS=' /etc/default/munge; then
  VENDOR_OPTS="$(grep -E '^\s*OPTIONS=' /etc/default/munge | head -1)"
  echo "    vendor munge OPTIONS found: ${VENDOR_OPTS}"
  echo "    -> pointing it at our key (/etc/munge/munge.key)"
fi
cat > /etc/default/munge <<'EOF'
# MUNGE configuration - managed by the i3D Slurm POC scripts.
# Deliberately pinned to the standard key path: the munge systemd unit runs
# `munged $OPTIONS`, so any vendor-supplied --key-file here would override
# /etc/munge/munge.key and break authentication.
OPTIONS="--key-file=/etc/munge/munge.key"
EOF
# Same problem can appear as a vendor drop-in unit override
if [[ -d /etc/systemd/system/munge.service.d ]]; then
  echo "    clearing vendor munge unit overrides"
  rm -f /etc/systemd/system/munge.service.d/*.conf 2>/dev/null || true
  rmdir /etc/systemd/system/munge.service.d 2>/dev/null || true
  systemctl daemon-reload
fi

# Belt-and-braces: we could not identify how the vendor pinned
# --key-file=/cm/shared/... (it survived rewriting /etc/default/munge and
# clearing drop-ins). Rather than keep guessing, create our OWN full unit
# that cannot be overridden by any EnvironmentFile or OPTIONS variable.
cat > /etc/systemd/system/munge.service <<'EOF'
[Unit]
Description=MUNGE authentication service (i3D POC - pinned key path)
Documentation=man:munged(8)
After=time-sync.target

[Service]
Type=forking
# NOTE: deliberately no EnvironmentFile and no $OPTIONS - the vendor stack
# left OPTIONS pointing at /cm/shared/apps/... and the distro unit expands
# $OPTIONS, which overrode our key and broke all Slurm authentication.
ExecStart=/usr/sbin/munged --key-file=/etc/munge/munge.key
PIDFile=/run/munge/munged.pid
RuntimeDirectory=munge
RuntimeDirectoryMode=0755
User=munge
Group=munge
Restart=on-abort

[Install]
WantedBy=multi-user.target
EOF
# any EnvironmentFile the unit might still pull in is now ignored, but blank
# it anyway so nothing else can inject a stale key path
: > /etc/default/munge 2>/dev/null || true
systemctl daemon-reload

if [[ ! -s /etc/munge/munge.key ]]; then
  dd if=/dev/urandom bs=1 count=1024 of=/etc/munge/munge.key 2>/dev/null
fi
chown munge:munge /etc/munge/munge.key
chmod 400 /etc/munge/munge.key

# Sanity-check the key path BEFORE starting: a vendor --key-file pointing at
# /cm/shared/apps/... is the #1 cause of munge failing on these nodes.
grep -qE '^\s*OPTIONS=.*--key-file=/cm/' /etc/default/munge 2>/dev/null && {
  echo "    !! /etc/default/munge still references a vendor key path"
}

systemctl reset-failed munge 2>/dev/null || true
systemctl enable munge >/dev/null 2>&1 || true
# `|| true` is REQUIRED: systemctl restart returns non-zero when the unit
# fails, and under `set -e` that aborted the script before the diagnostics
# below could print - which is why this failure looked silent.
systemctl restart munge 2>/dev/null || true
sleep 2
if ! munge -n 2>/dev/null | unmunge 2>/dev/null | grep -q "STATUS:.*Success"; then
  echo
  echo "    !! munge is not working - the cluster cannot authenticate without it."
  echo "       --- systemctl status ---"
  systemctl status munge --no-pager 2>/dev/null | head -12 | sed 's/^/       /'
  echo "       --- journal ---"
  journalctl -u munge -n 8 --no-pager 2>/dev/null | tail -8 | sed 's/^/       /'
  echo "       --- effective config ---"
  echo "       /etc/default/munge : $(grep -E '^\s*OPTIONS=' /etc/default/munge 2>/dev/null || echo '(none)')"
  echo "       key in place      : $(ls -l /etc/munge/munge.key 2>/dev/null || echo MISSING)"
  echo "       If OPTIONS shows a /cm/ path, that is the vendor key and it must"
  echo "       be /etc/munge/munge.key instead."
  exit 1
fi
echo "    munge OK (key: /etc/munge/munge.key)"

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
# REQUIRED with the source build's systemd unit: Type=forking tracks the
# daemon via this pid file. Without it systemd sees the parent exit and
# marks the service "inactive (dead)" even though slurmdbd is running.
PidFile=/run/slurmdbd.pid
EOF
# slurmdbd refuses to start unless this file is 0600
chmod 600 /etc/slurm/slurmdbd.conf
chown root:root /etc/slurm/slurmdbd.conf

# Slurm 25.11 refuses to start when the accounting DB was created by a much
# older version. Verified root cause by reading as_mysql_convert.c:172-175:
# it fatals if `cluster_table` EXISTS but the schema version is below
# MIN_CONVERT_VERSION. A genuinely EMPTY database starts fine and 25.11
# creates its own tables (verified: 12 tables created).
# So: drop the DB BEFORE restarting, rather than reading stale journal lines
# (an earlier attempt grep'd the journal and matched old boot entries).
if [[ "${RESET_ACCT_DB:-0}" == "1" ]]; then
  echo "    RESET_ACCT_DB=1 -> recreating slurm_acct_db from scratch"
  systemctl stop slurmdbd 2>/dev/null || true
  mysql -e "DROP DATABASE IF EXISTS slurm_acct_db;"
  mysql -e "CREATE DATABASE slurm_acct_db;"
  mysql -e "GRANT ALL ON slurm_acct_db.* TO 'slurm'@'localhost'; FLUSH PRIVILEGES;"
fi

systemctl enable slurmdbd >/dev/null 2>&1 || true
systemctl reset-failed slurmdbd 2>/dev/null || true

# IMPORTANT ORDERING: sacctmgr (and every Slurm client) needs
# /etc/slurm/slurm.conf merely to LOCATE slurmdbd. Without it we get:
#   sacctmgr: error: resolve_ctls_from_dns_srv: Host name lookup failure
#   sacctmgr: fatal: Could not establish a configuration source
# which also blocks ~20s on a DNS SRV lookup and killed this script under
# `set -e`. The full config is written in section 6, but that happens AFTER
# the DB registration step - so seed a minimal config here.
mkdir -p /etc/slurm
if [[ ! -s /etc/slurm/slurm.conf ]]; then
  cat > /etc/slurm/slurm.conf <<EOF
# Minimal config so clients can find slurmdbd. section 6 overwrites this.
ClusterName=${CLUSTER_NAME}
SlurmctldHost=${NODE1}
AuthType=auth/munge
AccountingStorageType=accounting_storage/slurmdbd
AccountingStorageHost=127.0.0.1
AccountingStoragePort=6819
EOF
  echo "    seeded minimal /etc/slurm/slurm.conf (clients need it to find slurmdbd)"
fi
# timestamp boundary so we only judge THIS attempt, never an older boot's
# "fatal" line (journalctl -n N happily returns entries from previous boots)
DBD_SINCE="$(date '+%Y-%m-%d %H:%M:%S')"
systemctl restart slurmdbd
sleep 3

# give it a moment to either come up or die
for _ in 1 2 3 4 5 6; do
  systemctl is-active --quiet slurmdbd && break
  sleep 2
done

if ! systemctl is-active --quiet slurmdbd; then
  echo
  if journalctl -u slurmdbd --since "$DBD_SINCE" --no-pager 2>/dev/null | grep -q "schema is too old"; then
    echo "    !! accounting DB has an old schema (created by Slurm < 23.11)."
    echo "       Re-run with:  RESET_ACCT_DB=1 sudo -E bash \$0"
    echo "       This DELETES accounting history - acceptable for a POC."
  else
    echo "    !! slurmdbd failed to start:"
    journalctl -u slurmdbd --since "$DBD_SINCE" --no-pager 2>/dev/null | tail -15
  fi
  exit 1
fi
# wait for slurmdbd to actually accept connections before any sacctmgr call.
# Every probe is timeout-bounded: sacctmgr can block ~20s on a DNS SRV
# lookup when slurm.conf is missing, and 30 of those would hang the script.
DBD_OK=0
for i in $(seq 1 20); do
  systemctl is-active --quiet slurmdbd || { sleep 1; continue; }
  if timeout 8 sacctmgr -n show cluster >/dev/null 2>&1; then DBD_OK=1; break; fi
  sleep 1
done
if [[ "$DBD_OK" != "1" ]]; then
  echo "    !! slurmdbd is up but not answering sacctmgr."
  echo "       Check that /etc/slurm/slurm.conf exists and names the cluster:"
  ls -l /etc/slurm/slurm.conf 2>/dev/null || echo "       (missing!)"
  echo "       And that slurmdbd is listening:"
  ss -tlnp 2>/dev/null | grep 6819 || echo "       (nothing on 6819)"
  journalctl -u slurmdbd --since "$DBD_SINCE" --no-pager 2>/dev/null | tail -10
  exit 1
fi
echo "    slurmdbd OK (accepting connections)"

# ---------------------------------------------------------------
# 5. Detect hardware for NodeName lines
#    slurmd -C prints the authoritative topology Slurm expects.
# ---------------------------------------------------------------
# Node description helper.
# gpu_type_and_count() / detect_node() now live in lib.sh so 03 and 04 share
# one definition; detect_node() can only describe the LOCAL machine, which
# is why node 2's line is read from shared storage instead.
# ---------------------------------------------------------------

NODE_LINES="$(detect_node "$NODE1")"
NODE_NAMES="$NODE1"
if [[ -n "$NODE2_HOST" ]]; then
  # Node 2's resources MUST come from node 2 itself: detect_node() reads the
  # LOCAL kernel, so calling it with another host's name would stamp this
  # machine's CPU/RAM/GPU counts onto that node's stanza and slurmd would be
  # rejected on registration. 04 publishes what each node detected about
  # itself; we read that. No ssh required - it is on shared storage.
  node2_line="$(fetch_remote_node_line "$NODE2_HOST")"
  if [[ -n "$node2_line" ]]; then
    # A published line only describes node 2 as it was when 04 last ran. If 04
    # ran BEFORE a fix to the detection logic (or before its hardware changed)
    # the line is stale, and a stale line silently reintroduces the exact
    # INVALID_REG we are fixing - e.g. one without CoresPerSocket makes
    # slurmctld assume socket 0 = core 0. Compare against what the CURRENT
    # logic would produce and require freshness.
    cfg="$(cluster_stage_dir)/node-${NODE2_HOST}.conf"
    age_s=$(( $(date +%s) - $(stat -c %Y "$cfg" 2>/dev/null || echo 0) ))
    if ! grep -q "CoresPerSocket=" <<<"$node2_line" \
       && ! grep -q "SocketsPerBoard=" <<<"$node2_line"; then
      echo
      echo "    !! ${NODE2_HOST}'s published line has NO CPU topology:"
      echo "         ${node2_line}"
      echo "       That is a STALE line, written by an older version of 04."
      echo "       Without CoresPerSocket, slurmctld assumes 1 and rejects the"
      echo "       node as INVALID_REG:"
      echo "         Reason=gres/gpu GRES autodetected core affinity ... doesn't"
      echo "         match socket boundaries. (Socket 0 is cores 0-0)."
      echo "       On ${NODE2_HOST}, re-run to republish:"
      echo "           sudo bash 04-slurm-compute.sh"
      echo "       then re-run this script."
      echo
      exit 1
    fi
    echo "    ${NODE2_HOST} line read from shared storage (${age_s}s old):"
    sed 's/^/      /' <<<"$node2_line"
    NODE_LINES="${NODE_LINES}
${node2_line}"
  else
    # Refuse to invent it. Getting this wrong produces exactly the failure we
    # saw: the node registers with different resources and slurmctld marks it
    # INVALID_REG, or slurmd cannot find itself at all.
    echo
    echo "    !! ${NODE2_HOST} has not published its own node line yet."
    echo "       ${cluster_stage_dir}/node-${NODE2_HOST}.conf is missing."
    echo "       Run this FIRST, on ${NODE2_HOST}:"
    echo "           sudo bash 04-slurm-compute.sh"
    echo "       (04 publishes the node line before it starts slurmd, so it can"
    echo "        run before the controller knows about it - no deadlock.)"
    echo "       Then re-run here with NODE2_HOST=${NODE2_HOST}."
    echo
    echo "       Refusing to guess ${NODE2_HOST}'s CPU/memory/GPU counts:"
    echo "       this machine's hardware is NOT ${NODE2_HOST}'s hardware."
    echo
    exit 1
  fi
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

# SlurmctldHost takes a hostname, optionally followed by the address to use in
# parentheses: SlurmctldHost=slurmctl-primary(12.34.56.78).
#
# Do NOT add a parenthetical address here. It pins the advertised address, and
# if that address is not the one clients resolve the hostname to, every RPC
# fails with:
#   sinfo: error: Unable to contact slurm controller (connect failure)
#   slurm_load_partitions: Socket timed out on send/recv operation
#   error: Node X appears to have a different slurm.conf than the slurmctld
# Verified on the test bed: with SlurmctldHost=node(172.x) clients timed out;
# with a bare hostname (resolved via /etc/hosts, which 01-base.sh fills in
# with hgx01=10.100.18.5 / hgx20=10.100.18.8) the cluster reports `idle`.
# A bare hostname therefore adapts to each environment. NODE1_ADDR remains
# available as an opt-in override for split-brain/multi-homed setups.
if [[ -n "${NODE1_ADDR:-}" ]]; then
  SLURMCTLD_HOST="${NODE1}(${NODE1_ADDR})"
else
  SLURMCTLD_HOST="${NODE1}"
fi
echo "    SlurmctldHost=${SLURMCTLD_HOST}"

cat > /etc/slurm/slurm.conf <<EOF
# Slurm config - i3D H200 POC (generated $(date -Iseconds))
ClusterName=${CLUSTER_NAME}
SlurmctldHost=${SLURMCTLD_HOST}

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
if [[ -d /var/spool/slurmctld ]]; then
  # The dir may exist but be empty (fresh node / just wiped). Guard the read:
  # a failed `< file` redirection is a shell error, and `set -e` would abort
  # the whole script with "/var/spool/slurmctld/clustername: No such file or
  # directory" even though an empty state dir is perfectly valid.
  OLD_CLUSTER=""
  if [[ -f /var/spool/slurmctld/clustername ]]; then
    OLD_CLUSTER="$(tr -d '[:space:]' < /var/spool/slurmctld/clustername 2>/dev/null || true)"
  fi
  OLD_NAME="${OLD_CLUSTER%%|*}"
  OLD_ID="${OLD_CLUSTER##*|}"
  # Slurm writes "<ClusterName>|<ClusterID>", e.g. "i3dpoc|3744".
  #
  # CRITICAL: the ID must match the accounting DB. Recreating the DB
  # (RESET_ACCT_DB=1) mints a NEW ClusterID; a stale state file then makes
  # slurmctld die with:
  #   fatal: CLUSTER ID MISMATCH.
  #   slurmctld has been started with "ClusterID=3744" from the state files,
  #   but the DBD thinks it should be "1540".
  #
  # And the state dir must be either FULLY present or FULLY absent. Leaving
  # clustername without assoc_usage (a partial clear) makes slurmctld die:
  #   fatal: No Assoc usage file (/var/spool/slurmctld/assoc_usage) to recover
  #   [assoc_mgr.c:  if (clustername_existed && !ignore_state_errors) fatal(...)]
  # So we always delete the WHOLE directory when resetting.
  RESET_STATE=0
  if [[ "${RESET_ACCT_DB:-0}" == "1" ]]; then
    RESET_STATE=1
    echo "    RESET_ACCT_DB=1 -> clearing the whole slurmctld state dir"
    echo "      (a fresh DB mints a new ClusterID, and a partial state dir"
    echo "       causes 'CLUSTER ID MISMATCH' or 'No Assoc usage file')"
  elif [[ -n "$OLD_NAME" && "$OLD_NAME" != "$CLUSTER_NAME" ]]; then
    RESET_STATE=1
    echo "    !! state dir holds cluster '${OLD_NAME}' (id ${OLD_ID}), want '${CLUSTER_NAME}'"
    echo "       clearing it so slurmctld can start"
  fi
  if [[ "$RESET_STATE" == "1" ]]; then
    mv /var/spool/slurmctld "/var/spool/slurmctld.bak.$(date +%s)" 2>/dev/null \
      || rm -rf /var/spool/slurmctld
    mkdir -p /var/spool/slurmctld
    chown root:root /var/spool/slurmctld
    chmod 0755 /var/spool/slurmctld
    # confirm it really is empty - a leftover file breaks the next start
    if [[ -n "$(ls -A /var/spool/slurmctld 2>/dev/null)" ]]; then
      echo "    !! state dir not empty after reset; forcing removal"
      rm -rf /var/spool/slurmctld
      mkdir -p /var/spool/slurmctld
      chown root:root /var/spool/slurmctld
    fi
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
# NOTE: `enable --now` only STARTS a stopped unit. On a re-run the daemon is
# already up, so it would keep the PREVIOUS slurm.conf - slurmctld and slurmd
# then run different config hashes and clients fail with:
#   error: Node X appears to have a different slurm.conf than the slurmctld
#   slurm_load_partitions: Socket timed out on send/recv operation
# We rewrite slurm.conf above, so force a restart to guarantee both daemons
# read the same file.
systemctl enable slurmctld
systemctl restart slurmctld
sleep 3
systemctl is-active --quiet slurmctld || { journalctl -u slurmctld -n 15 --no-pager; exit 1; }
echo "    slurmctld OK"

# start slurmd on this node too (node1 also computes)
systemctl enable slurmd 2>/dev/null || true
systemctl restart slurmd 2>/dev/null || true
sleep 3

cat > /root/.slurm_db_pass <<EOF
DB_PASS=${DB_PASS}
EOF
chmod 600 /root/.slurm_db_pass

echo
echo "==> 03-slurm-controller.sh DONE"
echo "    --- sinfo ---"
# `set -e` is on: `cmd || cmd` returns non-zero when BOTH fail, which aborts
# the script even though the cluster came up fine. slurmctld needs a moment
# after a restart, so a transient "Socket timed out" here is expected and must
# NOT be treated as a failure. Everything below is reporting only.
sinfo -N -o "%N %T %C %G" 2>/dev/null || sinfo 2>/dev/null || {
  echo "    (sinfo not answering yet - slurmctld may still be starting;"
  echo "     this is not fatal, re-run: sinfo -N -o '%N %T %C %G')"
}
echo
# A node that is `inval` (INVALID_REG) registered with resources that differ
# from slurm.conf, or a daemon is running stale state. The reason string is the
# only thing that says WHICH, so always print it rather than leaving the user
# with a bare `inval` and no next step.
if sinfo -N -h -o "%N %T" 2>/dev/null | grep -qiE '\binval\b|\bdrain'; then
  echo "    !! a node is not usable - details:"
  for n in $(sinfo -N -h -o "%N %T" 2>/dev/null | awk 'tolower($2) ~ /inval|drain/ {print $1}'); do
    echo "      --- ${n} ---"
    echo "        slurmctld's view (configured):"
    scontrol show node "$n" 2>/dev/null \
      | grep -oE "(State|Reason|CPUTot|RealMemory|Gres)=[^ ]*" \
      | sed 's/^ */          /'
    echo "        configured in slurm.conf:"
    grep -E "^NodeName=${n}(\s|$)" /etc/slurm/slurm.conf 2>/dev/null | sed 's/^ */          /'
    # THE decisive check for the common GPU case: INVALID_REG is usually the
    # node registering FEWER gres than configured. `slurmd -G` shows whether
    # slurmd can see the driver at all - a login shell may see it while the
    # systemd service cannot (different library path), which registers 0 GPUs.
    if [[ "$n" == "$NODE1" ]]; then
      echo "        this machine reports (slurmd -C):"
      slurmd -C 2>/dev/null | grep -m1 '^NodeName=' | sed 's/^ */          /'
      echo "        NVML visibility for slurmd (slurmd -G):"
      # `slurmd -G` tries to set up a cgroup, which CONFLICTS with the running
      # slurmd and prints "Unable to initialize cgroup plugin" - that noise is
      # unrelated to GPU detection, so keep the GPU-relevant lines and say so
      # rather than letting the user chase a cgroup red herring.
      gg="$(slurmd -G 2>&1 || true)"
      if grep -qE 'Gres Name=|device\(s\) detected|lib wasn' <<<"$gg"; then
        grep -E 'Gres Name=|device\(s\) detected|lib wasn' <<<"$gg" \
          | head -4 | sed 's/^ */          /'
      else
        echo "          (could not read GPU list - slurmd -G collides with the"
        echo "           running slurmd's cgroup; this is NOT a GPU problem)"
        grep -iE 'Permission denied|cgroup' <<<"$gg" | head -2 | sed 's/^ */          /'
      fi
    fi
  done
  echo
  echo "    Read the mismatch above - that is the cause. Most common:"
  echo "      * registered Gres lower than configured (0 < N), and 'slurmd -G'"
  echo "        reports the lib was not found -> the NVIDIA driver's"
  echo "        libnvidia-ml.so.1 is not on the loader path FOR THE SERVICE."
  echo "        Check on the node:  ldconfig; ls /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.*"
  echo "        then restart it:    sudo systemctl restart slurmd"
  echo "      * everything matches but the state is stale (the node registered"
  echo "        before this config existed). Restart it, then on the controller:"
  echo "          sudo scontrol update nodename=${n:-<node>} state=resume"
fi
echo
echo "    Cluster artifacts published to: ${STAGE}"
echo "    Next:"
if [[ -n "$NODE2_HOST" ]]; then
  echo "      * on ${NODE2_HOST}:  sudo bash 04-slurm-compute.sh"
  echo "        (it will install the conf this run published, and start slurmd)"
else
  echo "      * node 2 is not in the config yet. The order is:"
  echo "          1. on node 2:  sudo bash 04-slurm-compute.sh"
  echo "             ^ publishes node 2's OWN CPU/RAM/GPU counts to"
  echo "               ${STAGE}/node-<node2>.conf, then stops and asks you"
  echo "               to come back here. Run it twice - that is expected."
  echo "          2. here:       NODE2_HOST=<node2> sudo -E bash \$0"
  echo "             ^ this reads that file (it cannot measure a remote"
  echo "               node's hardware, and must not guess it)"
  echo "          3. on node 2:  sudo bash 04-slurm-compute.sh   # now starts"
fi
echo "      * containers (both nodes):  sudo bash 05-pyxis-enroot.sh"
