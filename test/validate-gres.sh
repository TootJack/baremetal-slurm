#!/bin/bash
# Validate gpu_type_and_count + detect_node exactly as they appear in 03-slurm-controller.sh
set -uo pipefail

gpu_type_and_count() {   # echoes "<type> <count>"; empty if undetectable
  local name count
  command -v nvidia-smi >/dev/null 2>&1 || return 0
  count="$(nvidia-smi --list-gpus 2>/dev/null | wc -l | tr -d ' ')"
  [[ -z "$count" || "$count" == "0" ]] && return 0
  if [[ -n "${GPU_TYPE:-}" ]]; then
    echo "${GPU_TYPE} ${count}"; return 0
  fi
  name="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
  name="$(tr 'A-Z ' 'a-z_' <<<"$name" | tr -s '_' | sed 's/^_//;s/_$//')"
  echo "${name:-gpu} ${count}"
}

detect_node() {
  local host="$1" line cpus mem gres="" gtype="" gcount=""
  line="$(slurmd -C 2>/dev/null | grep -m1 '^NodeName=' || true)"
  if [[ -n "$line" ]]; then
    cpus="$(sed -E 's/.*CPUs=([0-9]+).*/\1/' <<<"$line")"
    mem="$(sed -E 's/.*RealMemory=([0-9]+).*/\1/' <<<"$line")"
  else
    cpus="$(nproc)"; mem="$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 ))"
  fi
  read -r gtype gcount <<<"$(gpu_type_and_count)"
  if [[ -n "$gtype" && -n "$gcount" ]]; then
    gres=" Gres=gpu:${gtype}:${gcount}"
  fi
  echo "NodeName=${host} CPUs=${cpus} RealMemory=${mem}${gres} State=UNKNOWN"
}

echo "--- raw nvidia-smi name (if any) ---"
nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "(none)"
echo "--- gpu_type_and_count ---"
echo "auto:     $(gpu_type_and_count)"
echo "override: $(GPU_TYPE=h200 gpu_type_and_count)"
echo "--- detect_node <hostname> ---"
H="$(hostname -s)"
LINE="$(detect_node "$H")"
echo "$LINE"
echo "$LINE" | grep -qE "^NodeName=${H} CPUs=[0-9]+ RealMemory=[0-9]+" \
  && echo "PASS: node line well-formed" || echo "FAIL: malformed"
echo "--- with GPU_TYPE=h200 override ---"
GPU_TYPE=h200 detect_node "$H" 2>/dev/null || GPU_TYPE=h200 bash -c "$(declare -f gpu_type_and_count detect_node); detect_node $H"
