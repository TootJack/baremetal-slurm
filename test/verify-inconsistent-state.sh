#!/bin/bash
# Reproduce the crash loop: a state dir with clustername but NO assoc_usage
# makes slurmctld die forever with
#   fatal: No Assoc usage file (/var/spool/slurmctld/assoc_usage) to recover
# Then prove 03's new inconsistency check clears it and the cluster comes back.
set -u
cd "$(dirname "$0")/.."
export PATH=/opt/slurm/bin:/opt/slurm/sbin:$PATH

echo "=== plant the inconsistent state dir (name MATCHES, assoc_usage missing) ==="
systemctl stop slurmctld slurmd 2>/dev/null || true
rm -rf /var/spool/slurmctld; mkdir -p /var/spool/slurmctld
# take the real cluster name/id from the DB-backed config so the name matches
name="$(grep -m1 '^ClusterName=' /etc/slurm/slurm.conf | cut -d= -f2)"
printf '%s|1234\n' "$name" > /var/spool/slurmctld/clustername
echo "  clustername=$(cat /var/spool/slurmctld/clustername)  (matches CLUSTER_NAME)"
ls -A /var/spool/slurmctld | sed 's/^/    /'

echo
echo "=== confirm it kills slurmctld ==="
systemctl reset-failed slurmctld 2>/dev/null || true
systemctl start slurmctld
sleep 8
echo "  is-active: $(systemctl is-active slurmctld)"
journalctl -u slurmctld --since "40 sec ago" --no-pager 2>/dev/null \
  | grep -oE 'fatal: .*' | tail -2 | sed 's/^/    /'
if grep -qi "No Assoc usage file" <(journalctl -u slurmctld --since "40 sec ago" --no-pager 2>/dev/null); then
  echo "  CONFIRMED: crash loop reproduced"
else
  echo "  note: did not reproduce here"
fi

echo
echo "=== run 03 - must detect the inconsistency and recover ==="
RESET_ACCT_DB=1 SLURM_MODE=source timeout 300 \
  bash scripts/03-slurm-controller.sh > /tmp/incons.log 2>&1
echo "  exit=$?"
grep -E "INCONSISTENT|No Assoc usage|loading the whole|clearing the whole" /tmp/incons.log | sed 's/^/    /'

echo
echo "=== cluster recovered? ==="
sleep 8
out="$(sinfo -N -o "%N %T %C %G" 2>&1)"; rc=$?
echo "$out" | sed 's/^/  /'
if [[ $rc -eq 0 ]] && ! grep -qiE 'connect failure|timed out|drain|inval' <<<"$out"; then
  echo "  PASS: cluster is up and nodes usable"
else
  echo "  FAIL: still broken (rc=$rc)"
fi
