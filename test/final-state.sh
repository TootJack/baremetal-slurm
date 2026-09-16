#!/bin/bash
# Final state check for the source-mode install
export PATH=/opt/slurm/bin:/opt/slurm/sbin:/usr/bin:/bin:/usr/sbin:/sbin

echo "=== Slurm version ==="
slurmctld -V 2>&1 | head -1

echo
echo "=== daemons ==="
for s in munge mariadb slurmdbd slurmctld slurmd; do
  printf "  %-10s %s\n" "$s" "$(systemctl is-active "$s" 2>/dev/null || echo unknown)"
done

echo
echo "=== node state ==="
sinfo -N -o "%N %T %C %G" 2>&1 | head -5

echo
echo "=== scontrol show node ==="
scontrol show node 2>&1 | grep -E "NodeName|State=|Gres=|RealMemory|CPUTot" | head -8

echo
echo "=== does slurmd register? (recent) ==="
journalctl -u slurmd --since "3 min ago" --no-pager 2>/dev/null | grep -viE "environment" | tail -5

echo
echo "=== submit a test job ==="
sbatch --wrap="hostname; date" -o /tmp/srcjob-%j.out 2>&1 | tail -1
sleep 8
echo "--- output ---"
cat /tmp/srcjob-*.out 2>/dev/null | tail -5
sacct -X -o JobID,JobName%10,State,Elapsed 2>&1 | tail -4
