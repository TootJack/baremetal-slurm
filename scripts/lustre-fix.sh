#!/usr/bin/env bash
# =====================================================================
# lustre-fix.sh - diagnose and fix write access on the i3D Lustre mount
#
# Context: both nodes have Lustre at /mnt/i3d_20tb (514T) and /scratch,
# but 'ubuntu' cannot write to the root of /mnt/i3d_20tb.
#
#   sudo bash scripts/lustre-fix.sh diag      # what are the permissions?
#   sudo bash scripts/lustre-fix.sh fix       # create the POC dirs
# =====================================================================
set -uo pipefail

LUSTRE="${LUSTRE:-/mnt/i3d_20tb}"
MODE="${1:-diag}"
hr() { printf '\n========== %s ==========\n' "$*"; }

hr "LUSTRE ROOT $(hostname -s)"
ls -ld "$LUSTRE"
echo "--- ownership/perms detail ---"
stat -c '%A %U:%G %n' "$LUSTRE" 2>/dev/null
echo "--- can we write as $(whoami)? ---"
touch "$LUSTRE/.wtest-$$" 2>/dev/null && echo "  YES" && rm -f "$LUSTRE/.wtest-$$" || echo "  NO"

hr "EXISTING DIRS"
ls -la "$LUSTRE" 2>/dev/null | head -20

hr "OTHER LUSTRE MOUNTS"
mount | grep -i lustre

hr "/scratch"
ls -ld /scratch 2>/dev/null && touch "/scratch/.wtest-$$" 2>/dev/null \
  && echo "  writable" && rm -f "/scratch/.wtest-$$" || echo "  not writable / absent"

if [ "$MODE" = "diag" ]; then
  hr "NEXT"
  echo "If the root is +default_permissions and owned by root, create the"
  echo "POC area as root:   sudo bash scripts/lustre-fix.sh fix"
  exit 0
fi

# ---------------------------------------------------------------
# FIX - create a writable POC area owned by the user group
# ---------------------------------------------------------------
hr "CREATING POC AREA under ${LUSTRE}"

# make the slurmusers group exist (02-users.sh creates it, but be safe)
getent group slurmusers >/dev/null || groupadd slurmusers

POC="${LUSTRE}/slurm-poc"
mkdir -p "$POC"/{containers,ckpt,data,scratch,cluster-config,home}
chown -R root:slurmusers "$POC"
# group-writable, setgid so new files inherit the group
chmod 2775 "$POC" "$POC"/{containers,ckpt,data,cluster-config,home}
# scratch stays world-writable + sticky
chmod 1777 "$POC/scratch"

echo "--- result ---"
ls -ld "$POC" "$POC"/* | sed 's/^/  /'

hr "VERIFY as ubuntu"
sudo -u ubuntu touch "$POC/ckpt/.wtest-ubuntu" 2>/dev/null \
  && echo "  ubuntu can write to $POC/ckpt  YES" \
  && rm -f "$POC/ckpt/.wtest-ubuntu" \
  || echo "  ubuntu CANNOT write (add ubuntu to the slurmusers group)"

hr "RECORD FOR OTHER SCRIPTS"
echo "SHARED_ROOT=${POC}" | tee /etc/slurm-poc-shared.conf
echo
echo "DONE. Re-run on the OTHER node to confirm it sees the same tree:"
echo "  ls -la ${POC}"
echo "  (files/ownership must look identical - that proves Lustre is shared)"
