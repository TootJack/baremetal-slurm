#!/bin/bash
# =====================================================================
# CPT training job TEMPLATE - 2 nodes x 8 H200, sqsh container, requeue.
#
# This is a STARTING POINT, not a runnable job: the container image and the
# training entrypoint are specific to your Megatron/NeMo setup. Replace the
# paths marked TODO-PATH before submitting, otherwise the job will be accepted
# and then exit immediately with no output.
#
#   What it needs to exist first (01-base.sh creates the directories):
#     /shared/containers/megatron-bridge.sqsh   <- your image
#     /shared/data/                             <- your dataset
#     /shared/ckpt/                             <- checkpoint dir
#   On this cluster /shared is a symlink to /mnt/i3d_20tb/slurm-poc (Lustre).
#   Verify with:  ls -l /shared/
#
#   Build the image once, on either node:
#     enroot import -o /shared/containers/megatron-bridge.sqsh \
#       docker://nvcr.io#nvidia/pytorch:24.07-py3
#
# Submit: sbatch examples/train-cpt.sbatch
# =====================================================================
#SBATCH --job-name=cpt-qwen27b
#SBATCH --partition=gpu
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=8
#SBATCH --gpus-per-task=1
#SBATCH --qos=low                # preemptible; use high for priority runs
#SBATCH --requeue                # resume from checkpoint on preemption/failure
#SBATCH --time=24:00:00
#SBATCH --output=/shared/ckpt/%x-%j.out

# --- Smoke test first -------------------------------------------------------
# Until the image and entrypoint exist, prove scheduling works with no
# container and no training code:
#     sbatch --wrap="hostname; nvidia-smi -L" --gres=gpu:1
# or: ./poc.sh test
# ---------------------------------------------------------------------------

# --- Container (the whole environment; no modules needed) ---
# TODO-PATH: point these at your image, dataset and checkpoint directory.
#SBATCH --container-image=/shared/containers/megatron-bridge.sqsh
#SBATCH --container-mounts=/shared/data:/data,/shared/ckpt:/ckpt
#SBATCH --container-workdir=/workspace

# --- Graceful checkpoint on preemption: Slurm sends SIGTERM at T-120s ---
#SBATCH --signal=B:SIGTERM@120

set -euo pipefail

echo "=== CPT job ${SLURM_JOB_ID} restart #${SLURM_RESTART_COUNT:-0} on ${SLURM_JOB_NODELIST} ==="
echo "GPUs per node: ${SLURM_GPUS_ON_NODE:-?}   nodes: ${SLURM_NNODES:-?}"

# Fail loudly with a clear message instead of a bare exit.
if [[ ! -f /workspace/train.py ]]; then
  echo "!! /workspace/train.py not found - this is a TEMPLATE." >&2
  echo "   Set the container image and entrypoint for your setup." >&2
  exit 1
fi

# Megatron/NeMo auto-resume from the latest checkpoint dir when it exists
python train.py \
  --config /workspace/configs/cpt_qwen27b.yaml \
  --ckpt-dir /ckpt/cpt-qwen27b \
  --auto-resume \
  --nodes "${SLURM_NNODES}" \
  --gpus-per-node "${SLURM_GPUS_ON_NODE}" \
  --master-addr "$(scontrol show hostnames "$SLURM_JOB_NODELIST" | head -1)" \
  --master-port 29500
