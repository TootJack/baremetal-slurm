# i3D.net H200 Slurm POC — Deployment Scripts

Bare-metal Slurm cluster for the MLOps POC on 2 × 8×H200 (i3D.net).
Jobs run as **sqsh containers** (Pyxis + Enroot) — no environment modules.

## Cluster facts (measured 2026-09-16)

| | hgx01 | hgx20 |
|---|---|---|
| IP (bond0) | `10.100.18.5` | `10.100.18.8` |
| OS | Ubuntu 22.04.4 LTS | Ubuntu 22.04.4 LTS |
| Kernel | 5.15.0-113-generic | 5.15.0-113-generic |
| cgroup | **cgroup2fs** ✅ | **cgroup2fs** ✅ |
| CPU / RAM | 192 vCPU / 2015 GiB | 192 vCPU / 2015 GiB |
| GPUs | 8× H200 (143 GiB each) | 8× H200 (143 GiB each) |
| NVLink | **NV18** (all-to-all) ✅ | **NV18** (all-to-all) ✅ |
| Driver | 550.54.14 | 550.54.14 |
| fabricmanager | **active** ✅ | **active** ✅ |
| InfiniBand | 8× ConnectX-7, ports **DOWN** ⚠️ | 8× ConnectX-7, ports **DOWN** ⚠️ |
| sudo | passwordless ✅ | passwordless ✅ |
| `/shared` | does not exist | does not exist |

Sizeable notes:
- Both nodes sit on the **same subnet `10.100.18.0/24`** on `bond0`, so they can
  reach each other over IP — `ssh hgx02` failed only because the hostname was
  misspelled (`hgx20`) and there was no `/etc/hosts` entry. `01-base.sh` now
  writes both entries.
- **IB ports are DOWN.** That is expected until a subnet manager (or the
  provider's fabric) is up. Multi-node NCCL without IB falls back to TCP over
  `bond0` — functional but far slower. See "Fabric" below.

## Files

```
scripts/
  01-base.sh               OS prep — run on BOTH nodes
  02-users.sh              users + sudo + SSH keys — run on controller
  03-slurm-controller.sh   ctld + dbd + QoS — run on hgx01
  04-slurm-compute.sh      slurmd — run on BOTH nodes
  05-pyxis-enroot.sh       containers — run on BOTH nodes
  run-on-node.sh           one entry point; tees a log to paste back
examples/
  train-cpt.sbatch         CPT job with checkpoint/requeue
  smoke-container.sbatch   container smoke test
pubkeys/                   <user>.pub files go here before running 02
test/                      validation + diagnostics (check-vpn, validate-gres, ...)
```

## Access (why the agent cannot drive this)

**eduVPN and FortiClient are mutually exclusive** on the admin laptop:

| Connected | Node `10.100.18.5` | Agent |
|---|---|---|
| eduVPN | ❌ unreachable | ✅ works |
| FortiClient | ✅ ping 132 ms, port 22 OK | ❌ model times out |

So the operator runs the scripts and pastes the logs back.

## Install order

Scripts auto-detect hostname, CPU, RAM and GPU type. Node 2 is optional until
it is up.

```bash
# --- on hgx01 (10.100.18.5) ---
cd ~/hengjiantmp/i3d-slurm-poc
bash scripts/run-on-node.sh preflight        # already done ✅
bash scripts/run-on-node.sh fabric           # check IB / shared FS
sudo bash scripts/01-base.sh                 # writes /etc/hosts, sysctls, sshd
sudo bash scripts/03-slurm-controller.sh     # single node to start

# --- on hgx20 (10.100.18.8) ---
cd ~/hengjiantmp/i3d-slurm-poc
sudo bash scripts/01-base.sh
CTRL_HOST=hgx01 sudo -E bash scripts/04-slurm-compute.sh
sudo scp hgx01:/etc/munge/munge.key /etc/munge/   # if 04 could not fetch it

# include node2 in the controller config (re-run on hgx01)
NODE2_HOST=hgx20 sudo -E bash scripts/03-slurm-controller.sh

# --- on BOTH nodes: containers / sqsh ---
sudo bash scripts/05-pyxis-enroot.sh

# --- verify (hgx01) ---
sinfo -N -o "%N %T %C %G"
bash scripts/run-on-node.sh verify
```

`run-on-node.sh` stages: `preflight | fabric | controller | containers | verify`
Everything is teed to `/tmp/poc-<stage>-<ts>.log`.

## GRES

`03` derives the GPU type from `nvidia-smi --query-gpu=name` → `nvidia_h200`.
Slurm must detect the same `Type`, or it registers fewer GPUs than configured
and **DRAINs the node**. Override if needed:

```bash
GPU_TYPE=h200 sudo -E bash scripts/03-slurm-controller.sh
```

`preflight` prints both values so they can be compared.

## Open issue: inter-node fabric

Multi-node (16-GPU) training needs the 8× ConnectX-7 links up. Currently all
IB ports read `DOWN`. Options, in order of preference:

1. **Ask i3D to bring up the IB fabric / subnet manager** — this is a provider
   question, and the correct fix for the SOW's "NCCL over the inter-node
   fabric" criterion.
2. **Soft-RoCE (`rdma_rxe`) over `bond0`** — works today, no provider action,
   but bandwidth is limited by the bonded Ethernet uplink.
3. **Plain TCP NCCL over `bond0`** — always works, slowest.

`run-on-node.sh fabric` reports the current state so we can decide.
