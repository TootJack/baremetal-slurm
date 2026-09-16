#!/bin/bash
# How long does sacctmgr actually take to reach slurmdbd?
echo "=== timing sacctmgr (no artificial timeout) ==="
START=$(date +%s)
/opt/slurm/bin/sacctmgr -n show cluster
RC=$?
END=$(date +%s)
echo "exit=$RC  elapsed=$((END-START))s"
echo
echo "=== with 30s budget ==="
START=$(date +%s)
timeout 30 /opt/slurm/bin/sacctmgr -n show cluster; RC=$?
END=$(date +%s)
echo "exit=$RC (124=timed out)  elapsed=$((END-START))s"
echo
echo "=== is a cluster registered? ==="
timeout 30 /opt/slurm/bin/sacctmgr -n -P show cluster format=name 2>&1 | head -3
echo "exit=$?"
