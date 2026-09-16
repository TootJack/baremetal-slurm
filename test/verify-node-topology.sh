#!/bin/bash
# Verify detect_node() preserves the FULL CPU topology, and that the produced
# line would not trigger the INVALID_REG we saw on hgx01:
#   Reason=gres/gpu GRES autodetected core affinity 0-95 on node hgx01 doesn't
#   match socket boundaries. (Socket 0 is cores 0-0).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${HERE}/../scripts/lib.sh"

PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

NODE="$(hostname -s)"
raw="$(slurmd -C 2>/dev/null | grep -m1 '^NodeName=' || true)"
echo "=== slurmd -C (raw) ==="
echo "  $raw"

line="$(detect_node "$NODE")"
echo
echo "=== detect_node() output ==="
echo "  $line"

echo
echo "=== required topology fields are carried through ==="
for f in CPUs Boards SocketsPerBoard CoresPerSocket ThreadsPerCore RealMemory; do
  if grep -q "${f}=" <<<"$raw"; then
    if grep -q "${f}=" <<<"$line"; then
      ok "${f} preserved"
    else
      bad "${f} DROPPED (raw has it, our line does not)"
    fi
  else
    echo "  skip ${f} (not emitted here)"
  fi
done

echo
echo "=== values match slurmd's own ==="
# extract each key=value from slurmd's output and require it verbatim in ours
mismatch=0
for kv in $(grep -oE '[A-Za-z]+=[^ ]+' <<<"$raw" | grep -v '^NodeName='); do
  k="${kv%%=*}"
  [[ "$k" == "NodeName" ]] && continue
  if ! grep -qE "(^| )${kv}( |$)" <<<"$line"; then
    echo "    missing/changed: ${kv}"
    mismatch=1
  fi
done
[[ $mismatch -eq 0 ]] && ok "every slurmd-reported field appears verbatim" \
                      || bad "some fields were altered"

echo
echo "=== our line is parseable as a slurm.conf NodeName stanza ==="
printf '%s\n' "$line" > /tmp/stanza.conf
grep -qE "^NodeName=${NODE}([[:space:]]|$)" /tmp/stanza.conf \
  && ok "starts with NodeName=${NODE}" || bad "bad NodeName prefix"
grep -q "State=UNKNOWN" <<<"$line" && ok "State=UNKNOWN set" || bad "no State="
# exactly one Gres= (duplicates would be a config error)
n="$(grep -o 'Gres=' <<<"$line" | wc -l | tr -d ' ')"
[[ "$n" -le 1 ]] && ok "at most one Gres= (found $n)" || bad "duplicate Gres= ($n)"

echo
echo "=== the specific hgx01 failure cannot recur ==="
if grep -q "CoresPerSocket=" <<<"$raw"; then
  # slurmctld computes socket boundaries from CoresPerSocket
  if grep -q "CoresPerSocket=" <<<"$line"; then
    ok "CoresPerSocket present, so socket boundaries are correct"
    echo "    (hgx01 failed because this was absent -> slurmctld assumed"
    echo "     CoresPerSocket=1 -> 'Socket 0 is cores 0-0')"
  else
    bad "CoresPerSocket absent - INVALID_REG would recur on GPU nodes"
  fi
else
  echo "  n/a on this machine"
fi

echo
echo "=== summary ==="
echo "  passed=$PASS failed=$FAIL"
[[ "$FAIL" == "0" ]] || exit 1
