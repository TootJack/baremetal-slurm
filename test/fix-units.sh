#!/bin/bash
# Regenerate systemd units using Type=simple + -D (no PID-file race)
PREFIX=/opt/slurm

install_unit() {   # $1=name $2=exec $3=description
  cat > "/etc/systemd/system/$1.service" <<UNIT
[Unit]
Description=$3
After=network.target munge.service
Wants=munge.service

[Service]
Type=simple
ExecStart=$2 -D
ExecReload=/bin/kill -HUP \$MAINPID
User=root
Restart=on-failure
RestartSec=5
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
UNIT
  echo "  unit: $1 -> $2 -D"
}

install_unit slurmctld "$PREFIX/sbin/slurmctld" "Slurm controller daemon"
install_unit slurmd    "$PREFIX/sbin/slurmd"    "Slurm node daemon"
install_unit slurmdbd  "$PREFIX/sbin/slurmdbd"  "Slurm DBD accounting daemon"
sed -i "s|^After=.*|After=network.target munge.service mariadb.service|" \
  /etc/systemd/system/slurmdbd.service

systemctl daemon-reload
for s in slurmdbd slurmctld slurmd; do
  systemctl reset-failed "$s" 2>/dev/null
  systemctl restart "$s"
done
sleep 8
export PATH=/opt/slurm/bin:/opt/slurm/sbin:/usr/bin:/bin:/usr/sbin:/sbin
echo
echo "=== daemons ==="
for s in munge mariadb slurmdbd slurmctld slurmd; do
  printf "  %-10s %s\n" "$s" "$(systemctl is-active "$s" 2>/dev/null || echo unknown)"
done
echo
echo "=== node state ==="
sinfo -N -o "%N %T %C %G" 2>&1 | head -4
echo
echo "=== slurmd recent errors ==="
journalctl -u slurmd --since "1 min ago" --no-pager 2>/dev/null \
  | grep -viE "environment|Scheduled restart" | tail -4
