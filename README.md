# i3D.net H200 Slurm POC — Deployment Scripts

Bare-metal Slurm cluster for the 2-week MLOps POC on 2 × 8×H200 (i3D.net).
Jobs run as **sqsh containers** (Pyxis + Enroot) — no environment modules.

## Stack

| Layer | Choice |
|---|---|
| OS | Ubuntu 22.04/24.04 LTS |
| Scheduler | Slurm 23.11 (slurmctld on node1, slurmd on both) |
| Accounting | slurmdbd + MariaDB (required for QoS) |
| Containers | Pyxis (SPANK) + Enroot → `.sqsh` images |
| Access | SSH **ed25519 keys only**, password auth disabled |
| Users | 3 ML users, **passwordless sudo** |
| Remote access | FortiClient VPN + ed25519 SSH keys |

## Files

```
scripts/
  01-base.sh               OS prep — run on BOTH nodes
  02-users.sh              users + sudo + SSH keys — run on controller
  03-slurm-controller.sh   ctld + dbd + QoS — run on node1
  04-slurm-compute.sh      slurmd — run on node1 AND node2
  05-pyxis-enroot.sh       containers — run on BOTH nodes
examples/
  train-cpt.sbatch         CPT job with checkpoint/requeue
  smoke-container.sbatch    container smoke test
pubkeys/                   <user>.pub files go here before running 02
```

## Install order

Scripts auto-detect hostname, CPU, RAM and GPU type — no editing needed.
Node 2 is optional at first; add it with `NODE2_HOST` when it comes up.

```bash
# on node 1 (single node is fine to start)
sudo bash scripts/01-base.sh
sudo bash scripts/02-users.sh          # needs pubkeys/<user>.pub present
sudo bash scripts/03-slurm-controller.sh          # node1 only
GPU_TYPE=h200 sudo -E bash scripts/03-slurm-controller.sh   # force GRES type
NODE2_HOST=<node2> sudo -E bash scripts/03-slurm-controller.sh   # include node2

# on node 2, once it is up
sudo scp node1:/etc/munge/munge.key /etc/munge/
sudo bash scripts/01-base.sh
CTRL_HOST=<node1> sudo -E bash scripts/04-slurm-compute.sh

# on BOTH nodes (containers / sqsh)
sudo bash scripts/05-pyxis-enroot.sh

# verify
sinfo -N -o "%N %T %C %G"      # nodes idle, Gres=gpu:<type>:8
srun --container-image=/shared/containers/ubuntu-test.sqsh echo OK
```

Or use the single entry point that tees a log for pasting back:

```bash
bash scripts/run-on-node.sh preflight     # hardware/driver/GRES report
bash scripts/run-on-node.sh controller    # 01 + 03
bash scripts/run-on-node.sh containers    # 05
bash scripts/run-on-node.sh verify        # sbatch + container smoke test
```

## Before you run anything

1. **Collect ed25519 public keys** from the 3 users into `pubkeys/`:
   each user runs `ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519` on their
   laptop and sends you `~/.ssh/id_ed25519.pub`.
2. **Verify the GRES type matches the driver.** `03` derives it from
   `nvidia-smi --query-gpu=name` (lowercased, spaces→underscores). If Slurm's
   detected name differs, set `GPU_TYPE=<substring>`. A mismatch makes Slurm
   register fewer GPUs than configured and **DRAIN the node**.
   `bash scripts/run-on-node.sh preflight` prints both values to compare.
3. ~~Edit `/etc/hosts`~~ — replaced by auto-detection of the real hostname.

4. **VPN**: connect FortiClient (profile "baremetal") to reach the nodes.

## What was verified (before shipping)

Every script's logic was executed against a real Slurm cluster (Ubuntu 24.04
test bed, systemd, munge, MariaDB, slurmdbd, slurmctld, slurmd):

