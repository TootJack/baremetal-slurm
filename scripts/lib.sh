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
#
# The names in the block become AUTHORITATIVE. nsswitch is normally
# `hosts: files dns`, and within `files` the FIRST matching line wins. So a
# stale, duplicate, or unmarked mapping anywhere else in the file silently
# beats the block we write - and a wrong one (an old IP, or the 127.0.1.1
# shadow) still resolves "successfully", just to the wrong address. Every
# non-block line that maps a managed name is therefore removed.
install_cluster_hosts() {
  local block="${1:-$(cluster_hosts_block)}" n changed="UNCHANGED"
  local names tmp
  names="$(awk '{print $2}' <<<"$block" | tr '\n' ' ')"
  tmp="$(mktemp)"

  # Any line OUTSIDE our marked block that claims one of these names loses that
  # name. Only the managed NAME is dropped - unrelated aliases on the same line
  # are preserved. A line left with nothing but its address is removed.
  awk -v names="$names" '
    /# BEGIN i3d-slurm-cluster/ { inblk = 1 }
    inblk { print; if (/# END i3d-slurm-cluster/) inblk = 0; next }
    /^[[:space:]]*#/ { print; next }
    NF == 0 { print; next }
    {
      n = split(names, want, " ")
      m = NF
      out = $1
      kept = 0
      linehit = 0
      for (i = 2; i <= m; i++) {
        managed = 0
        for (j = 1; j <= n; j++) if ($i == want[j]) managed = 1
        if (managed) { linehit = 1; removed++; continue }
        out = out " " $i
        kept++
      }
      if (kept == 0 && linehit) next   # address now has no names left
      print out
    }
    END { if (removed) exit 7 }
  ' /etc/hosts > "$tmp"
  local rc=$?
  if [[ "$rc" == "7" ]]; then
    # Report only names that appear OUTSIDE the managed block - those are the
    # ones that were shadowing it. Grepping the whole file would also match the
    # block's own (correct) entries and report them as removed.
    local outside
    outside="$(sed '/# BEGIN i3d-slurm-cluster/,/# END i3d-slurm-cluster/d' /etc/hosts)"
    for n in $names; do
      if grep -qE "(^|[[:space:]])${n}([[:space:]]|$)" <<<"$outside" 2>/dev/null; then
        echo "    removing stray/duplicate mapping(s) for ${n}" \
             "(they shadow the managed block)" >&2
      fi
    done
    # preserve inode/permissions; /etc/hosts may be bind-mounted
    cat "$tmp" > /etc/hosts
    changed="UPDATED"
  fi
  rm -f "$tmp"

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

# Diagnostic: show EVERY /etc/hosts line that mentions the managed names, plus
# what each name actually resolves to. Use when verify_cluster_hosts fails -
# resolution is `files` first (first match wins), so a stray or duplicated
# line elsewhere in the file silently overrides the managed block.
show_cluster_hosts_sources() {
  local block="${1:-$(cluster_hosts_block)}" ip name resolved
  echo "  --- /etc/hosts lines mentioning managed names ---"
  while read -r ip name; do
    [[ -z "$ip" || -z "$name" ]] && continue
    local hits
    hits="$(grep -nE "(^|[[:space:]])${name}([[:space:]]|$)" /etc/hosts 2>/dev/null)"
    if [[ -n "$hits" ]]; then
      echo "$hits" | sed "s/^/    /"
    else
      echo "    (no /etc/hosts entry for ${name})"
    fi
    resolved="$(getent ahostsv4 "$name" 2>/dev/null | awk '{print $1}' | head -1)"
    echo "    => ${name} resolves to ${resolved:-<nothing>}"
  done <<<"$block"
  echo "  --- nsswitch hosts order ---"
  grep '^hosts:' /etc/nsswitch.conf 2>/dev/null | sed 's/^/    /'
}
