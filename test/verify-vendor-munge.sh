#!/bin/bash
# Full end-to-end: plant vendor munge config, then run the REAL 03 script
# and confirm it recovers.
set -u

echo "=== PLANT the hgx01 vendor state ==="
systemctl stop munge 2>/dev/null
cat > /etc/default/munge <<'EOF'
# MUNGE configuration

# Pass additional command-line options to munged.
OPTIONS="--key-file=/cm/shared/apps/slurm/var/munge/keys/munge.key"
EOF
mkdir -p /etc/systemd/system/slurmctld.service.d
printf '[Service]\nUser=root\nGroup=root\n' > /etc/systemd/system/slurmctld.service.d/override.conf
echo "planted vendor OPTIONS + stale slurmctld drop-in"
systemctl daemon-reload 2>/dev/null

echo
echo "=== RUN the real 03-slurm-controller.sh ==="
rm -f /etc/slurm/slurm.conf
RESET_ACCT_DB=1 SLURM_MODE=source timeout 600 \
  bash /mnt/c/Users/20210859/Documents/i3d-slurm-poc/scripts/03-slurm-controller.sh \
  > /tmp/vendor-test.log 2>&1
echo "EXIT=$?"

echo
echo "=== key lines from the run ==="
grep -E "vendor munge|munge OK|clearing stale|slurmdbd OK|slurmctld OK|!!" /tmp/vendor-test.log | head -10

echo
echo "=== final state ==="
export PATH=/opt/slurm/bin:/opt/slurm/sbin:/usr/bin:/bin:/usr/sbin:/sbin
for s in munge mariadb slurmdbd slurmctld slurmd; do
  printf "  %-10s %s\n" "$s" "$(systemctl is-active "$s" 2>/dev/null || echo unknown)"
done
sinfo -N -o "%N %T %G" 2>&1 | head -3
