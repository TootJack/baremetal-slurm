#!/bin/bash
# Prove test/verify-hosts-resolution.sh is non-destructive:
# /etc/hosts must be byte-identical before and after.
set -u
SNAP="$(mktemp)"
cp /etc/hosts "$SNAP"
echo "before: $(wc -l < "$SNAP") lines  md5=$(md5sum "$SNAP" | cut -c1-12)"

bash "$(dirname "$0")/verify-hosts-resolution.sh" >/tmp/vh.out 2>&1
echo "test exit=$?"
tail -3 /tmp/vh.out | sed 's/^/  /'

echo "after:  $(wc -l < /etc/hosts) lines  md5=$(md5sum /etc/hosts | cut -c1-12)"
if cmp -s "$SNAP" /etc/hosts; then
  echo "RESULT: non-destructive (identical)"
else
  echo "RESULT: MODIFIED - test must not change the system"
  diff "$SNAP" /etc/hosts | head -20 | sed 's/^/  /'
fi
rm -f "$SNAP"
