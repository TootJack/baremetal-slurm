#!/bin/bash
# Verify the two fixes for the hgx20 symptoms:
#  1. AccountingStorageHost must be the CONTROLLER, not 127.0.0.1 (a compute
#     node otherwise tries to reach slurmdbd on itself and hangs).
#  2. /shared must exist as a symlink to the real shared root, because #SBATCH
#     paths in the examples are literal and cannot compute it.
set -u
cd "$(dirname "$0")/.."
export PATH=/opt/slurm/bin:/opt/slurm/sbin:$PATH
PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== 1. no hardcoded loopback accounting host ==="
if grep -nE '^AccountingStorageHost=127\.0\.0\.1' scripts/03-slurm-controller.sh >/dev/null 2>&1; then
  bad "still hardcodes AccountingStorageHost=127.0.0.1"
  grep -nE '^AccountingStorageHost=' scripts/03-slurm-controller.sh | sed 's/^/      /'
else
  ok "AccountingStorageHost is templated"
fi
if grep -qE '^AccountingStorageHost=\$\{SLURMDBD_HOST\}' scripts/03-slurm-controller.sh; then
  ok "uses \${SLURMDBD_HOST}"
else
  bad "does not use \${SLURMDBD_HOST}"
fi
if grep -qE '^SLURMDBD_HOST="\$\{NODE1\}"' scripts/03-slurm-controller.sh; then
  ok "SLURMDBD_HOST defaults to the controller node"
else
  bad "SLURMDBD_HOST not defined as NODE1"
fi
# the generated conf must actually contain the controller name, not 127.0.0.1
conf_val="$(grep -m1 '^AccountingStorageHost=' /etc/slurm/slurm.conf 2>/dev/null | cut -d= -f2)"
echo "  live slurm.conf has: AccountingStorageHost=${conf_val:-<none>}"
if [[ "${conf_val:-}" == "127.0.0.1" ]]; then
  bad "live conf still points accounting at loopback"
elif [[ -n "${conf_val:-}" ]]; then
  ok "live conf points accounting at '${conf_val}'"
else
  echo "  (no live conf to check - skipped)"
fi

echo
echo "=== 2. /shared resolves to the shared root ==="
if [[ -L /shared ]]; then
  tgt="$(readlink -f /shared)"
  ok "/shared is a symlink -> ${tgt}"
  root="$(grep -m1 '^SHARED_ROOT=' /etc/slurm-poc-shared.conf 2>/dev/null | cut -d= -f2)"
  if [[ -n "$root" && "$tgt" == "$(readlink -f "$root")" ]]; then
    ok "target matches SHARED_ROOT (${root})"
  else
    bad "target ${tgt} != SHARED_ROOT ${root:-<none>}"
  fi
elif [[ -e /shared ]]; then
  echo "  /shared is a real directory (not a symlink) - acceptable if intended"
  ok "/shared exists"
else
  bad "/shared does not exist - example #SBATCH paths will fail"
fi

echo
echo "=== 3. the directories the examples reference exist ==="
for d in ckpt containers data; do
  if [[ -d "/shared/${d}" ]]; then
    ok "/shared/${d} exists"
  else
    bad "/shared/${d} missing (jobs writing there would fail at launch)"
  fi
done

echo
echo "=== 4. a job writing to /shared/ckpt actually runs ==="
cat > /tmp/sharedtest.sbatch <<'EOF'
#!/bin/bash
#SBATCH --job-name=sharedtest
#SBATCH --time=00:02:00
#SBATCH --output=/shared/ckpt/sharedtest-%j.out
echo "wrote via /shared symlink"
EOF
out="$(sbatch /tmp/sharedtest.sbatch 2>&1)"
jid="$(grep -oE '[0-9]+$' <<<"$out")"
echo "  ${out}"
st=""
for _ in $(seq 1 12); do
  st="$(sacct -j "$jid" -X -n -o State 2>/dev/null | head -1 | tr -d ' ')"
  case "$st" in COMPLETED*|FAILED*|CANCELLED*) break ;; esac
  sleep 3
done
echo "  state: ${st:-<none>}"
if [[ "$st" == COMPLETED* ]]; then
  ok "job with --output=/shared/ckpt/... completed"
  ls -l /shared/ckpt/sharedtest-*.out 2>/dev/null | tail -1 | sed 's/^/      /'
else
  bad "job state ${st:-none} - /shared paths still broken"
  scontrol show job "$jid" 2>/dev/null | grep -oE 'Reason=[^\[]*' | head -1 | sed 's/^/      /'
fi

echo
echo "=== summary ==="
echo "  passed=$PASS failed=$FAIL"
[[ "$FAIL" == "0" ]] || exit 1
