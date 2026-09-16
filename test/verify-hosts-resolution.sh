#!/bin/bash
# Regression test for the cluster-hostname logic in scripts/lib.sh.
#
# Covers the root cause of the multi-node failure:
#   hgx20$ sinfo
#   sinfo: error: Unable to contact slurm controller (connect failure)
#   slurm_load_partitions: Socket timed out on send/recv operation
#
# Traps fixed in install_cluster_hosts():
#   1. Debian/Ubuntu's `127.0.1.1 <hostname>` line makes a node's own name
#      resolve to LOOPBACK; SlurmctldHost=<name> then binds loopback.
#   2. A stale/partial cluster block must be repaired, not trusted.
#   3. A stray/duplicate mapping elsewhere in /etc/hosts wins, because
#      nsswitch is `files dns` and the FIRST match in `files` wins. Such a
#      line resolves "successfully" to the WRONG address.
#
# Test names are under the reserved .invalid TLD (DNS never resolves those, so
# /etc/hosts is provably the only source) and are UNIQUE per run. An earlier
# version reused fixed names and a fixed real hostname: a caching nss module
# could then serve an answer cached before the edit, which made the test report
# a shadow as "not removed" while /etc/hosts was in fact correct. It passed on
# hgx20 and failed on hgx01 with identical code. IPs below are DOCUMENTATION
# ranges (192.0.2.0/24), never real addresses, so even if a stale cache served
# one it could not point at a live host.
#
# The test is NON-DESTRUCTIVE: /etc/hosts is snapshotted and restored exactly
# on exit. Installing the real mapping is 01-base.sh's job, not the test's.
#
# Run as root on the target nodes.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${HERE}/../scripts/lib.sh"

PASS=0
FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

HOSTS_SNAPSHOT="$(mktemp)"
cat /etc/hosts > "$HOSTS_SNAPSHOT"

restore() {
  cat "$HOSTS_SNAPSHOT" > /etc/hosts
  rm -f "$HOSTS_SNAPSHOT"
}
trap restore EXIT

MYNAME="$(hostname -s)"
MYIP="$(ip -4 route get 1.1.1.1 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)"
[[ -z "$MYIP" ]] && MYIP="$(hostname -I | awk '{print $1}')"
REAL_BLOCK="${MYIP}  ${MYNAME}"

# Resolver answers can be stale: a caching nss module (nscd, systemd-resolved
# with `resolve` in nsswitch, sssd) may serve an answer cached BEFORE we edited
# /etc/hosts. Flush before every resolver-based assertion.
flush_host_cache() {
  if command -v nscd >/dev/null 2>&1 && systemctl is-active --quiet nscd 2>/dev/null; then
    nscd -i hosts >/dev/null 2>&1 || true
  fi
  if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    resolvectl flush-caches >/dev/null 2>&1 || true
  fi
  sleep 1
}

# What does /etc/hosts ITSELF say? (empty = absent). Read directly, so the
# answer cannot be influenced by any resolver cache.
hosts_lookup() {
  sed -E 's/#.*//' /etc/hosts 2>/dev/null \
    | awk -v n="$1" '{ for (i=2;i<=NF;i++) if ($i==n) { print $1; exit } }'
}

# Count lines OUTSIDE the managed block that claim a name.
stray_count() {
  local outside
  outside="$(sed '/# BEGIN i3d-slurm-cluster/,/# END i3d-slurm-cluster/d' /etc/hosts)"
  grep -cE "(^|[[:space:]])$1([[:space:]]|$)" <<<"$outside" 2>/dev/null || true
}

resolve_name() {
  flush_host_cache
  getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | head -1
}

# Unique per run: no cached answer from a previous run can apply.
RUN="$(date +%s)-$$"
SYN_A="poc-shadow-a-${RUN}.invalid"
SYN_B="poc-shadow-b-${RUN}.invalid"
IP_A="192.0.2.11"
IP_B="192.0.2.12"
IP_STALE="192.0.2.99"
SYN_BLOCK="${IP_A}  ${SYN_A}
${IP_B}  ${SYN_B}"

echo "host=${MYNAME} lan_ip=${MYIP}"
echo "test names: ${SYN_A} , ${SYN_B}"

echo
echo "=== 1. missing block -> must UPDATE ==="
sed -i '/# BEGIN i3d-slurm-cluster/,/# END i3d-slurm-cluster/d' /etc/hosts
r="$(install_cluster_hosts "$REAL_BLOCK")"
[[ "$r" == "UPDATED" ]] && ok "created the cluster block" || bad "expected UPDATED, got $r"

echo
echo "=== 2. correct block -> must be left alone ==="
r="$(install_cluster_hosts "$REAL_BLOCK")"
[[ "$r" == "UNCHANGED" ]] && ok "idempotent re-run" || bad "expected UNCHANGED, got $r"

echo
echo "=== 3. stale block -> must be repaired ==="
sed -i '/# BEGIN i3d-slurm-cluster/,/# END i3d-slurm-cluster/d' /etc/hosts
{ echo "# BEGIN i3d-slurm-cluster"; echo "192.0.2.250  ${MYNAME}"; echo "# END i3d-slurm-cluster"; } >> /etc/hosts
r="$(install_cluster_hosts "$REAL_BLOCK")"
[[ "$r" == "UPDATED" ]] && ok "repaired the stale block" || bad "expected UPDATED, got $r"

