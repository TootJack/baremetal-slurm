#!/bin/bash
# Diagnose slurmdbd "Database schema is too old" on a fresh 25.11 install
systemctl stop slurmdbd 2>/dev/null
systemctl reset-failed slurmdbd 2>/dev/null
sleep 1

echo "=== 1. recreate a genuinely empty DB ==="
mysql -e "DROP DATABASE IF EXISTS slurm_acct_db;"
mysql -e "CREATE DATABASE slurm_acct_db;"
mysql -e "GRANT ALL ON slurm_acct_db.* TO 'slurm'@'localhost'; FLUSH PRIVILEGES;"

echo "=== 2. does cluster_table exist in the empty DB? ==="
mysql -N -e "SELECT COUNT(*) FROM information_schema.tables
             WHERE table_schema='slurm_acct_db' AND table_name='cluster_table';"

echo "=== 3. any tables at all? ==="
mysql -N -e "SHOW TABLES FROM slurm_acct_db;" | head -5
echo "(count: $(mysql -N -e "SHOW TABLES FROM slurm_acct_db;" | wc -l))"

echo
echo "=== 4. run slurmdbd in FOREGROUND (real error, no systemd noise) ==="
timeout 25 /opt/slurm/sbin/slurmdbd -D 2>&1 | head -15

echo
echo "=== 5. did it create tables this time? ==="
mysql -N -e "SHOW TABLES FROM slurm_acct_db;" | head -8
echo "(count: $(mysql -N -e "SHOW TABLES FROM slurm_acct_db;" | wc -l))"
