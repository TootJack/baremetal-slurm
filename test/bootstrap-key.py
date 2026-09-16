#!/usr/bin/env python3
"""
One-time bootstrap: push the ed25519 public key to the bare-metal node and
switch SSH to key-only auth.

Run this ONCE, while the password is still available:
    python bootstrap-key.py

After it succeeds every later connection (and this agent) uses the key only.

Requires: pip install paramiko
"""
import getpass
import os
import sys

import paramiko

HOST = os.environ.get("BM_HOST", "10.100.18.5")
USER = os.environ.get("BM_USER", "ubuntu")
KEY_PATH = os.path.expanduser("~/.ssh/id_ed25519.pub")
KEY_NAME = "id_ed25519"


def main() -> int:
    if not os.path.exists(KEY_PATH):
        print(f"!! public key not found: {KEY_PATH}")
        print("   generate one with: ssh-keygen -t ed25519")
        return 1

    with open(KEY_PATH) as fh:
        pubkey = fh.read().strip()
    print(f"==> using public key: {KEY_PATH}")
    print(f"    fingerprint line: {pubkey[:60]}...")

    # Password comes from BM_PASSWORD when run non-interactively (agent/CI),
    # otherwise prompt. Never written to disk.
    password = os.environ.get("BM_PASSWORD") or getpass.getpass(
        f"Password for {USER}@{HOST} : "
    )

    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    print(f"==> connecting to {HOST} as {USER} ...")
    try:
        client.connect(
            HOST, username=USER, password=password,
            look_for_keys=False, allow_agent=False, timeout=20,
        )
    except paramiko.AuthenticationException:
        print("!! authentication failed - wrong password?")
        return 2
    except Exception as exc:  # noqa: BLE001
        print(f"!! connection failed: {exc}")
        print("   Is FortiClient VPN connected? (Ethernet 25 should be Connected)")
        return 3

    # Build an idempotent remote script: install key, then harden sshd.
    remote = f"""
set -e
mkdir -p ~/.ssh && chmod 700 ~/.ssh
if ! grep -qF '{pubkey}' ~/.ssh/authorized_keys 2>/dev/null; then
  echo '{pubkey}' >> ~/.ssh/authorized_keys
  echo "  key added"
else
  echo "  key already present"
fi
chmod 600 ~/.ssh/authorized_keys

# passwordless sudo for this user (SOW requirement)
echo '{USER} ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/{USER}-poc >/dev/null
sudo chmod 440 /etc/sudoers.d/{USER}-poc
sudo visudo -cf /etc/sudoers.d/{USER}-poc >/dev/null && echo "  sudo OK"

# sshd: keep pubkey auth, disable password auth AFTER we know the key works
sudo mkdir -p /etc/ssh/sshd_config.d
printf '%s\\n' \\
  'PubkeyAuthentication yes' \\
  'PasswordAuthentication no' \\
  'PermitRootLogin prohibit-password' \\
  | sudo tee /etc/ssh/sshd_config.d/99-poc.conf >/dev/null
sudo sshd -t && echo "  sshd config valid"
echo '--- fingerprint of installed key:'
ssh-keygen -lf ~/.ssh/authorized_keys
"""
    stdin, stdout, stderr = client.exec_command(remote, timeout=60)
    out = stdout.read().decode()
    err = stderr.read().decode()
    code = stdout.channel.recv_exit_status()
    print(out)
    if err.strip():
        print("STDERR:", err)
    client.close()

    if code != 0:
        print("!! remote setup reported an error")
        return 4

    print("==> OK. Now reload sshd (kept as a separate step so we do not")
    print("    lock ourselves out mid-session):")
    print(f"    ssh {USER}@{HOST} 'sudo systemctl reload ssh'")
    return 0


if __name__ == "__main__":
    sys.exit(main())
