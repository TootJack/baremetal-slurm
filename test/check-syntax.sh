#!/bin/bash
cd /mnt/c/Users/20210859/Documents/i3d-slurm-poc || exit 1
for f in scripts/*.sh test/*.sh examples/*.sbatch; do
  bash -n "$f" && echo "OK: $f"
done
