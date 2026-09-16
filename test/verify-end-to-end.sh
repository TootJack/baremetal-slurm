#!/bin/bash
# Full end-to-end: clean slate -> 03 -> cluster up -> submit a real job.
# Proves the three fixes together:
#   1. SlurmctldHost has no pinned address (socket timeout)
#   2. slurmctld/slurmd are restarted, not `enable --now` (conf hash mismatch)
#   3. the state dir is cleared atomically (No Assoc usage file)
export PATH=/opt/slurm/bin:/opt/slurm/sbin:/usr/bin:/bin:/usr/sbin:/sbin

echo "=== clean slate: wipe state + accounting DB ==="
systemctl stop slurmctld slurmd slurmdbd 2>/dev/null
rm -rf /var/spool/slurmctld /var/spool/slurmd
mysql -e "DROP DATABASE IF EXISTS slurm_acct_db; CREATE DATABASE slurm_acct_db;"
mysql -e "GRANT ALL ON slurm_acct_db.* TO \"slurm\"@\"localhost\"; FLUSH PRIVILEGES;"
echo "  wiped"

echo
echo "=== run 03 from scratch ==="
cd /mnt/c/Users/20210859/Documents/i3d-slurm-poc
RESET_ACCT_DB=1 SLURM_MODE=source timeout 350 bash scripts/03-slurm-controller.sh > /tmp/final.log 2>&1
echo "EXIT=$?"
grep -E "SlurmctldHost=|slurmctld OK|controller address" /tmp/final.log | head -4

echo
echo "=== cluster state ==="
sleep 8
sinfo -N -o "%N %T %C %G" 2>&1 | head -4

echo
echo "=== submit and run a real job ==="
cd /tmp
JID="$(sbatch --wrap="hostname; echo SLURM_JOB_ID=\$SLURM_JOB_ID" 2>&1 | grep -oE '[0-9]+$')"
echo "submitted job $JID"
for i in $(seq 1 12); do
  ST="$(sacct -j "$JID" -X -n -o State 2>/dev/null | head -1 | tr -d ' ')"
  echo "  t=$((i*4))s state=$ST"
  [[ "$ST" == COMPLETED* || "$ST" == FAILED* ]] && break
  sleep 4
done

echo
echo "=== job output ==="
cat "slurm-${JID}.out" 2>/dev/null || echo "(no output file)"

echo
echo "=== accounting works? ==="
sacct -X -o JobID,State,Elapsed 2>&1 | tail -3
