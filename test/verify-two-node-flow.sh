#!/bin/bash
# Simulate the FULL corrected two-node order on one machine:
#   1. node2 publishes its own line (04 does this before starting slurmd)
#   2. 03 runs with NODE2_HOST and must READ that line, not invent one
#
# A fake hostname is used for the second node so the machine genuinely cannot
# derive its resources locally under that name.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${HERE}/../scripts/lib.sh"

FAKE="hgx99-fake"

echo "=== 1. node2 publishes its own line (as 04 does) ==="
line="$(publish_own_node_line "$FAKE")"
echo "    $line"
stage="$(cluster_stage_dir)"
ls -l "${stage}/node-${FAKE}.conf" 2>/dev/null | sed 's/^/    /'

echo
echo "=== 2. controller reads it via fetch_remote_node_line ==="
got="$(fetch_remote_node_line "$FAKE")"
if [[ "$got" == "$line" ]]; then
  echo "    PASS: controller obtained node2's OWN line:"
  echo "      $got"
else
  echo "    FAIL: got '${got:-<empty>}'"
  exit 1
fi

echo
echo "=== 3. it must NOT be this machine's hardware mislabelled ==="
# detect_node always describes the LOCAL machine. The controller must never
# call it for the remote host - that was the original bug.
if [[ "$got" == *"$FAKE"* ]]; then
  echo "    PASS: line is named for ${FAKE}"
else
  echo "    FAIL: line does not name ${FAKE}"; exit 1
fi

echo
echo "=== 4. build the multi-node conf fragment 03 would write ==="
NODE1="$(hostname -s)"
NODE_LINES="$(detect_node "$NODE1")
${got}"
echo "$NODE_LINES" | sed 's/^/    /'
count="$(grep -cE '^NodeName=' <<<"$NODE_LINES")"
if [[ "$count" == "2" ]]; then
  echo "    PASS: both nodes present"
else
  echo "    FAIL: expected 2 NodeName lines, got $count"; exit 1
fi

echo
echo "=== 5. each line names a DIFFERENT host ==="
names="$(awk '{print $1}' <<<"$NODE_LINES" | sort -u | wc -l | tr -d ' ')"
[[ "$names" == "2" ]] && echo "    PASS: distinct hosts" || { echo "    FAIL: $names distinct"; exit 1; }

echo
echo "=== cleanup: remove the fake node's published line ==="
rm -f "${stage}/node-${FAKE}.conf"
echo "    removed ${stage}/node-${FAKE}.conf"
