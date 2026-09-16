#!/bin/bash
# Why did VENDOR_OPTS capture as empty while the regex matched?
f=/etc/default/munge
cat > "$f" <<'EOF'
# MUNGE configuration
OPTIONS="--key-file=/cm/shared/apps/slurm/var/munge/keys/munge.key"
EOF

echo "=== A. grep -E with the script's pattern ==="
grep -E '^\s*OPTIONS=' "$f" | head -1
echo "captured=[$(grep -E '^\s*OPTIONS=' "$f" | head -1)]"

echo
echo "=== B. inside command substitution ==="
V="$(grep -E '^\s*OPTIONS=' "$f" | head -1)"
echo "V=[$V]  len=${#V}"

echo
echo "=== C. is it the 'q' variant that behaves differently? ==="
if grep -qE '^\s*OPTIONS=' "$f"; then echo "q-version MATCHED"; else echo "q-version NO MATCH"; fi

echo
echo "=== D. what does the script ACTUALLY execute? show the block ==="
sed -n '/vendor munge OPTIONS found/,+4p' /mnt/c/Users/20210859/Documents/i3d-slurm-poc/scripts/03-slurm-controller.sh
