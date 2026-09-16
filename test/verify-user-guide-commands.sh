#!/bin/bash
# Verify the commands documented in USER-GUIDE.md are accepted by this Slurm.
# WSL has no GPU, so GPU *requests* cannot be satisfied - but option PARSING
# still fails loudly on an unknown/invalid option, which is what this checks.
# A documented command that the client rejects would be a broken guide.
set -u
export PATH=/opt/slurm/bin:/opt/slurm/sbin:$PATH
cd /tmp
PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# Does sbatch accept these options/formats? (dry-run: only parsing matters)
check_opt() {
  local desc="$1"; shift
  local out
  out="$(sbatch --test-only "$@" --wrap=true 2>&1)"
  if grep -qiE 'unrecognized|invalid option|error:.*option' <<<"$out"; then
    bad "${desc}  ->  ${out}"
  else
    ok "${desc}"
  fi
}

echo "=== sbatch options used in the guide ==="
check_opt "--gpus-per-node=8"            --gpus-per-node=8
check_opt "--ntasks-per-node=8"          --ntasks-per-node=8
check_opt "--cpus-per-task=24"           --cpus-per-task=24
check_opt "--gres=gpu:1"                 --gres=gpu:1
check_opt "--exclusive"                  --exclusive
check_opt "--mem=0"                      --mem=0
check_opt "--requeue"                    --requeue
check_opt "--qos=high"                   --qos=high
check_opt "--qos=low"                    --qos=low
check_opt "--qos=normal"                 --qos=normal
check_opt "--partition=gpu"              --partition=gpu
check_opt "--partition=debug"            --partition=debug
check_opt "--nodes=2"                    --nodes=2
check_opt "--job-name=mytrain"           --job-name=mytrain
check_opt "--signal=B:SIGTERM@120"       --signal=B:SIGTERM@120
check_opt "--dependency=afterok:1"       --dependency=afterok:1
check_opt "--output=/tmp/%x-%j.out"      --output=/tmp/%x-%j.out
check_opt "--error=/tmp/%x-%j.err"       --error=/tmp/%x-%j.err
check_opt "--chdir=/tmp"                 --chdir=/tmp

echo
echo "=== sbatch -o format fields (squeue/sacct documented) ==="
if squeue -o "%.10i %.9P %.20j %.8u %.2t %.10M %.6D %R" >/dev/null 2>&1; then
  ok "squeue format string valid"
else
  bad "squeue format string rejected"
fi
if sacct -o JobID,State,Elapsed,AllocTRES >/dev/null 2>&1; then
  ok "sacct JobID,State,Elapsed,AllocTRES valid"
else
  bad "sacct fields rejected"
fi
if sacct -o JobID,AllocGRES >/dev/null 2>&1; then
  echo "  (note: AllocGRES still accepted here)"
else
  ok "AllocGRES correctly documented as removed"
fi

echo
echo "=== sinfo formats documented ==="
for f in "%N %T %G" "%N %G"; do
  if sinfo -N -o "$f" >/dev/null 2>&1; then ok "sinfo -o '$f'"; else bad "sinfo -o '$f'"; fi
done

echo
echo "=== scontrol / srun commands documented ==="
if scontrol show hostnames "${HOSTNAME:-localhost}" >/dev/null 2>&1; then
  ok "scontrol show hostnames"
else
  bad "scontrol show hostnames"
fi
if srun --help 2>&1 | grep -q -- '--pty'; then ok "srun --pty exists"; else bad "srun --pty"; fi
if srun --help 2>&1 | grep -q -- '--gres'; then ok "srun --gres exists"; else bad "srun --gres"; fi

echo
echo "=== Pyxis container options referenced in the guide ==="
# Only meaningful if pyxis is installed; report either way.
if srun --help 2>&1 | grep -q -- '--container-image'; then
  for o in --container-image --container-mounts --container-workdir --container-remap-root; do
    if srun --help 2>&1 | grep -q -- "$o"; then ok "pyxis ${o}"; else bad "pyxis ${o} missing"; fi
  done
else
  echo "  (pyxis not installed here - cannot verify; guide claims it is on the cluster)"
fi

echo
echo "=== the documented tiny-job submission is accepted ==="
out="$(sbatch --test-only --wrap="hostname" --gres=gpu:1 2>&1)"
echo "  sbatch --wrap='hostname' --gres=gpu:1  ->  ${out}"
# 'test-only' should complain about the missing GPU resource, not the syntax
grep -qiE 'unrecognized|invalid option' <<<"$out" && bad "--wrap + --gres syntax rejected" \
                                               || ok "--wrap + --gres syntax accepted"

echo
echo "=== summary ==="
echo "  passed=$PASS failed=$FAIL"
[[ "$FAIL" == "0" ]] || exit 1
