#!/bin/bash
# Verify the SIGPIPE fix and the root guard in 03-slurm-controller.sh
set -uo pipefail
SCRIPT=/mnt/c/Users/20210859/Documents/i3d-slurm-poc/scripts/03-slurm-controller.sh

echo "=== 1. DB password generation must not die from SIGPIPE ==="
for i in 1 2 3 4 5; do
  out=$(bash -c '
    set -euo pipefail
    DB_PASS="$(head -c 512 /dev/urandom | base64 | tr -dc "a-zA-Z0-9" | cut -c1-24)"
    echo "len=${#DB_PASS} val=${DB_PASS:0:6}..."
  ' 2>&1)
  echo "  run $i: rc=$? $out"
done

echo
echo "=== 2. root guard present and fires when not root ==="
grep -q 'EUID' "$SCRIPT" && echo "  guard present" || echo "  GUARD MISSING"
# run as a non-root user -> must exit 1 with a clear message
if id ubuntu >/dev/null 2>&1; then
  sudo -u ubuntu bash "$SCRIPT" >/tmp/g.out 2>&1
  rc=$?
  echo "  as ubuntu: rc=$rc"
  head -3 /tmp/g.out | sed 's/^/    /'
else
  echo "  (no ubuntu user to test with)"
fi

echo
echo "=== 3. the OLD pattern still fails (proving the test is meaningful) ==="
out=$(bash -c 'set -euo pipefail; P=$(tr -dc "a-zA-Z0-9" </dev/urandom | head -c 24); echo "len=${#P}"' 2>&1)
echo "  old pattern: rc=$? output='$out'"
