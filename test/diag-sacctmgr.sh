#!/bin/bash
# Why does sacctmgr hang despite slurmdbd being active?
echo "=== 1. is slurmdbd actually listening on 6819? ==="
ss -tlnp 2>/dev/null | grep -E "6819|6817|6818" || echo "(nothing listening!)"

echo
echo "=== 2. slurmdbd process alive? ==="
pgrep -a slurmdbd | head -2 || echo "(no process)"

echo
echo "=== 3. recent slurmdbd log (this boot) ==="
journalctl -u slurmdbd --since "5 min ago" --no-pager 2>/dev/null \
  | grep -viE "environment variable" | tail -8

echo
echo "=== 4. munge working? ==="
munge -n 2>/dev/null | unmunge 2>/dev/null | head -2 || echo "munge FAILED"

echo
echo "=== 5. sacctmgr with a hard timeout, verbose ==="
timeout 15 /opt/slurm/bin/sacctmgr -v -n show cluster 2>&1 | head -8
echo "rc=$?"

echo
echo "=== 6. is the slurm user in the DB an admin? ==="
mysql -N -e "SELECT user,admin_level FROM slurm_acct_db.user_table;" 2>/dev/null | head -5 \
  || echo "(user_table empty or missing)"
