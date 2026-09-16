#!/bin/bash
# Test the vendor-Slurm detection guard in 03-slurm-controller.sh
echo "=== 1. is the fake vendor package installed? ==="
dpkg -l | grep -c '^ii  slurm23' || true

echo
echo "=== 2. run the EXACT matcher from the script ==="
VENDOR_SLURM="$(dpkg -l 2>/dev/null | awk '/^ii/ && $2 ~ /^slurm[0-9]/ {print $2" "$3}' | head -5)"
echo "matcher output: [${VENDOR_SLURM}]"
if [ -n "$VENDOR_SLURM" ]; then
  echo "PASS: guard would fire"
else
  echo "FAIL: guard would NOT fire"
fi

echo
echo "=== 3. now run 03 and confirm it refuses ==="
timeout 120 bash /mnt/c/Users/20210859/Documents/i3d-slurm-poc/scripts/03-slurm-controller.sh > /tmp/guard.log 2>&1
rc=$?
echo "exit=$rc (expect 1)"
head -14 /tmp/guard.log

echo
echo "=== 4. cleanup: remove fake package ==="
dpkg -r slurm23.02-client >/dev/null 2>&1 && echo "removed" || echo "nothing to remove"
