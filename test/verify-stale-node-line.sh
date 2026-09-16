#!/bin/bash
# Verify 03 REJECTS a stale node-2 line (one published without CPU topology,
# as hgx20's is right now) instead of silently writing a conf that makes the
# node INVALID_REG.
set -u
cd "$(dirname "$0")/.."
export PATH=/opt/slurm/bin:/opt/slurm/sbin:$PATH
source scripts/lib.sh

FAKE="hgx98-stale"
stage="$(cluster_stage_dir)"
mkdir -p "$stage"

echo "=== plant a STALE line (no topology, like the old 04 wrote) ==="
printf 'NodeName=%s CPUs=192 RealMemory=2063725 Gres=gpu:nvidia_h200:8 State=UNKNOWN\n' "$FAKE" \
  > "${stage}/node-${FAKE}.conf"
cat "${stage}/node-${FAKE}.conf" | sed 's/^/  /'

echo
echo "=== run 03 with NODE2_HOST -> must REFUSE ==="
rm -rf /var/spool/slurmctld; mkdir -p /var/spool/slurmctld
mysql -e "DROP DATABASE IF EXISTS slurm_acct_db; CREATE DATABASE slurm_acct_db;" 2>/dev/null
mysql -e "GRANT ALL ON slurm_acct_db.* TO \"slurm\"@\"localhost\"; FLUSH PRIVILEGES;" 2>/dev/null
RESET_ACCT_DB=1 NODE2_HOST="$FAKE" SLURM_MODE=source timeout 300 \
  bash scripts/03-slurm-controller.sh > /tmp/stale.log 2>&1
rc=$?
echo "  exit=$rc"
grep -E "NO CPU topology|STALE line|re-run to republish|INVALID_REG" /tmp/stale.log | sed 's/^/  /'
[[ $rc -ne 0 ]] && echo "  PASS: refused a stale line" || echo "  FAIL: accepted stale line"

echo
echo "=== a FRESH line must be accepted ==="
publish_own_node_line "$FAKE" | sed 's/^/  published: /'
RESET_ACCT_DB=1 NODE2_HOST="$FAKE" SLURM_MODE=source timeout 300 \
  bash scripts/03-slurm-controller.sh > /tmp/fresh.log 2>&1
rc=$?
echo "  exit=$rc"
grep -E "line read from shared storage" /tmp/fresh.log | sed 's/^/  /'
[[ $rc -eq 0 ]] && echo "  PASS: accepted the fresh line" || { echo "  FAIL: rc=$rc"; tail -8 /tmp/fresh.log | sed 's/^/    /'; }

echo
echo "=== both nodes have topology in the written conf ==="
grep -E '^NodeName=' /etc/slurm/slurm.conf | sed 's/^/  /'
while IFS= read -r l; do
  if grep -qE 'CoresPerSocket=|SocketsPerBoard=' <<<"$l"; then
    echo "  PASS: $(awk '{print $1}' <<<"$l") has topology"
  else
    echo "  FAIL: $(awk '{print $1}' <<<"$l") lacks topology"
  fi
done < <(grep -E '^NodeName=' /etc/slurm/slurm.conf)

echo
echo "=== cleanup ==="
rm -f "${stage}/node-${FAKE}.conf"
rm -rf /var/spool/slurmctld; mkdir -p /var/spool/slurmctld
mysql -e "DROP DATABASE IF EXISTS slurm_acct_db; CREATE DATABASE slurm_acct_db;" 2>/dev/null
mysql -e "GRANT ALL ON slurm_acct_db.* TO \"slurm\"@\"localhost\"; FLUSH PRIVILEGES;" 2>/dev/null
RESET_ACCT_DB=1 SLURM_MODE=source timeout 300 bash scripts/03-slurm-controller.sh >/tmp/cleanup.log 2>&1
echo "  cleanup exit=$?"
grep -E '^NodeName=' /etc/slurm/slurm.conf | sed 's/^/  /'
sinfo -N -o "%N %T" 2>/dev/null | sed 's/^/  /'
