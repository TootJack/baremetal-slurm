#!/bin/bash
# Verify the sourced Slurm build has NVML support in the right places.
cd /usr/local/src/slurm-25.11.8 || exit 1

echo "=== config.h ==="
grep -E '^#define HAVE_NVML' config.h || echo "HAVE_NVML NOT defined"

echo
echo "=== gres/gpu plugin (this is what AutoDetect=nvml uses) ==="
find src/plugins/gres/gpu -name '*.so' -o -name 'lib*' | head -5
ls -la src/plugins/gres/gpu/.libs/*.so 2>/dev/null | head -3

echo
echo "=== does the gpu gres plugin link against nvidia-ml? ==="
P=$(find src/plugins/gres/gpu -name 'gres_gpu.so' | head -1)
echo "plugin: $P"
[ -n "$P" ] && ldd "$P" 2>/dev/null | grep -iE "nvidia|nvml" || echo "(no direct link - it dlopen()s NVML at runtime)"

echo
echo "=== strings check on the plugin ==="
[ -n "$P" ] && strings "$P" 2>/dev/null | grep -ciE 'nvml' || echo 0

echo
echo "=== binaries built ==="
for b in src/slurmctld/slurmctld src/slurmd/slurmd src/slurmdbd/slurmdbd; do
  if [ -x "$b" ]; then echo "  ok  $b"; else echo "  MISSING $b"; fi
done

echo
echo "=== slurmctld version ==="
src/slurmctld/slurmctld -V 2>&1 | head -1
