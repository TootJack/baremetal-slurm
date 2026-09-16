#!/bin/bash
# Confirm 03 exits 0 deterministically - including when sinfo is briefly
# unresponsive right after slurmctld restarts (which used to abort it with a
# bogus non-zero exit under `set -e`).
set -u
cd "$(dirname "$0")/.."
export PATH=/opt/slurm/bin:/opt/slurm/sbin:$PATH

fails=0
for i in 1 2; do
  echo "=== run $i ==="
  RESET_ACCT_DB=1 SLURM_MODE=source timeout 300 \
    bash scripts/03-slurm-controller.sh > "/tmp/e2e-$i.log" 2>&1
  rc=$?
  echo "    exit=$rc"
  grep -E "slurmctld OK|not fatal" "/tmp/e2e-$i.log" | sed 's/^/    /'
  [[ $rc -ne 0 ]] && { fails=$((fails+1)); echo "    !! non-zero exit"; tail -6 "/tmp/e2e-$i.log" | sed 's/^/      /'; }
done

echo
echo "=== resulting state ==="
sleep 6
sinfo -N -o "%N %T %C %G" 2>&1 | sed 's/^/  /'

echo
if [[ $fails -eq 0 ]]; then echo "PASS: 03 exits 0 on both runs"; else echo "FAIL: $fails run(s) non-zero"; fi
exit $fails
