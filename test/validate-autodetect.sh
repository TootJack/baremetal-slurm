#!/bin/bash
# Validate the rewritten 03/04 auto-detection logic in the WSL test cluster.
set -uo pipefail
cd /mnt/c/Users/20210859/Documents/i3d-slurm-poc || exit 1

echo "=== syntax checks ==="
for f in scripts/*.sh test/*.sh; do
  bash -n "$f" && echo "OK: $f" || echo "FAIL: $f"
done

echo
echo "=== test the detect_node logic standalone ==="
# replicate the function from 03 and confirm it produces a valid NodeName line
detect_node_test() {
  local host="$1" line cpus mem gres gcount=""
  line="$(slurmd -C 2>/dev/null | grep -m1 '^NodeName=' || true)"
  if [[ -n "$line" ]]; then
    cpus="$(sed -E 's/.*CPUs=([0-9]+).*/\1/' <<<"$line")"
    mem="$(sed -E 's/.*RealMemory=([0-9]+).*/\1/' <<<"$line")"
  else
    cpus="$(nproc)"; mem="$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 ))"
  fi
  if command -v nvidia-smi >/dev/null 2>&1; then
    gcount="$(nvidia-smi --list-gpus 2>/dev/null | wc -l | tr -d ' ')"
  fi
  [[ -n "$gcount" && "$gcount" != "0" ]] && gres=" Gres=gpu:h200:${gcount}"
  echo "NodeName=${host} CPUs=${cpus} RealMemory=${mem}${gres} State=UNKNOWN"
}

H="$(hostname -s)"
LINE="$(detect_node_test "$H")"
echo "detected: $LINE"
echo "$LINE" | grep -qE "^NodeName=${H} CPUs=[0-9]+ RealMemory=[0-9]+" \
  && echo "PASS: NodeName matches hostname and has numeric CPUs/RealMemory" \
  || echo "FAIL: malformed NodeName line"
