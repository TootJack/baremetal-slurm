#!/bin/bash
echo "=============================================="
echo " FINAL VALIDATION SUMMARY (WSL test bed)"
echo "=============================================="
echo "1. daemons:  ctld=$(systemctl is-active slurmctld) slurmd=$(systemctl is-active slurmd) dbd=$(systemctl is-active slurmdbd) munge=$(systemctl is-active munge)"
echo "2. cluster:  $(sinfo -h)"
echo "3. ssh+sudo as mluser1:"
runuser -l mluser1 -c 'ssh -o BatchMode=yes localhost "echo OK" && sudo -n whoami' 2>/dev/null
echo "4. pyxis flags in srun: $(srun --help 2>/dev/null | grep -c container-image)"
echo "5. enroot version: $(enroot version 2>/dev/null)"
echo "6. sqsh image: $(du -h /shared/containers/ubuntu-test.sqsh 2>/dev/null | cut -f1)"
echo "7. QoS list: $(sacctmgr show qos -n -o name | paste -sd, -)"
echo "8. last jobs: "
sacct -X -o JobID,JobName%12,State%12,Elapsed | tail -6
