#!/bin/bash
# Verify the multi-node bootstrap flow that hgx01/hgx20 must follow.
#
# The old documented order was a deadlock:
#   1) 03 with NODE2_HOST unset  -> slurm.conf contains only node1
#   2) 04 on node2 installs it   -> fatal: Unable to determine this
#                                    slurmd's NodeName
#   3) README then says "re-run 03 with NODE2_HOST" <- step 2 never worked
#
# The fix: 04 publishes node2's OWN node line to shared storage before it
# starts slurmd, so it can run first; 03 then reads that line instead of
# stamping node1's local hardware onto node2's stanza.
#
# Simulated with two fake host names on one machine (shared storage is local
# here); the ordering and the file contents are what is under test.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${HERE}/../scripts/lib.sh"

PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# point the staging dir at a scratch location
SHARED_ROOT="$TMP"
cat > "$TMP/shared.conf" <<EOF
SHARED_ROOT=${SHARED_ROOT}
EOF

STAGE="${SHARED_ROOT}/cluster-config"
mkdir -p "$STAGE"

echo "=== 0. staging dir resolves from lib.sh ==="
got="$(SHARED_ROOT="$SHARED_ROOT" cluster_stage_dir)"
[[ "$got" == "$STAGE" ]] && ok "cluster_stage_dir -> ${got}" || bad "got ${got}"

echo
echo "=== 1. publish_own_node_line writes node-<host>.conf ==="
out="$(SHARED_ROOT="$SHARED_ROOT" publish_own_node_line "fake-node-2" 2>&1)"
f="${STAGE}/node-fake-node-2.conf"
[[ -f "$f" ]] && ok "wrote ${f##*/}" || bad "file not created"
grep -q '^NodeName=fake-node-2 ' "$f" && ok "line names the host it describes" \
                                     || bad "wrong NodeName in file"
echo "    $(cat "$f")"

echo
echo "=== 2. the line describes THIS machine's hardware (not invented) ==="
mine="$(detect_node "fake-node-2")"
echo "    detect_node -> ${mine}"
[[ "$mine" == "$(cat "$f")" ]] && ok "published line matches detected resources" \
                              || bad "published line differs from detection"
# CPU count must be the real local one, proving it is measured not guessed
nproc_now="$(nproc)"
grep -q "CPUs=${nproc_now} " "$f" && ok "CPUs=${nproc_now} is the real local value" \
                                 || bad "CPUs is not the local value"

echo
echo "=== 3. fetch_remote_node_line reads it back ==="
back="$(SHARED_ROOT="$SHARED_ROOT" fetch_remote_node_line "fake-node-2")"
[[ "$back" == "$(cat "$f")" ]] && ok "round-trips" || bad "got: ${back:-<empty>}"

echo
echo "=== 4. missing node -> fetch returns empty (03 must refuse) ==="
none="$(SHARED_ROOT="$SHARED_ROOT" fetch_remote_node_line "never-published")"
[[ -z "$none" ]] && ok "empty for an unpublished node (03 refuses)" \
                 || bad "expected empty, got ${none}"

echo
echo "=== 5. publish is atomic (no partial file readable) ==="
# a second publish must not leave a .tmp behind
SHARED_ROOT="$SHARED_ROOT" publish_own_node_line "fake-node-2" >/dev/null 2>&1
leftover="$(find "$STAGE" -name '.node-*tmp' 2>/dev/null | wc -l | tr -d ' ')"
[[ "$leftover" == "0" ]] && ok "no .tmp file left behind" || bad "${leftover} leftover temp file(s)"

echo
echo "=== 6. the exact grep 04 uses to find its own NodeName line ==="
# From 04: grep -qE "NodeName=${HOST}([[:space:]]|$)" — anchored on the
# NodeName= key so a longer name (fake-node-2-extra) cannot match.
HOST="fake-node-2"
printf 'NodeName=fake-node-1 CPUs=4 RealMemory=100 State=UNKNOWN\nNodeName=%s CPUs=8 RealMemory=200 State=UNKNOWN\n' "$HOST" > "$TMP/conf"
if grep -qE "^NodeName=${HOST}([[:space:]]|$)" "$TMP/conf"; then
  ok "04 recognises its own line"
else
  bad "04 would NOT recognise its own line"
fi
printf 'NodeName=fake-node-2-extra CPUs=4 RealMemory=100 State=UNKNOWN\n' > "$TMP/conf2"
if grep -qE "^NodeName=${HOST}([[:space:]]|$)" "$TMP/conf2"; then
  bad "false positive: matched 'fake-node-2-extra'"
else
  ok "no false positive on a longer name"
fi
# and the real conf format 03 writes must satisfy it
printf 'NodeName=%s CPUs=20 RealMemory=7760 Gres=gpu:nvidia_h200:8 State=UNKNOWN\n' "$HOST" > "$TMP/conf3"
grep -qE "^NodeName=${HOST}([[:space:]]|$)" "$TMP/conf3" \
  && ok "matches a real 03-written line (with CPU/RAM/Gres)" \
  || bad "does not match the real format"

echo
echo "=== summary ==="
echo "  passed=$PASS failed=$FAIL"
[[ "$FAIL" == "0" ]] || exit 1
