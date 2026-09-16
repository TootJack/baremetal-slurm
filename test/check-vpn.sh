#!/usr/bin/env bash
# Check connectivity AFTER FortiClient is connected.
# Verifies BOTH conditions we need:
#   1. the bare-metal node is reachable (FortiClient route)
#   2. this machine still has a working default route for model traffic (eduVPN)
#
# Usage: bash test/check-vpn.sh

echo "=== 1. FortiClient adapter ==="
netsh interface show interface 2>/dev/null | grep -iE "Ethernet 25|forti"

echo
echo "=== 2. Route to bare-metal node ==="
powershell -NoProfile -Command "Find-NetRoute -RemoteIPAddress 10.100.18.5 |
  Select-Object -First 1 IPAddress,InterfaceAlias | Format-List" 2>/dev/null

echo "=== 3. bare-metal SSH port ==="
if timeout 10 bash -c "echo > /dev/tcp/10.100.18.5/22" 2>/dev/null; then
  echo "  OK - 10.100.18.5:22 REACHABLE"
else
  echo "  FAIL - 10.100.18.5:22 not reachable (FortiClient not connected?)"
fi

echo
echo "=== 4. Default route (must stay on eduVPN for model access) ==="
route print -4 2>/dev/null | grep -E "^\s+0\.0\.0\.0"

echo
echo "=== 5. Is the agent's model traffic still flowing? ==="
if netstat -ano 2>/dev/null | grep -q ":443.*ESTABLISHED.*$(tasklist //FI "IMAGENAME eq omp.exe" //FO CSV //NH 2>/dev/null | head -1 | cut -d, -f2 | tr -d '"')"; then
  echo "  OK - agent has live :443 sessions"
else
  echo "  WARN - no live agent :443 sessions; if the model stops responding,"
  echo "         FortiClient took the default route. Fix with:"
  echo "           # give eduVPN the lower metric on 0.0.0.0/0"
  echo "           netsh interface ipv4 set route 0.0.0.0/0 \"tue.eduvpn.nl\" metric=1"
  echo "           # ensure FortiClient only owns its own subnet route"
fi
