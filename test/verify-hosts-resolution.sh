#!/bin/bash
# Regression test for the 01-base.sh /etc/hosts logic.
#
# Covers the root cause of the multi-node failure:
#   hgx20$ sinfo
#   sinfo: error: Unable to contact slurm controller (connect failure)
#   slurm_load_partitions: Socket timed out on send/recv operation
#
# Two independent traps, both fixed in 01-base.sh:
#   1. Debian/Ubuntu's `127.0.1.1 <hostname>` line makes a node's own name
#      resolve to LOOPBACK. SlurmctldHost=<name> then binds loopback and no
#      other node can reach the controller.
#   2. A stale/partial /etc/hosts cluster block must be repaired, not trusted
#      just because the marker is present.
#
# Run on the target nodes; requires root.
set -u

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

extract_block() {
  sed -n '/# BEGIN i3d-slurm-cluster/,/# END i3d-slurm-cluster/p' /etc/hosts 2>/dev/null | grep -v '^#'
}

# ---- the logic under test (verbatim from 01-base.sh) --------------------
apply_hosts_logic() {
  local HOSTS_BLOCK="$1"
  for _node in $(echo "$HOSTS_BLOCK" | awk '{print $2}'); do
    if grep -qE "^[[:space:]]*127\.[0-9.]+[[:space:]]+.*\b${_node}\b" /etc/hosts 2>/dev/null; then
      sed -i -E "/^[[:space:]]*127\.[0-9.]+[[:space:]]+.*\b${_node}\b/d" /etc/hosts
    fi
  done
  if [[ "$(extract_block)" != "$HOSTS_BLOCK" ]]; then
    sed -i '/# BEGIN i3d-slurm-cluster/,/# END i3d-slurm-cluster/d' /etc/hosts
    { echo "# BEGIN i3d-slurm-cluster"; echo "$HOSTS_BLOCK"; echo "# END i3d-slurm-cluster"; } >> /etc/hosts
    echo "UPDATED"
  else
    echo "UNCHANGED"
  fi
}

MYNAME="$(hostname -s)"
MYIP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)"
[[ -z "$MYIP" ]] && MYIP="$(hostname -I | awk '{print $1}')"
BLOCK="${MYIP}  ${MYNAME}"

cleanup() {
  sed -i '/# BEGIN i3d-slurm-cluster/,/# END i3d-slurm-cluster/d' /etc/hosts
  if ! grep -qE "^127\.0\.1\.1" /etc/hosts; then
    echo "127.0.1.1  ${MYNAME}" >> /etc/hosts
  fi
}
trap cleanup EXIT

echo "host=${MYNAME} lan_ip=${MYIP}"

echo
echo "=== 1. missing block -> must UPDATE ==="
cleanup
r="$(apply_hosts_logic "$BLOCK")"
[[ "$r" == "UPDATED" ]] && ok "created the cluster block" || bad "expected UPDATED, got $r"

echo
echo "=== 2. correct block -> must be left alone ==="
r="$(apply_hosts_logic "$BLOCK")"
[[ "$r" == "UNCHANGED" ]] && ok "idempotent re-run" || bad "expected UNCHANGED, got $r"

echo
echo "=== 3. stale block -> must be repaired ==="
sed -i '/# BEGIN i3d-slurm-cluster/,/# END i3d-slurm-cluster/d' /etc/hosts
{ echo "# BEGIN i3d-slurm-cluster"; echo "10.9.9.9  ${MYNAME}"; echo "# END i3d-slurm-cluster"; } >> /etc/hosts
r="$(apply_hosts_logic "$BLOCK")"
[[ "$r" == "UPDATED" ]] && ok "repaired the stale block" || bad "expected UPDATED, got $r"

echo
echo "=== 4. loopback shadowing -> own name must resolve to the LAN IP ==="
sed -i '/# BEGIN i3d-slurm-cluster/,/# END i3d-slurm-cluster/d' /etc/hosts
sed -i -E "/^[[:space:]]*127\.[0-9.]+[[:space:]]+.*\b${MYNAME}\b/d" /etc/hosts
echo "127.0.1.1  ${MYNAME}" >> /etc/hosts          # simulate the Ubuntu default
before="$(getent ahostsv4 "$MYNAME" | awk '{print $1}' | head -1)"
apply_hosts_logic "$BLOCK" >/dev/null
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
echo "=== summary ==="
echo "  passed=$PASS failed=$FAIL"
[[ "$FAIL" == "0" ]] || exit 1
