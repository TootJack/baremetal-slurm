#!/bin/bash
# Exercise real 03 with NODE2_HOST set - the path that failed on hgx01/hgx20.
# Verifies it REFUSES to invent node2's resources and SUCCEEDS once node2 has
# published its own line.
set -u
cd "$(dirname "$0")/.."
export PATH=/opt/slurm/bin:/opt/slurm/sbin:$PATH
HERE="$(pwd)"
FAKE="hgx99-fake"

echo "=== A. NODE2_HOST set, node2 has NOT published -> must refuse ==="
rm -rf /var/spool/slurmctld; mkdir -p /var/spool/slurmctld
mysql -e "DROP DATABASE IF EXISTS slurm_acct_db; CREATE DATABASE slurm_acct_db;" 2>/dev/null
mysql -e "GRANT ALL ON slurm_acct_db.* TO \"slurm\"@\"localhost\"; FLUSH PRIVILEGES;" 2>/dev/null
rm -f /shared/cluster-config/node-${FAKE}.conf

RESET_ACCT_DB=1 NODE2_HOST="$FAKE" SLURM_MODE=source timeout 300 \
  bash scripts/03-slurm-controller.sh > /tmp/neg.log 2>&1
rc=$?
echo "    exit=${rc}"
grep -E "has not published|Refusing to guess|Run this FIRST" /tmp/neg.log | sed 's/^/    /'
if [[ $rc -ne 0 ]] && grep -q "has not published" /tmp/neg.log; then
  echo "    PASS: refused instead of inventing hardware"
else
  echo "    FAIL: should have refused (rc=${rc})"
fi
# it must NOT have written a slurm.conf claiming that host
if grep -q "NodeName=${FAKE}" /etc/slurm/slurm.conf 2>/dev/null; then
  echo "    FAIL: wrote a conf containing the unpublished host"
else
  echo "    PASS: no conf written for the unpublished host"
fi

echo
echo "=== B. node2 publishes, then 03 must succeed ==="
source scripts/lib.sh
publish_own_node_line "$FAKE" | sed 's/^/    published: /'

RESET_ACCT_DB=1 NODE2_HOST="$FAKE" SLURM_MODE=source timeout 300 \
  bash scripts/03-slurm-controller.sh > /tmp/pos.log 2>&1
rc=$?
echo "    exit=${rc}"
grep -E "line read from shared storage|SlurmctldHost=|slurmctld OK" /tmp/pos.log | sed 's/^/    /'
if [[ $rc -eq 0 ]]; then
  echo "    PASS: 03 completed with node2 included"
else
  echo "    FAIL: rc=${rc}"; tail -12 /tmp/pos.log | sed 's/^/      /'
fi

echo
echo "=== C. the written conf describes BOTH nodes correctly ==="
grep -E '^NodeName=' /etc/slurm/slurm.conf | sed 's/^/    /'
for h in "$(hostname -s)" "$FAKE"; do
  if grep -qE "^NodeName=${h}([[:space:]]|$)" /etc/slurm/slurm.conf; then
    echo "    PASS: conf has NodeName=${h}"
  else
    echo "    FAIL: conf missing NodeName=${h}"
  fi
done
# the fake node must carry its PUBLISHED values, not this machine's
pub="$(cat "/shared/cluster-config/node-${FAKE}.conf")"
if grep -qF "$pub" /etc/slurm/slurm.conf; then
  echo "    PASS: fake node's line is exactly what it published"
else
  echo "    FAIL: published='${pub}' not found verbatim"
fi

echo
echo "=== D. cleanup: restore single-node config ==="
rm -f "/shared/cluster-config/node-${FAKE}.conf"
rm -rf /var/spool/slurmctld; mkdir -p /var/spool/slurmctld
mysql -e "DROP DATABASE IF EXISTS slurm_acct_db; CREATE DATABASE slurm_acct_db;" 2>/dev/null
mysql -e "GRANT ALL ON slurm_acct_db.* TO \"slurm\"@\"localhost\"; FLUSH PRIVILEGES;" 2>/dev/null
RESET_ACCT_DB=1 SLURM_MODE=source timeout 300 bash scripts/03-slurm-controller.sh >/tmp/clean.log 2>&1
echo "    exit=$?"
grep -E "^NodeName=" /etc/slurm/slurm.conf | sed 's/^/    /'
sinfo -N -o "%N %T" 2>/dev/null | sed 's/^/    /'
