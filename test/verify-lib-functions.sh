#!/bin/bash
# Confirm lib.sh's functions are all defined and callable after sourcing.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${HERE}/../scripts/lib.sh"

rc=0
for f in cluster_hosts_block cluster_hosts_current install_cluster_hosts verify_cluster_hosts show_cluster_hosts_sources flush_host_cache; do
  if declare -F "$f" >/dev/null 2>&1; then
    echo "  defined: $f"
  else
    echo "  MISSING: $f"; rc=1
  fi
done

echo
echo "=== callable test ==="
b="$(cluster_hosts_block)"
if [[ -n "$b" ]]; then
  echo "  cluster_hosts_block ->"
  echo "$b" | sed 's/^/    /'
else
  echo "  FAIL: cluster_hosts_block returned nothing"; rc=1
fi

echo "  nested: $(install_cluster_hosts "$(cluster_hosts_block)" 2>&1)"

echo
echo "  overall: $([[ $rc == 0 ]] && echo PASS || echo FAIL)"
exit $rc
