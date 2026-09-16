#!/usr/bin/env bash
# =====================================================================
# lib.sh - shared helpers. Source this from every script:
#     source "$(dirname "$0")/lib.sh"
#
# Handles the cross-cutting problems that bit us on the real nodes.
# =====================================================================

# --- needrestart ------------------------------------------------------
# On Ubuntu 22.04 `needrestart` runs AFTER apt operations, prints a
# "Scanning processes..." wall and can BLOCK waiting for input (which is
# why 05-pyxis-enroot.sh had to be Ctrl-C'd). Disable it for the whole
# session, both by config and by env var (belt and braces).
disable_needrestart() {
  export NEEDRESTART_MODE=a          # automatic; never prompt
  export NEEDRESTART_SUSPEND=1       # do not restart services mid-script
  if [[ -f /etc/needrestart/needrestart.conf ]]; then
    if ! grep -q '^\$nrconf{restart}' /etc/needrestart/needrestart.conf 2>/dev/null; then
      printf "\n\$nrconf{restart} = 'a';\n" >> /etc/needrestart/needrestart.conf 2>/dev/null || true
    else
      sed -i "s/^#\?\$nrconf{restart}.*/\$nrconf{restart} = 'a';/" \
        /etc/needrestart/needrestart.conf 2>/dev/null || true
    fi
  fi
  # also silence the "NEEDRESTART-*" noise harmless to us
  export DEBIAN_FRONTEND=noninteractive
}

# --- defensive user/group creation ------------------------------------
# A vendor Slurm replacement left `chown munge:` failing with
# "invalid spec" because the user did not exist. Create as needed.
ensure_user() {   # $1=user  [$2=home]
  local u="$1" h="${2:-/var/lib/$1}"
  getent group "$u" >/dev/null 2>&1 || groupadd -r "$u" 2>/dev/null || true
  if ! getent passwd "$u" >/dev/null 2>&1; then
    useradd -r -g "$u" -d "$h" -s /usr/sbin/nologin "$u" 2>/dev/null \
      || useradd -r -g "$u" -d "$h" -s /bin/false "$u" 2>/dev/null || true
  fi
  getent passwd "$u" >/dev/null 2>&1
}

# --- preflight checks -------------------------------------------------
require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "!! must run as root:  sudo bash $0"
    exit 1
  fi
}

# Fail loudly if PATH-based tools we depend on are missing.
require_cmd() {
  local missing=0
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { echo "!! missing command: $c"; missing=1; }
  done
  [[ "$missing" -eq 0 ]] || exit 1
}

# --- shared storage ---------------------------------------------------
# 01-base.sh records SHARED_ROOT; default to Lustre when mounted.
resolve_shared_root() {
  if [[ -f /etc/slurm-poc-shared.conf ]]; then
    # shellcheck disable=SC1091
    source /etc/slurm-poc-shared.conf
  fi
  if [[ -z "${SHARED_ROOT:-}" ]]; then
    if mountpoint -q /mnt/i3d_20tb 2>/dev/null; then
      SHARED_ROOT=/mnt/i3d_20tb/slurm-poc
    else
      SHARED_ROOT=/shared
    fi
  fi
  echo "$SHARED_ROOT"
}
