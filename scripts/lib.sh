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

# --- cluster hostname resolution --------------------------------------
# Slurm resolves SlurmctldHost=<name> through /etc/hosts (there is no DNS for
# these names). The controller and every compute node MUST map each name to
# the SAME address, or RPCs fail:
#   sinfo: error: Unable to contact slurm controller (connect failure)
#   slurm_load_partitions: Socket timed out on send/recv operation
#
# Two traps, both hit on the real nodes:
#   1. Debian/Ubuntu ship `127.0.1.1 <hostname>`, so a node's OWN name resolves
#      to loopback. SlurmctldHost=<name> then binds loopback and no other node
#      can reach the controller.
#   2. A stale or partial block from an earlier run must be REPAIRED, not
#      trusted just because the marker is present.
#
# Defined here so 01-base.sh and the regression test exercise the same code
# instead of duplicating it.

# Default mapping for this cluster. Override via HOSTS_BLOCK.
cluster_hosts_block() {
  echo "${HOSTS_BLOCK:-10.100.18.5  hgx01
10.100.18.8  hgx20}"
}

# Print the current cluster block (without comment lines).
cluster_hosts_current() {
  sed -n '/# BEGIN i3d-slurm-cluster/,/# END i3d-slurm-cluster/p' /etc/hosts 2>/dev/null \
    | grep -v '^#'
}

# Install/repair the cluster block in /etc/hosts. Echoes "UPDATED" or "UNCHANGED".
# Does NOT touch anything outside its own marked block except the loopback
# shadow lines, which must go for the names it manages.
install_cluster_hosts() {
  local block="${1:-$(cluster_hosts_block)}" n changed="UNCHANGED"
  for n in $(awk '{print $2}' <<<"$block"); do
    if grep -qE "^[[:space:]]*127\.[0-9.]+[[:space:]]+.*\b${n}\b" /etc/hosts 2>/dev/null; then
      echo "    removing loopback entry for ${n} (it would shadow the LAN IP)" >&2
      sed -i -E "/^[[:space:]]*127\.[0-9.]+[[:space:]]+.*\b${n}\b/d" /etc/hosts
    fi
  done
  if [[ "$(cluster_hosts_current)" != "$block" ]]; then
    sed -i '/# BEGIN i3d-slurm-cluster/,/# END i3d-slurm-cluster/d' /etc/hosts
    { echo "# BEGIN i3d-slurm-cluster"
      echo "$block"
      echo "# END i3d-slurm-cluster"
    } >> /etc/hosts
    changed="UPDATED"
  fi
  echo "$changed"
}

# Assert every managed name resolves to its configured address on THIS node.
# Returns 0 when all match, 1 otherwise (printing the offending entries).
verify_cluster_hosts() {
  local block="${1:-$(cluster_hosts_block)}" ip name resolved rc=0
  while read -r ip name; do
    [[ -z "$ip" || -z "$name" ]] && continue
    resolved="$(getent ahostsv4 "$name" 2>/dev/null | awk '{print $1}' | head -1)"
    if [[ "$resolved" != "$ip" ]]; then
      echo "    !! ${name} resolves to '${resolved}', expected '${ip}'"
      rc=1
    fi
  done <<<"$block"
  return $rc
}
