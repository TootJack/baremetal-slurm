#!/bin/bash
# Run the hosts test repeatedly to prove it is deterministic (the earlier
# version passed on hgx20 and failed on hgx01 with identical code).
set -u
T="$(dirname "$0")/verify-hosts-resolution.sh"
fails=0
for i in 1 2 3; do
  out="$(bash "$T" 2>&1)"
  rc=$?
  line="$(grep 'passed=' <<<"$out" | tail -1)"
  echo "  run $i: exit=$rc  ${line}"
  [[ $rc -ne 0 ]] && { fails=$((fails+1)); grep -E "FAIL" <<<"$out" | sed 's/^/    /'; }
done
echo
if [[ $fails -eq 0 ]]; then echo "PASS: deterministic across 3 runs"; else echo "FAIL: $fails run(s) failed"; fi
exit $fails
