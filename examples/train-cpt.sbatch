#!/bin/bash
# =====================================================================
# Example: CPT training job with sqsh container + checkpoint/requeue
# Submit: sbatch train-cpt.sbatch
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

# --- Container (the whole environment; no modules needed) ---
#SBATCH --container-image=/shared/containers/megatron-bridge.sqsh
#SBATCH --container-mounts=/shared/data:/data,/shared/ckpt:/ckpt,/shared/home/%u:/home/%u
#SBATCH --container-workdir=/workspace

# --- Graceful checkpoint on preemption: Slurm sends SIGTERM at T-120s ---
#SBATCH --signal=B:SIGTERM@120

set -euo pipefail
echo "=== CPT job ${SLURM_JOB_ID} restart #${SLURM_RESTART_COUNT:-0} on ${SLURM_JOB_NODELIST} ==="

# Megatron/Nemo auto-resume from the latest checkpoint dir when it exists
python train.py \
  --config /workspace/configs/cpt_qwen27b.yaml \
  --ckpt-dir /ckpt/cpt-qwen27b \
  --auto-resume \
  --nodes ${SLURM_NNODES} \
  --gpus-per-node ${SLURM_GPUS_ON_NODE} \
  --master-addr $(hostname) \
  --master-port 29500