echo
echo "=== 4. loopback shadow -> removed, asserted on /etc/hosts ==="
sed -i "/${SYN_A}/d" /etc/hosts
sed -i '/# BEGIN i3d-slurm-cluster/,/# END i3d-slurm-cluster/d' /etc/hosts
printf '127.0.1.1  %s\n' "$SYN_A" >> /etc/hosts
before="$(hosts_lookup "$SYN_A")"
echo "  /etc/hosts before: ${before:-<none>}"
[[ "$before" == "127.0.1.1" ]] && ok "planted the loopback shadow" \
                               || bad "could not plant shadow (got ${before:-none})"

install_cluster_hosts "$SYN_BLOCK" >/dev/null
after="$(hosts_lookup "$SYN_A")"
stray="$(stray_count "$SYN_A")"
echo "  /etc/hosts after:  ${after:-<none>}   stray lines outside block: ${stray}"
[[ "$after" == "$IP_A" ]] && ok "file now maps ${SYN_A} -> ${IP_A}" \
                          || bad "expected ${IP_A}, got ${after:-none}"
[[ "$stray" == "0" ]] && ok "no stray ${SYN_A} line remains" \
                      || bad "expected 0 stray lines, found ${stray}"

echo
echo "=== 4b. resolver agrees (cache flushed) ==="
got="$(resolve_name "$SYN_A")"
echo "  ${SYN_A} -> ${got:-<none>}"
if [[ "$got" == "$IP_A" ]]; then
  ok "resolver returns the managed address"
else
  bad "resolver returned ${got:-none}, expected ${IP_A}"
  if [[ "$(stray_count "$SYN_A")" == "0" && "$(hosts_lookup "$SYN_A")" == "$IP_A" ]]; then
    echo "    NOTE: /etc/hosts is correct; a resolver cache or nss module is"
    echo "          serving a stale answer. Not an /etc/hosts defect."
    echo "    nsswitch: $(grep '^hosts:' /etc/nsswitch.conf)"
    for s in nscd systemd-resolved sssd; do
      echo "    ${s}: active=$(systemctl is-active "$s" 2>/dev/null || echo n/a)"
    done
  fi
fi

echo
echo "=== 5. stray duplicate outside the block -> must lose to the block ==="
# The hgx20 case: an early unmarked line wins because the first match in
# `files` is authoritative.
sed -i "/${SYN_B}/d" /etc/hosts
sed -i '/# BEGIN i3d-slurm-cluster/,/# END i3d-slurm-cluster/d' /etc/hosts
printf '127.0.1.1  %s\n%s  %s\n' "$SYN_B" "$IP_STALE" "$SYN_B" >> /etc/hosts
install_cluster_hosts "$SYN_BLOCK" >/dev/null
got="$(hosts_lookup "$SYN_B")"
stray="$(stray_count "$SYN_B")"
echo "  stale lines were 127.0.1.1 and ${IP_STALE}; file now: ${got:-<none>}, stray=${stray}"
[[ "$got" == "$IP_B" && "$stray" == "0" ]] && ok "stale unmarked mappings were overridden" \
                                           || bad "expected ${IP_B}/0 stray, got ${got:-none}/${stray}"

echo
echo "=== 6. verify_cluster_hosts() accepts a correct mapping ==="
if verify_cluster_hosts "$SYN_BLOCK"; then
  ok "verifier accepted the correct mapping"
else
  bad "verifier rejected the correct mapping"
fi

echo
echo "=== 7. verify_cluster_hosts() rejects a wrong mapping ==="
# Plant a shadow AFTER install, so a genuinely-shadowed state is verified.
sed -i "/${SYN_A}/d" /etc/hosts
printf '127.0.1.1  %s\n' "$SYN_A" >> /etc/hosts
flush_host_cache
if verify_cluster_hosts "$SYN_BLOCK" >/dev/null 2>&1; then
  bad "verifier accepted a loopback shadow (it must reject)"
else
  ok "verifier rejected the loopback shadow"
fi

echo
echo "=== 8. reality check: own name resolves to the LAN IP ==="
sed -i "/${SYN_A}/d;/${SYN_B}/d" /etc/hosts
sed -i '/# BEGIN i3d-slurm-cluster/,/# END i3d-slurm-cluster/d' /etc/hosts
install_cluster_hosts "$REAL_BLOCK" >/dev/null
got="$(resolve_name "$MYNAME")"
file="$(hosts_lookup "$MYNAME")"
echo "  ${MYNAME}: /etc/hosts=${file:-<none>} resolver=${got:-<none>}"
if [[ "$got" == "$MYIP" ]]; then
  ok "own name resolves to the LAN address"
else
  bad "expected ${MYIP}, got ${got:-none}"
  show_cluster_hosts_sources "$REAL_BLOCK"
fi

echo
echo "=== summary ==="
echo "  passed=$PASS failed=$FAIL"
[[ "$FAIL" == "0" ]] || exit 1
