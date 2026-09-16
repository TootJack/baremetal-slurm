#!/bin/bash
# =====================================================================
# Example: quick sqsh container smoke test (run after 05-pyxis-enroot.sh)
# Submit: sbatch smoke-container.sbatch
# Expect: prints Ubuntu version from INSIDE the container + nvidia-smi
# =====================================================================
#SBATCH --job-name=smoke
#SBATCH --partition=debug
#SBATCH --nodes=1
#SBATCH --time=00:10:00
#SBATCH --output=/tmp/smoke-%j.out

#SBATCH --container-image=/shared/containers/ubuntu-test.sqsh

set -euo pipefail
echo "--- inside container:"
cat /etc/os-release | head -2
echo "--- GPUs visible in container:"
nvidia-smi --list-gpus 2>/dev/null | head -8 || echo "no GPUs (expected on non-GPU test)"
echo "--- SMOKE OK"
