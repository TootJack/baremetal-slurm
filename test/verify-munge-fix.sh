#!/bin/bash
# Reproduce the hgx01 munge failure and prove the fix.
# hgx01 had: OPTIONS="--key-file=/cm/shared/apps/slurm/var/munge/keys/munge.key"
#            (a vendor path that does not exist) -> munged exits 1.

echo "=== 1. REPRODUCE: plant the vendor OPTIONS ==="
systemctl stop munge 2>/dev/null
cat > /etc/default/munge <<'EOF'
# MUNGE configuration
OPTIONS="--key-file=/cm/shared/apps/slurm/var/munge/keys/munge.key"
EOF
systemctl reset-failed munge 2>/dev/null
systemctl start munge 2>&1 | head -3
sleep 2
echo "munge state with vendor OPTIONS: $(systemctl is-active munge)"
journalctl -u munge -n 3 --no-pager 2>/dev/null | tail -2

echo
echo "=== 2. APPLY THE FIX (what the scripts now do) ==="
cat > /etc/default/munge <<'EOF'
# MUNGE configuration - managed by the i3D Slurm POC scripts.
# Pinned to the standard key path; a vendor --key-file here would override
# /etc/munge/munge.key because the unit runs `munged $OPTIONS`.
OPTIONS="--key-file=/etc/munge/munge.key"
EOF
mkdir -p /etc/munge
[ -s /etc/munge/munge.key ] || dd if=/dev/urandom bs=1 count=1024 of=/etc/munge/munge.key 2>/dev/null
chown munge:munge /etc/munge/munge.key
chmod 400 /etc/munge/munge.key
systemctl reset-failed munge 2>/dev/null
systemctl restart munge
sleep 2

echo "munge state after fix: $(systemctl is-active munge)"
if munge -n 2>/dev/null | unmunge 2>/dev/null | grep -qE '^STATUS: *Success'; then
  echo "PASS: munge authenticates (STATUS: Success)"
else
  echo "FAIL: munge still broken"
  journalctl -u munge -n 5 --no-pager 2>/dev/null | tail -4
fi
