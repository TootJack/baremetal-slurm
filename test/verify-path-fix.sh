#!/bin/bash
# Verify the PATH-shadowing fix: bare `sinfo`/`slurmd` must resolve to /opt/slurm
echo "=== 1. simulate the distro Slurm shadowing problem ==="
echo "where does a bare 'slurmd' currently resolve?"
command -v slurmd
echo "where does a bare 'sinfo' resolve?"
command -v sinfo
echo "which slurmctld version is that?"
slurmd -V 2>/dev/null | head -1 || echo "(none)"

echo
echo "=== 2. apply the fix: symlink /opt/slurm into /usr/local/bin ==="
PREFIX=/opt/slurm
mkdir -p /usr/local/bin
for b in "$PREFIX"/bin/* "$PREFIX"/sbin/*; do
  [ -x "$b" ] || continue
  ln -sf "$b" "/usr/local/bin/$(basename "$b")"
done
echo "linked: $(ls /usr/local/bin | wc -l) entries"

echo
echo "=== 3. resolve again (no PATH export, fresh shell semantics) ==="
echo "slurmd -> $(command -v slurmd)"
echo "sinfo  -> $(command -v sinfo)"
echo "version: $(slurmd -V 2>/dev/null | head -1)"

echo
echo "=== 4. does bare slurmd -C now report Gres? ==="
slurmd -C 2>/dev/null | grep -o 'Gres=[^ ]*' || echo "(no Gres - WSL has no usable NVML)"

echo
echo "=== 5. does bare sinfo reach the controller? ==="
sinfo -N -o "%N %T %G" 2>&1 | head -3
