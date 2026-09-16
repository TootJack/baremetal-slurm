#!/bin/bash
# Why does slurmdbd deactivate right after starting?
echo "=== 1. is slurmdbd actually running (process)? ==="
pgrep -a slurmdbd | head -3 || echo "(no slurmdbd process)"

echo
echo "=== 2. unit state ==="
systemctl show slurmdbd -p ActiveState,SubState,ExecMainStatus,Type,Result | head -6

echo
echo "=== 3. foreground run: what does it actually say? ==="
systemctl stop slurmdbd 2>/dev/null
systemctl reset-failed slurmdbd 2>/dev/null
sleep 1
timeout 20 /opt/slurm/sbin/slurmdbd -D 2>&1 | head -20

echo
echo "=== 4. pid file handling (Type=forking needs it) ==="
grep -iE "pidfile" /etc/slurm/slurmdbd.conf 2>/dev/null || echo "(no PidFile set in slurmdbd.conf)"
ls -la /run/slurmdbd.pid /var/run/slurmdbd.pid 2>/dev/null
