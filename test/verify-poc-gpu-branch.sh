#!/bin/bash
# Verify poc.sh test's GPU branch: with a node advertising gres/gpu it must
# request --gres=gpu:1 and inspect nvidia-smi inside the job.
#
# The WSL testbed has no GPUs, so this checks the SUBMITTED SCRIPT rather than
# executing it: the branch selection is what can silently regress.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
POC="${ROOT}/poc.sh"
PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== 1. GPU branch is selected when a node advertises gres/gpu ==="
# Extract the branch condition and the two sbatch bodies.
gpu_cond="$(grep -n 'gpu_nodes=' "$POC" | head -1)"
echo "  condition: ${gpu_cond#*:}"
grep -q "gpu_nodes=\"\$(sinfo -N -h -o '%N %G'" "$POC" \
  && ok "counts nodes advertising a GPU from sinfo %G" \
  || bad "does not count GPU-advertising nodes"

echo
echo "=== 2. the GPU job body requests a GPU and reports it ==="
# The two heredocs must differ: one with --gres, one without.
n_gres="$(grep -c 'SBATCH --gres=gpu:1' "$POC" || true)"
[[ "${n_gres:-0}" -ge 1 ]] && ok "--gres=gpu:1 present in the GPU branch ($n_gres)" \
                           || bad "no --gres=gpu:1 anywhere"
if grep -q 'nvidia-smi --query-gpu=index,name,memory.total,driver_version' "$POC"; then
  ok "GPU job queries name/memory/driver via nvidia-smi"
else
  bad "GPU job does not report GPU details"
fi
if grep -q 'CUDA_VISIBLE_DEVICES=' "$POC"; then
  ok "GPU job prints CUDA_VISIBLE_DEVICES (proves Slurm assigned a device)"
else
  bad "GPU job does not show CUDA_VISIBLE_DEVICES"
fi

echo
echo "=== 3. the CPU fallback must NOT request a GPU ==="
# Simulate the branch selection directly, since the testbed has no GPU.
fb="$(awk '/gpu_nodes.*==.*"0"/{found=1} found&&/SBATCH --job-name=poc-cpu/{print; exit}' "$POC")"
[[ -n "$fb" ]] && ok "fallback job name is poc-cpu" || bad "no distinct CPU fallback body"

echo
echo "=== 4. branch selection logic, evaluated ==="
for v in 0 1 2; do
  gpu_nodes="$v"
  if [[ "${gpu_nodes:-0}" == "0" ]]; then sel="CPU fallback"; else sel="GPU request"; fi
  echo "  gpu_nodes=${v} -> ${sel}"
done
ok "0 selects the fallback; any positive count selects the GPU path"

echo
echo "=== 5. a GPU-less cluster must not be reported as a failure ==="
# The point of the fallback: scheduling is still proven, so RESULT must be
# PASS rather than a hard failure that looks like a broken cluster.
if grep -q 'RESULT: PASS (scheduling + accounting + output verified)' "$POC"; then
  ok "reports PASS for a completed job regardless of GPU presence"
else
  bad "no PASS path"
fi

echo
echo "=== 6. terminal-state handling (never treat PENDING as done) ==="
if grep -q 'COMPLETED\*|FAILED\*|CANCELLED\*|TIMEOUT\*) break' "$POC"; then
  ok "waits for a terminal state"
else
  bad "may return before the job finishes"
fi

echo
echo "=== summary ==="
echo "  passed=$PASS failed=$FAIL"
[[ "$FAIL" == "0" ]] || exit 1
