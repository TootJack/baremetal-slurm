#!/bin/bash
# Reproduce the exact hgx20 condition and prove 01-base.sh fixes it.
#
# hgx20 showed:
#   test 4: before=10.100.18.8 (could not force 127.0.1.1)
#   test 6: verifier accepted a loopback shadow
# i.e. SOME source other than the appended line resolved hgx20 to the LAN IP
# first. That means a stray/duplicate mapping existed ahead of it. This script
# plants that condition for a synthetic name and checks the fix.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${HERE}/../scripts/lib.sh"

SNAP="$(mktemp)"; cat /etc/hosts > "$SNAP"
trap 'cat "$SNAP" > /etc/hosts; rm -f "$SNAP"' EXIT

N1="hgx-sim-one.invalid"
N2="hgx-sim-two.invalid"
BLOCK="10.100.18.5  ${N1}
10.100.18.8  ${N2}"

echo "=== plant the hgx20-like condition ==="
sed -i "/${N1}/d;/${N2}/d" /etc/hosts
sed -i '/# BEGIN i3d-slurm-cluster/,/# END i3d-slurm-cluster/d' /etc/hosts
# An EARLY stray line mapping each name to the WRONG ip, exactly like a
# leftover duplicate sitting ahead of the block. Built with printf so the
# newlines are real (sed's `i` command mangles them).
{ printf '127.0.1.1  %s\n10.99.99.99  %s\n' "$N1" "$N2"; cat /etc/hosts; } > /tmp/h.planted
cat /tmp/h.planted > /etc/hosts
rm -f /tmp/h.planted
echo "  planted:"
grep -nE "${N1}|${N2}" /etc/hosts | sed 's/^/    /'
echo "  resolves before fix:"
echo "    ${N1} -> $(getent ahostsv4 "$N1" | awk '{print $1}' | head -1)"
echo "    ${N2} -> $(getent ahostsv4 "$N2" | awk '{print $1}' | head -1)"

echo
echo "=== run the real installer (lib.sh) ==="
install_cluster_hosts "$BLOCK"

echo
echo "=== result ==="
echo "  /etc/hosts now:"
grep -nE "${N1}|${N2}" /etc/hosts | sed 's/^/    /'
r1="$(getent ahostsv4 "$N1" | awk '{print $1}' | head -1)"
r2="$(getent ahostsv4 "$N2" | awk '{print $1}' | head -1)"
echo "    ${N1} -> ${r1}"
echo "    ${N2} -> ${r2}"

echo
fail=0
[[ "$r1" == "10.100.18.5" ]] && echo "  PASS: ${N1} fixed" || { echo "  FAIL: ${N1}"; fail=1; }
[[ "$r2" == "10.100.18.8" ]] && echo "  PASS: ${N2} fixed" || { echo "  FAIL: ${N2}"; fail=1; }
if verify_cluster_hosts "$BLOCK"; then echo "  PASS: verifier now agrees"; else echo "  FAIL: verifier"; fail=1; fi

echo
echo "=== idempotency: second run must be a no-op ==="
out="$(install_cluster_hosts "$BLOCK")"
[[ "$out" == "UNCHANGED" ]] && echo "  PASS: UNCHANGED on re-run" || { echo "  FAIL: got $out"; fail=1; }

echo
echo "  overall: $([[ $fail == 0 ]] && echo PASS || echo FAIL)"
exit $fail
