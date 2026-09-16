#!/usr/bin/env bash
# =====================================================================
# fabric-verify.sh - confirm the two nodes are interconnected BEFORE
# installing Slurm.
#
#   Stage 1 (no coordination needed):
#     bash scripts/fabric-verify.sh check
#
#   Stage 2 (needs both nodes; run server first, then client):
#     on hgx01:  bash scripts/fabric-verify.sh server
#     on hgx20:  bash scripts/fabric-verify.sh client 10.100.18.5
# =====================================================================
set -uo pipefail

MODE="${1:-check}"
PEER_IP="${2:-10.100.18.5}"
LUSTRE="${LUSTRE:-/mnt/i3d_20tb}"

hr() { printf '\n========== %s ==========\n' "$*"; }

# ---------------------------------------------------------------
# CHECK - everything that needs no second machine / no coordination
# ---------------------------------------------------------------
if [ "$MODE" = "check" ]; then
  hr "HOST $(hostname -s) $(hostname -I | awk '{print $1}')  $(date -Is)"

  hr "1. IP REACHABILITY (bond0, 10.100.18.0/24)"
  for ip in 10.100.18.5 10.100.18.8; do
    if ping -c 2 -W 2 "$ip" >/dev/null 2>&1; then
      echo "  $ip : REACHABLE"
    else
      echo "  $ip : unreachable$( [ "$ip" = "$(hostname -I | awk '{print $1}')" ] && echo ' (this node)')"
    fi
  done

  hr "2. SSH BETWEEN NODES (needs key auth - may prompt)"
  for ip in 10.100.18.5 10.100.18.8; do
    [ "$ip" = "$(hostname -I | awk '{print $1}')" ] && continue
    timeout 10 ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
      -o ConnectTimeout=5 "ubuntu@$ip" 'echo SSH OK from $(hostname -s)' 2>&1 | head -2
  done

  hr "3. IB FABRIC (this decides multi-node NCCL)"
  echo "devices:"
  for d in /sys/class/infiniband/*/ports/*/state; do
    [ -f "$d" ] || continue
    dev="$(echo "$d" | cut -d/ -f5)"
    printf "  %-16s %s\n" "$dev" "$(cat "$d")"
  done
  echo "LIDs (assigned = fabric configured by a subnet manager):"
  ibstat -l 2>/dev/null | head -10
  command -v ibstatus >/dev/null 2>&1 && \
    ibstatus 2>/dev/null | grep -E "rate|state|link_layer" | head -12
  echo "subnet manager on this host: $(systemctl is-active opensm 2>/dev/null || echo inactive)"
  echo "  ^ inactive here is FINE: i3D runs the SM upstream (sm_lid 1 is set)"

  hr "4. RDMA / RoCE PATH"
  rdma link 2>/dev/null | head -10
  echo "note: bond0 slaves are RoCE-capable (rocep157s0f0 / enp157s0f0np0)"
  echo "      so RDMA over bond0 is possible even without IPoIB"

  hr "5. SHARED FILESYSTEM (Lustre) - must be identical on both nodes"
  if mount | grep -q lustre; then
    mount | grep lustre | head -2
    echo "--- write test as $(whoami) ---"
    if touch "$LUSTRE/verify-$(hostname -s)-$(date +%s)" 2>/dev/null; then
      echo "  write OK"
      echo "--- files from BOTH hosts (proves shared) ---"
      ls -la "$LUSTRE"/verify-* 2>/dev/null | head -10
      echo "  ^ seeing a 'verify-<otherhost>-*' file means Lustre is genuinely shared"
    else
      echo "  write FAILED - check permissions on $LUSTRE"
    fi
    echo "--- capacity ---"
    df -h "$LUSTRE" | tail -2
  else
    echo "  NO lustre mount on this node"
  fi

  hr "6. LOCAL SCRATCH"
  df -h / /local /tmp 2>/dev/null | grep -vE "^Filesystem" | head -5

  hr "VERDICT"
  echo "Multi-node is viable if:"
  echo "  [ ] both IPs reachable (section 1)"
  echo "  [ ] all IB ports ACTIVE + LIDs present (section 3)"
  echo "  [ ] Lustre visible and writable on BOTH nodes (section 5)"
  echo "Then optionally run the bandwidth test (server/client)."
  exit 0
fi

# ---------------------------------------------------------------
# SERVER - bandwidth test, one device at a time
# ---------------------------------------------------------------
if [ "$MODE" = "server" ]; then
  hr "PERFTEST SERVER on $(hostname -s) $(date -Is)"
  echo "Use the RoCE device first (bond0 path), then one IB device."
  echo "Each test waits up to 45s for the client to connect."
  echo

  DEVS="${DEVS:-rocep157s0f0 ibp26s0}"
  for dev in $DEVS; do
    echo "===== device: $dev ====="
    ip addr show "rocep157s0f0" >/dev/null 2>&1
    timeout 45 ib_write_bw -d "$dev" -a -F --report_gbits -q 1 2>&1 | tail -22
    echo
    echo "----- $dev done -----"
    echo
  done
  hr "SERVER DONE"
  exit 0
fi

# ---------------------------------------------------------------
# CLIENT
# ---------------------------------------------------------------
if [ "$MODE" = "client" ]; then
  hr "PERFTEST CLIENT on $(hostname -s) -> $PEER_IP  $(date -Is)"

  hr "ip route to peer"
  ip route get "$PEER_IP" 2>/dev/null | head -2

  DEVS="${DEVS:-rocep157s0f0 ibp26s0}"
  for dev in $DEVS; do
    echo "===== device: $dev -> $PEER_IP ====="
    timeout 40 ib_write_bw -d "$dev" -a -F --report_gbits -q 1 "$PEER_IP" 2>&1 | tail -22
    echo
    echo "----- $dev done -----"
    echo
  done

  hr "CLIENT DONE"
  echo "Copy the bandwidth tables from BOTH nodes for comparison."
  exit 0
fi

echo "usage: $0 check | server | client <peer-ip>"
