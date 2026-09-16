#!/bin/bash
# Regression test for the cluster-hostname logic in scripts/lib.sh.
#
# Covers the root cause of the multi-node failure:
#   hgx20$ sinfo
#   sinfo: error: Unable to contact slurm controller (connect failure)
#   slurm_load_partitions: Socket timed out on send/recv operation
#
# Two independent traps, both fixed in install_cluster_hosts():
#   1. Debian/Ubuntu's `127.0.1.1 <hostname>` line makes a node's own name
#      resolve to LOOPBACK. SlurmctldHost=<name> then binds loopback and no
#      other node can reach the controller.
#   2. A stale/partial /etc/hosts cluster block must be repaired, not trusted
#      just because the marker is present.
#
# This test exercises the SAME code 01-base.sh runs (sourced from lib.sh),
# not a copy. It snapshots /etc/hosts up front and RESTORES that snapshot on
# exit, so running it never leaves the node less correct than it found it.
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

# ---- snapshot /etc/hosts, always restore it ---------------------------
HOSTS_SNAPSHOT="$(mktemp)"
cat /etc/hosts > "$HOSTS_SNAPSHOT"

restore() {
  cat "$HOSTS_SNAPSHOT" > /etc/hosts
  rm -f "$HOSTS_SNAPSHOT"
  # Leave the node with a CORRECT mapping, not the one it happened to have:
  # a node that failed the test must not be left broken.
  install_cluster_hosts "$(cluster_hosts_block)" >/dev/null
}
trap restore EXIT

MYNAME="$(hostname -s)"
MYIP="$(ip -4 route get 1.1.1.1 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)"
[[ -z "$MYIP" ]] && MYIP="$(hostname -I | awk '{print $1}')"
BLOCK="${MYIP}  ${MYNAME}"

echo "host=${MYNAME} lan_ip=${MYIP}"

echo
echo "=== 1. missing block -> must UPDATE ==="
sed -i '/# BEGIN i3d-slurm-cluster/,/# END i3d-slurm-cluster/d' /etc/hosts
r="$(install_cluster_hosts "$BLOCK")"
[[ "$r" == "UPDATED" ]] && ok "created the cluster block" || bad "expected UPDATED, got $r"

echo
echo "=== 2. correct block -> must be left alone ==="
r="$(install_cluster_hosts "$BLOCK")"
[[ "$r" == "UNCHANGED" ]] && ok "idempotent re-run" || bad "expected UNCHANGED, got $r"

echo
echo "=== 3. stale block -> must be repaired ==="
sed -i '/# BEGIN i3d-slurm-cluster/,/# END i3d-slurm-cluster/d' /etc/hosts
{ echo "# BEGIN i3d-slurm-cluster"; echo "10.9.9.9  ${MYNAME}"; echo "# END i3d-slurm-cluster"; } >> /etc/hosts
r="$(install_cluster_hosts "$BLOCK")"
[[ "$r" == "UPDATED" ]] && ok "repaired the stale block" || bad "expected UPDATED, got $r"

echo
echo "=== 4. loopback shadowing -> own name must resolve to the LAN IP ==="
sed -i '/# BEGIN i3d-slurm-cluster/,/# END i3d-slurm-cluster/d' /etc/hosts
sed -i -E "/^[[:space:]]*127\.[0-9.]+[[:space:]]+.*\b${MYNAME}\b/d" /etc/hosts
echo "127.0.1.1  ${MYNAME}" >> /etc/hosts          # simulate the Ubuntu default
before="$(getent ahostsv4 "$MYNAME" | awk '{print $1}' | head -1)"
install_cluster_hosts "$BLOCK" >/dev/null
after="$(getent ahostsv4 "$MYNAME" | awk '{print $1}' | head -1)"
echo "  before=${before}  after=${after}"
if [[ "$before" == "127.0.1.1" ]]; then
  ok "reproduced the loopback shadow (127.0.1.1)"
else
  bad "could not reproduce loopback shadow (got $before)"
fi
[[ "$after" == "$MYIP" ]] && ok "own name now resolves to the LAN address" \
                          || bad "expected $MYIP, got $after"

echo
echo "=== 5. verify_cluster_hosts() accepts a correct mapping ==="
sed -i '/# BEGIN i3d-slurm-cluster/,/# END i3d-slurm-cluster/d' /etc/hosts
install_cluster_hosts "$BLOCK" >/dev/null
if verify_cluster_hosts "$BLOCK"; then
  ok "verifier accepted the correct mapping"
else
  bad "verifier rejected the correct mapping"
fi

echo
echo "=== 6. verify_cluster_hosts() rejects a wrong mapping ==="
sed -i -E "/^[[:space:]]*127\.[0-9.]+[[:space:]]+.*\b${MYNAME}\b/d" /etc/hosts
echo "127.0.1.1  ${MYNAME}" >> /etc/hosts
if verify_cluster_hosts "$BLOCK" >/dev/null 2>&1; then
  bad "verifier accepted a loopback shadow (it must reject)"
else
  ok "verifier rejected the loopback shadow"
fi

echo
echo "=== summary ==="
echo "  passed=$PASS failed=$FAIL"
[[ "$FAIL" == "0" ]] || exit 1