- 4-node services active; `sinfo` shows node idle
- **SSH** login with `~/.ssh/id_ed25519`, password auth disabled
- **Passwordless sudo** (`sudo -n whoami` → root) for multiple users
- `sbatch` as a regular user → COMPLETED
- **QoS preemption**: high-QoS job PREEMPTED a low-QoS job
- **Requeue**: the preempted `--requeue` job resumed and ran to COMPLETED
  (60/60 steps, gap exactly at the preemption point)
- **Pyxis 0.24.0 compiled** against Slurm 23.11 headers (`libslurm-dev`),
  `srun --container-image` flag present
- **Enroot 4.2.1**: `import -o X.sqsh docker://ubuntu:24.04` → valid 57 MB
  squashfs; `enroot start` requires **pure cgroup v2** (05 checks this)

Known test-bed-only limitation: WSL2 uses hybrid cgroups, so `enroot start`
mounting fails there. Real Ubuntu 22.04+/systemd nodes boot cgroup v2 and are
unaffected — script 05 fails fast with a clear message if it detects hybrid.

## SOW requirement → where it lives

| SOW requirement | Provided by |
|---|---|
| Slurm cluster on both nodes | 03 + 04 |
| GPU scheduling (GRES) | 03: `GresTypes=gpu`, `Gres=gpu:h200:8`, `AutoDetect=nvml` |
| Queues/partitions | 03: `gpu` (default, exclusive) + `debug` |
| Priorities/QoS | 03: multifactor + `high`/`low` QoS |
| Preemption | 03: `PreemptType=preempt/qos`, `PreemptMode=REQUEUE` |
| Requeue | 03: `JobRequeue=1`; jobs use `--requeue` |
| Containers, no modules | 05: Pyxis + Enroot, `.sqsh` from `/shared/containers` |
| Secure access | 01 + 02: sshd pubkey-only, ed25519 keys, sudoers |
| Users with sudo | 02: `NOPASSWD:ALL` per user |

## Day-to-day

```bash
sinfo                          # cluster state
squeue                         # running/pending jobs
sacct -X -o JobID,State,Elapsed,QOS   # history
scancel <jobid>                # kill
scontrol requeue <jobid>       # force requeue (checkpoint/resume test)
sacctmgr show qos              # QoS list

# submit training
sbatch examples/train-cpt.sbatch
```

## Current state (updated)

- **Node 1 is up**, node 2 expected soon.
- **Access**: `ssh ubuntu@10.100.18.5` — requires **FortiClient** VPN
  (profile `baremetal` → gateway `78.100.71.218:10443`). **No Tailscale**
  (30-day POC, kept simple).
- **eduVPN and FortiClient are MUTUALLY EXCLUSIVE** (empirically confirmed
  in both directions):
  - *eduVPN connected* → the agent works, but FortiClient's tunnel does not
    establish (`10.100.18.5:22` unreachable, `ping` = "General failure").
  - *FortiClient connected* → the node is reachable (ping 132 ms, port 22 OK),
    but the model endpoint times out, so the agent stops working.
  - **Consequence: the agent cannot drive the SSH session.** The operator runs
    the scripts and pastes the logs back.
- Tailscale was removed (its `10.0.0.0/8` subnet route also shadowed the
  path to `10.100.18.5`; unnecessary for a 30-day POC).

### How to run this (no agent access to the node)

```bash
# 1. Connect FortiClient (GUI): profile "baremetal", gateway 78.100.71.218:10443
# 2. Confirm the node answers:
ping 10.100.18.5
# 3. Copy this repo to the node, then run ONE command:
scp -r . ubuntu@10.100.18.5:/tmp/i3d-slurm-poc
ssh ubuntu@10.100.18.5
cd /tmp/i3d-slurm-poc && bash scripts/run-on-node.sh preflight
# 4. Paste the preflight output back to the agent, then:
bash scripts/run-on-node.sh controller
```
`run-on-node.sh` tees everything to `/tmp/poc-<stage>-<ts>.log` so you can
paste `tail -n 200` straight back.

