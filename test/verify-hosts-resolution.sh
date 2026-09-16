#!/bin/bash
# Regression test for the cluster-hostname logic in scripts/lib.sh.
#
# Covers the root cause of the multi-node failure:
#   hgx20$ sinfo
#   sinfo: error: Unable to contact slurm controller (connect failure)
#   slurm_load_partitions: Socket timed out on send/recv operation
#
# Traps fixed in install_cluster_hosts():
#   1. Debian/Ubuntu's `127.0.1.1 <hostname>` line makes a node's own name
#      resolve to LOOPBACK; SlurmctldHost=<name> then binds loopback.
#   2. A stale/partial cluster block must be repaired, not trusted.
#   3. A stray/duplicate mapping elsewhere in /etc/hosts wins, because
#      nsswitch is `files dns` and the FIRST match in `files` wins. Such a
#      line resolves "successfully" to the WRONG address.
#
# Tests 4-7 use names under the reserved .invalid TLD, which DNS never
# resolves, so /etc/hosts is provably the only source. An earlier version
# appended a loopback line for the REAL hostname and got non-deterministic
# results depending on what else the node's resolver knew (it passed on hgx01,
# failed on hgx20).
#
# The test is NON-DESTRUCTIVE: /etc/hosts is snapshotted and restored exactly
# on exit, so running it never changes the node's state. Installing the real
# mapping is 01-base.sh's job, not the test's.
#
# Run as root on the target nodes.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${HERE}/../scripts/lib.sh"

PASS=0
FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

HOSTS_SNAPSHOT="$(mktemp)"
cat /etc/hosts > "$HOSTS_SNAPSHOT"

restore() {
  cat "$HOSTS_SNAPSHOT" > /etc/hosts
  rm -f "$HOSTS_SNAPSHOT"
}
trap restore EXIT

MYNAME="$(hostname -s)"
MYIP="$(ip -4 route get 1.1.1.1 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)"
[[ -z "$MYIP" ]] && MYIP="$(hostname -I | awk '{print $1}')"
REAL_BLOCK="${MYIP}  ${MYNAME}"

# synthetic, DNS-proof names
SYN_A="poc-shadow-a.invalid"
SYN_B="poc-shadow-b.invalid"
SYN_BLOCK="10.100.18.5  ${SYN_A}
10.100.18.8  ${SYN_B}"

echo "host=${MYNAME} lan_ip=${MYIP}"

echo
echo "=== 1. missing block -> must UPDATE ==="
sed -i '/# BEGIN i3d-slurm-cluster/,/# END i3d-slurm-cluster/d' /etc/hosts
r="$(install_cluster_hosts "$REAL_BLOCK")"
[[ "$r" == "UPDATED" ]] && ok "created the cluster block" || bad "expected UPDATED, got $r"

echo
echo "=== 2. correct block -> must be left alone ==="
r="$(install_cluster_hosts "$REAL_BLOCK")"
[[ "$r" == "UNCHANGED" ]] && ok "idempotent re-run" || bad "expected UNCHANGED, got $r"

echo
echo "=== 3. stale block -> must be repaired ==="
sed -i '/# BEGIN i3d-slurm-cluster/,/# END i3d-slurm-cluster/d' /etc/hosts
{ echo "# BEGIN i3d-slurm-cluster"; echo "10.9.9.9  ${MYNAME}"; echo "# END i3d-slurm-cluster"; } >> /etc/hosts
r="$(install_cluster_hosts "$REAL_BLOCK")"
[[ "$r" == "UPDATED" ]] && ok "repaired the stale block" || bad "expected UPDATED, got $r"

echo
echo "=== 4. loopback shadow (.invalid name) -> must be removed ==="
sed -i '/# BEGIN i3d-slurm-cluster/,/# END i3d-slurm-cluster/d' /etc/hosts
sed -i "/${SYN_A}/d" /etc/hosts
echo "127.0.1.1  ${SYN_A}" >> /etc/hosts
before="$(getent ahostsv4 "$SYN_A" | awk '{print $1}' | head -1)"
install_cluster_hosts "$SYN_BLOCK" >/dev/null
after="$(getent ahostsv4 "$SYN_A" | awk '{print $1}' | head -1)"
echo "  before=${before}  after=${after}"
[[ "$before" == "127.0.1.1" ]] && ok "reproduced the loopback shadow (127.0.1.1)" \
                               || bad "could not force loopback shadow (got $before)"
[[ "$after" == "10.100.18.5" ]] && ok "shadow removed; name resolves to the LAN IP" \
                                || bad "expected 10.100.18.5, got $after"

echo
echo "=== 5. stray duplicate outside the block -> must lose to the block ==="
# This is the hgx20 case: an unmarked line earlier in the file wins because
# the first match in `files` is authoritative.
sed -i '/# BEGIN i3d-slurm-cluster/,/# END i3d-slurm-cluster/d' /etc/hosts
sed -i "/${SYN_B}/d" /etc/hosts
sed -i "1i 10.99.99.99  ${SYN_B}" /etc/hosts        # early, stale, unmarked
install_cluster_hosts "$SYN_BLOCK" >/dev/null
got="$(getent ahostsv4 "$SYN_B" | awk '{print $1}' | head -1)"
echo "  stale line was 10.99.99.99; resolves to ${got}"
[[ "$got" == "10.100.18.8" ]] && ok "stale unmarked mapping was overridden" \
                              || bad "expected 10.100.18.8, got $got"

echo
echo "=== 6. verify_cluster_hosts() accepts a correct mapping ==="
sed -i "/${SYN_A}/d;/${SYN_B}/d" /etc/hosts
install_cluster_hosts "$SYN_BLOCK" >/dev/null
if verify_cluster_hosts "$SYN_BLOCK"; then
  ok "verifier accepted the correct mapping"
else
  bad "verifier rejected the correct mapping"
fi

echo
echo "=== 7. verify_cluster_hosts() rejects a wrong mapping ==="
echo "127.0.1.1  ${SYN_A}" >> /etc/hosts
if verify_cluster_hosts "$SYN_BLOCK" >/dev/null 2>&1; then
  bad "verifier accepted a loopback shadow (it must reject)"
else
  ok "verifier rejected the loopback shadow"
fi

echo
echo "=== 8. reality check: own name resolves to the LAN IP ==="
sed -i "/${SYN_A}/d;/${SYN_B}/d" /etc/hosts
sed -i '/# BEGIN i3d-slurm-cluster/,/# END i3d-slurm-cluster/d' /etc/hosts
install_cluster_hosts "$REAL_BLOCK" >/dev/null
got="$(getent ahostsv4 "$MYNAME" | awk '{print $1}' | head -1)"
echo "  ${MYNAME} -> ${got}"
if [[ "$got" == "$MYIP" ]]; then
  ok "own name resolves to the LAN address"
else
  bad "expected ${MYIP}, got ${got}"
  show_cluster_hosts_sources "$REAL_BLOCK"
fi

echo
echo "=== summary ==="
echo "  passed=$PASS failed=$FAIL"
[[ "$FAIL" == "0" ]] || exit 1
