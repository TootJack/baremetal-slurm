#!/bin/bash
# Reproduce the bug that made 03-slurm-controller.sh exit silently.
echo "=== current (buggy) pattern: tr | head ==="
for i in 1 2 3 4 5 6 7 8 9 10; do
  out=$(bash -c '
    set -euo pipefail
    P=$(tr -dc "a-zA-Z0-9" </dev/urandom | head -c 24)
    echo "len=${#P}"
  ' 2>&1)
  rc=$?
  echo "run $i: rc=$rc  $out"
done
