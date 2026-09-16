#!/bin/bash
# Verify the cgroup fix works in this (hybrid-cgroup) container
export PATH=/opt/slurm/bin:/opt/slurm/sbin:/usr/bin:/bin:/usr/sbin:/sbin

echo "=== cgroup type here ==="
stat -fc %T /sys/fs/cgroup

echo
echo "=== regenerate cgroup.conf via the script logic ==="
CG_TYPE="$(stat -fc %T /sys/fs/cgroup 2>/dev/null || echo unknown)"
if [ "$CG_TYPE" = "cgroup2fs" ]; then CG_PLUGIN=cgroup/v2; else CG_PLUGIN=cgroup/v1; fi
echo "detected: $CG_TYPE -> $CG_PLUGIN"
cat > /etc/slurm/cgroup.conf <<EOF
CgroupPlugin=${CG_PLUGIN}
ConstrainCores=yes
ConstrainDevices=yes
ConstrainRAMSpace=yes
EOF

echo
echo "=== restart slurmd ==="
systemctl reset-failed slurmd 2>/dev/null
systemctl restart slurmd
sleep 4
echo "slurmd: $(systemctl is-active slurmd)"
journalctl -u slurmd --since "1 min ago" --no-pager 2>/dev/null | grep -viE "environment" | tail -4

echo
echo "=== node state ==="
sinfo -N -o "%N %T %G" 2>&1 | head -4
scontrol show node 2>&1 | grep -E "State=" | head -2
