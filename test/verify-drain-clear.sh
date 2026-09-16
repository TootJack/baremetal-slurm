#!/bin/bash
# Reproduce the hgx01/hgx20 situation - a node holding DRAIN after a FAILED
# registration (INVALID_REG) - then prove 03's new 8b step clears it once the
# node registers cleanly.
#
# Uses `scontrol update state=drain reason=...` to emulate the latch Slurm
# itself sets, which is what node_mgr.c leaves behind for INVALID_REG.
export PATH=/opt/slurm/bin:/opt/slurm/sbin:/usr/bin:/bin:/usr/sbin:/sbin
NODE="$(hostname -s)"

echo "=== baseline ==="
sinfo -N -o "%N %T" | sed 's/^/  /'

echo
echo "=== emulate the stale latch: drained with a GRES reason ==="
scontrol update nodename="$NODE" state=drain \
  reason="gres/gpu GRES autodetected core affinity 0-95 on node ${NODE} doesn't match socket boundaries" \
  >/dev/null 2>&1
sleep 2
sinfo -N -o "%N %T" | sed 's/^/  /'
echo "  reason: $(scontrol show node "$NODE" | grep -oE 'Reason=[^[]*' | head -1)"

echo
echo "=== does ReturnToService clear it by itself? (expect NO) ==="
systemctl restart slurmd; sleep 8
sinfo -N -o "%N %T" | sed 's/^/  /'
state="$(scontrol show node "$NODE" | grep -oE 'State=[A-Z_+]+' | head -1)"
if grep -qi drain <<<"$state"; then
  echo "  CONFIRMED: still drained after re-registration (${state#State=})"
  echo "  -> Slurm will not auto-clear it; an admin resume is required"
else
  echo "  NOTE: drain cleared on its own (${state#State=}) - env difference"
fi

echo
echo "=== run 03's 8b logic (extracted verbatim) ==="
for n in $(sinfo -N -h -o "%N %T" 2>/dev/null | awk 'tolower($2) ~ /drain/ {print $1}' | sort -u); do
  st="$(scontrol show node "$n" 2>/dev/null | grep -oE 'State=[A-Z_+]+' | head -1)"
  if grep -q "INVALID_REG" <<<"$st" || grep -q "NO_RESPOND" <<<"$st"; then
    echo "    ${n} still ${st#State=} - leaving drained (failing validation)"
  else
    reason="$(scontrol show node "$n" 2>/dev/null | grep -oE 'Reason=[^[]*' | head -1 | sed 's/^Reason=//')"
    echo "    ${n} registered cleanly but is drained; resuming"
    echo "      stale reason was: ${reason:-<none>}"
    scontrol update nodename="$n" state=resume >/dev/null 2>&1 && echo "      resumed"
  fi
done
sleep 3

echo
echo "=== final ==="
# Do NOT treat failed sinfo output as evidence: grep over an error message
# "passes" trivially. Require a successful query AND an idle node.
out="$(sinfo -N -o "%N %T %C %G" 2>&1)"
rc=$?
echo "$out" | sed 's/^/  /'
if [[ $rc -ne 0 ]] || grep -qiE 'connect failure|timed out' <<<"$out"; then
  echo "  FAIL: cannot query the controller - not a drain result"
  exit 1
fi
if grep -qiE '\bdrain|inval' <<<"$out"; then
  echo "  FAIL: still drained/inval"
  exit 1
fi
echo "  PASS: no drained/inval nodes"

echo
echo "=== and a job actually runs ==="
cd /tmp && rm -f slurm-*.out
out="$(sbatch --wrap="hostname; echo OK" 2>&1)"
if ! grep -qE '^Submitted batch job [0-9]+' <<<"$out"; then
  echo "  FAIL: submit failed: ${out}"
  exit 1
fi
jid="$(grep -oE '[0-9]+$' <<<"$out")"
# Wait for a TERMINAL state. sacct reports PENDING/COMPLETING immediately, so
# breaking on "non-empty" would return before the job had a chance to run.
st=""
for i in $(seq 1 15); do
  st="$(sacct -j "$jid" -X -n -o State 2>/dev/null | head -1 | tr -d ' ')"
  case "$st" in
    COMPLETED*|FAILED*|CANCELLED*|TIMEOUT*|OUT_OF_MEMORY*) break ;;
  esac
  sleep 3
done
echo "  state: ${st:-<none>}"
[[ "$st" == COMPLETED* ]] && echo "  PASS: job completed" || echo "  FAIL: job state=${st:-none}"
echo "  output:"; cat "slurm-${jid}.out" 2>/dev/null | sed 's/^/    /'
