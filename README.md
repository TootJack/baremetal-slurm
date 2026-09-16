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
| Remote access | Tailscale (per SOW) |

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

```bash
# on node1
sudo bash 01-base.sh
sudo bash 02-users.sh          # needs pubkeys/<user>.pub present
sudo bash 03-slurm-controller.sh

# copy the munge key to node2
sudo scp /etc/munge/munge.key node2:/etc/munge/
sudo ssh node2 chown munge: /etc/munge/munge.key

# on node2
sudo bash 01-base.sh
sudo bash 04-slurm-compute.sh

# on BOTH nodes
sudo bash 05-pyxis-enroot.sh

# verify (node1)
sinfo -N -o "%N %T %G"         # both nodes idle, gpu:h200:8
srun --container-image=/shared/containers/ubuntu-test.sqsh echo OK
```

## Before you run anything

1. **Edit `/etc/hosts`** on both nodes (01-base.sh prints a template) with the real IPs.
2. **Collect ed25519 public keys** from the 3 users into `pubkeys/`:
   each user runs `ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519` on their laptop
   and sends you `~/.ssh/id_ed25519.pub`.
3. **Adjust node specs** in 03 (CPUs/RAM) after running `slurmd -C` on each node.
4. **Tailscale**: `sudo tailscale up --auth-key=tskey-...` on both nodes.

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
| Secure access, Tailscale | 01: sshd pubkey-only + Tailscale install |
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
