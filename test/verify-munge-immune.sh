#!/bin/bash
# Prove the new full munge unit defeats the vendor override.
# Vendor left: OPTIONS="--key-file=/cm/shared/apps/slurm/var/munge/keys/munge.key"
# AND the value somehow survived rewriting /etc/default/munge on hgx01.

echo "=== 1. plant the hostile vendor state ==="
systemctl stop munge 2>/dev/null
cat > /etc/default/munge <<'EOF'
OPTIONS="--key-file=/cm/shared/apps/slurm/var/munge/keys/munge.key"
EOF
# also add a drop-in that would re-inject it, the strongest form
mkdir -p /etc/systemd/system/munge.service.d
cat > /etc/systemd/system/munge.service.d/vendor.conf <<'EOF'
[Service]
Environment=OPTIONS=--key-file=/cm/shared/apps/slurm/var/munge/keys/munge.key
EOF
systemctl daemon-reload
systemctl reset-failed munge 2>/dev/null
systemctl restart munge 2>/dev/null
sleep 2
echo "BEFORE fix: munge=$(systemctl is-active munge 2>/dev/null)"
systemctl cat munge 2>/dev/null | grep -m1 ExecStart | sed 's/^/  effective: /'

echo
echo "=== 2. apply what the script now does ==="
rm -f /etc/systemd/system/munge.service.d/*.conf 2>/dev/null
rmdir /etc/systemd/system/munge.service.d 2>/dev/null
cat > /etc/systemd/system/munge.service <<'UNIT'
[Unit]
Description=MUNGE authentication service (i3D POC - pinned key path)
After=time-sync.target

[Service]
Type=forking
ExecStart=/usr/sbin/munged --key-file=/etc/munge/munge.key
PIDFile=/run/munge/munged.pid
RuntimeDirectory=munge
RuntimeDirectoryMode=0755
User=munge
Group=munge
Restart=on-abort

[Install]
WantedBy=multi-user.target
UNIT
: > /etc/default/munge
mkdir -p /etc/munge
[ -s /etc/munge/munge.key ] || dd if=/dev/urandom bs=1 count=1024 of=/etc/munge/munge.key 2>/dev/null
chown munge:munge /etc/munge/munge.key
chmod 400 /etc/munge/munge.key
systemctl daemon-reload
systemctl reset-failed munge 2>/dev/null
systemctl restart munge 2>/dev/null || true
sleep 2

echo "AFTER fix: munge=$(systemctl is-active munge 2>/dev/null)"
systemctl cat munge 2>/dev/null | grep -m1 ExecStart | sed 's/^/  effective: /'
if munge -n 2>/dev/null | unmunge 2>/dev/null | grep -qE '^STATUS: *Success'; then
  echo "PASS: munge authenticates despite the hostile vendor config"
else
  echo "FAIL: still broken"; journalctl -u munge -n 5 --no-pager | tail -4
fi
