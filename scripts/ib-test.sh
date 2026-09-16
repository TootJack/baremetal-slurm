#!/usr/bin/env bash
# =====================================================================
# ib-test.sh - measure the NATIVE 400 Gb/s InfiniBand rails
#
# The ibp* devices are IPoIB with no IP, and ib_write_bw uses TCP for its
# out-of-band handshake - so it cannot be tested as-is. This script assigns
# a temporary IP, measures, then removes it. Fully reversible.
#
#   hgx01:  bash scripts/ib-test.sh server
#   hgx20:  bash scripts/ib-test.sh client 10.100.18.5
#
# Optional: DEVS="ibp26s0 ibp60s0 ..." to test specific rails.
#           ALL=1 to test all 8 rails (slower).
# =====================================================================
set -uo pipefail

MODE="${1:-}"
PEER="${2:-10.100.18.5}"
SUBNET="${SUBNET:-192.168.100}"
ALL="${ALL:-0}"

# one IP per node on the IPoIB test subnet
case "$(hostname -s)" in
  hgx01) MY_IP="${SUBNET}.1" ;;
  hgx20) MY_IP="${SUBNET}.2" ;;
  *)     MY_IP="${SUBNET}.99" ;;
esac

hr() { printf '\n========== %s ==========\n' "$*"; }

# default: first rail only (fast proof). ALL=1 -> every 400G rail.
if [ "$ALL" = "1" ]; then
  DEVS="${DEVS:-$(ls /sys/class/infiniband | grep '^ibp' | sort)}"
else
  DEVS="${DEVS:-ibp26s0}"
fi

cleanup() {
  hr "CLEANUP - removing temporary IPs"
  for dev in $DEVS; do
    ip addr del "${MY_IP}/24" dev "$dev" 2>/dev/null && echo "  removed ${MY_IP} from $dev"
  done
}
trap cleanup EXIT

hr "IB TEST $( [ "$MODE" = server ] && echo SERVER || echo CLIENT ) on $(hostname -s)"
echo "test subnet : ${SUBNET}.0/24"
echo "my test IP  : ${MY_IP}"
echo "devices     : $(echo $DEVS | tr '\n' ' ')"

# ---------------------------------------------------------------
# Assign the temporary IP to each device under test
# ---------------------------------------------------------------
hr "ASSIGNING TEMPORARY IPs"
for dev in $DEVS; do
  ip addr add "${MY_IP}/24" dev "$dev" 2>/dev/null \
    && echo "  $dev <- ${MY_IP}/24" \
    || echo "  $dev: already has ${MY_IP} (or failed)"
done

# show what the fabric looks like
hr "DEVICE STATE"
for dev in $DEVS; do
  echo "--- $dev ---"
  cat "/sys/class/infiniband/$dev/ports/1/state" 2>/dev/null
  cat "/sys/class/infiniband/$dev/ports/1/rate" 2>/dev/null
  ip -br addr show "$dev" 2>/dev/null
done

# ---------------------------------------------------------------
# SERVER
# ---------------------------------------------------------------
if [ "$MODE" = "server" ]; then
  hr "LISTENING (each device waits up to 60s for the client)"
  for dev in $DEVS; do
    echo "===== $dev ====="
    timeout 60 ib_write_bw -d "$dev" -a -F --report_gbits -q 1 2>&1 | tail -24
    echo
  done
  hr "SERVER DONE - compare BW with the client output"
  exit 0
fi

# ---------------------------------------------------------------
# CLIENT
# ---------------------------------------------------------------
if [ "$MODE" = "client" ]; then
  PEER_IP="$(getent hosts "$PEER" 2>/dev/null | awk '{print $1}')"
  [ -z "$PEER_IP" ] && PEER_IP="$PEER"
  # peer lives on the same test subnet
  TARGET="${SUBNET}.$([ "${PEER_IP##*.}" = "5" ] && echo 1 || echo 2)"

  hr "TARGET"
  echo "peer host:  $PEER ($PEER_IP)"
  echo "peer test IP: $TARGET"

  hr "REACHABILITY over the test subnet"
  for dev in $DEVS; do
    if ping -c 1 -W 2 -I "$dev" "$TARGET" >/dev/null 2>&1; then
      echo "  $dev -> $TARGET : ping OK"
    else
      echo "  $dev -> $TARGET : ping FAILED (peer server may not be listening yet)"
    fi
  done

  hr "BANDWIDTH"
  for dev in $DEVS; do
    echo "===== $dev -> $TARGET ====="
    timeout 60 ib_write_bw -d "$dev" -a -F --report_gbits -q 1 "$TARGET" 2>&1 | tail -24
    echo
  done

  hr "CLIENT DONE"
  echo "Expected: ~350-400 Gb/s for a healthy 400G NDR rail."
  echo "If you see ~182 Gb/s, NCCL/perftest used the bond0 RoCE path instead."
  exit 0
fi

echo "usage: $0 server | client <peer-ip>"
echo "  ALL=1 to test all 8 rails"
