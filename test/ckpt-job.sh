#!/bin/bash
#SBATCH --job-name=ckpt
#SBATCH --output=/tmp/ckpt-%j.out
#SBATCH --requeue
#SBATCH --qos=low
#SBATCH --exclusive
for i in $(seq 1 60); do
  echo "step $i $(date +%T)"
  sleep 1
done
