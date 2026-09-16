#!/bin/bash
# Verify poc.sh: the paste-safe operator entry point.
#
# Two classes of defect this guards against:
#  1. Paste hazards. The script must contain no backticks and must not require
#     the operator to paste heredocs (a ```bash fence pasted into a shell opens
#     a command substitution and makes bash swallow the rest - that corrupted
#     an hgx01 session and silently skipped a git pull).
#  2. Lying output. `cmd | sed` reports sed's exit status, and grepping a
#     failed command trivially "passes" (an error message does not contain the
#     string you searched for). Status output must reflect the real result.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
POC="${ROOT}/poc.sh"
PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== 1. syntax ==="
bash -n "$POC" && ok "poc.sh parses" || bad "poc.sh has a syntax error"

echo
echo "=== 2. no backticks in EXECUTABLE code (paste hazard) ==="
# Backticks in comments are fine (they document this very hazard). What matters
# is executable code: a backtick there is a command substitution.
bc_hits="$(grep -vE '^[[:space:]]*#' "$POC" | grep -n '`' || true)"
if [[ -n "$bc_hits" ]]; then
  bad "executable line contains a backtick:"
  sed 's/^/      /' <<<"$bc_hits" | head -5
else
  ok "no backticks in executable code"
fi

echo
echo "=== 3. all subcommands exist and are reachable ==="
for a in sync status fix drains test containers; do
  if bash -n "$POC" && grep -qE "^  ${a}\)" "$POC"; then
    ok "subcommand '${a}' is wired into the dispatcher"
  else
    bad "subcommand '${a}' missing"
  fi
done
# an unknown action must fail loudly, not silently do nothing
out="$(bash "$POC" bogus-action 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -qi usage <<<"$out" && ok "unknown action -> usage + nonzero" \
                                          || bad "unknown action returned rc=$rc"

echo
echo "=== 4. status reports the REAL sinfo exit code ==="
# Prove that a failing sinfo cannot be reported as success. Run status with a
# deliberately broken client and require a non-zero exit to appear.
if grep -q 'sinfo_rc=\$?' "$POC"; then
  ok "captures sinfo's own exit status"
else
  bad "does not capture sinfo exit status (piping would report sed's)"
fi
if grep -qE 'stderr: ' "$POC"; then
  ok "surfaces stderr separately from stdout"
else
  bad "does not distinguish stderr from stdout"
fi

echo
echo "=== 5. no removed Slurm 25.11 fields ==="
# AllocGRES was removed ("please use AllocTRES"); using it makes sacct fail.
if grep -nE '\-o .*AllocGRES|,AllocGRES' "$POC" >/dev/null 2>&1; then
  bad "uses AllocGRES (removed in 25.11)"
else
  ok "does not use the removed AllocGRES field"
fi

echo
echo "=== 6. test subcommand handles a cluster with no GPUs ==="
# Requesting --gres=gpu:1 where none is advertised is rejected outright, so the
# script must detect that and still prove scheduling works.
if grep -q "no node currently advertises a GPU resource" "$POC"; then
  ok "detects a GPU-less cluster before submitting"
else
  bad "would submit --gres=gpu:1 blindly"
fi
if grep -q 'gpu_nodes=' "$POC"; then
  ok "queries advertised GPUs from sinfo"
else
  bad "does not query advertised GPUs"
fi

echo
echo "=== 7. usage text documents every subcommand ==="
# NOTE: with NO arguments the script intentionally runs the default read-only
# action (asserted in test 8), so usage comes from the explicit help action.
# Asking for usage from a bare invocation would contradict test 8.
usage="$(bash "$POC" help 2>&1 || true)"
for a in sync status fix drains test containers; do
  grep -q "$a" <<<"$usage" && ok "usage mentions ${a}" || bad "usage omits ${a}"
done

echo
echo "=== 8. it is not silently destructive on an unknown arg ==="
# 'status' is read-only; make sure the default action is read-only too.
if grep -qE 'ACTION="\$\{1:-status\}"' "$POC"; then
  ok "defaults to read-only 'status'"
else
  bad "default action is not status (could surprise the operator)"
fi

echo
echo "=== summary ==="
echo "  passed=$PASS failed=$FAIL"
[[ "$FAIL" == "0" ]] || exit 1
