#!/bin/bash
#SBATCH --job-name=preemptor
#SBATCH --output=/tmp/preemptor-%j.out
#SBATCH --qos=high
#SBATCH --exclusive
echo "high-qos job started at $(date +%T), forcing preemption of low-qos job"
sleep 8
echo "high-qos job done at $(date +%T)"
