# Running jobs on the i3D H200 cluster

A short guide for ML engineers. No admin steps — the cluster is already set up.

**What you have:** 2 nodes, 8× NVIDIA H200 (143 GB each) per node. 16 GPUs
total. Slurm 25.11, shared Lustre storage at `/shared`, containers via Enroot
+ Pyxis.

---

## 1. Get on the cluster

SSH to the login/controller node:

```bash
ssh ubuntu@10.100.18.5      # hgx01
```

Both nodes share `/shared` (Lustre over InfiniBand), so files you put there
are visible from every node — including inside jobs.

Check the cluster is healthy:

```bash
sinfo
```

```
PARTITION AVAIL  TIMELIMIT  NODES  STATE NODELIST
gpu*         up   infinite      2   idle hgx[01,20]
debug        up    2:00:00      2   idle hgx[01,20]
```

`idle` = free. Other states: `alloc` (busy), `mix` (partly free),
`drain`/`inval` (broken — tell an admin).

---

## 2. Your first job (30 seconds)

```bash
sbatch --wrap="hostname; nvidia-smi -L" --gres=gpu:1
```

Then:

```bash
squeue                      # is it running?
cat slurm-<jobid>.out       # its output
```

You should see a hostname and 8 GPU lines. **`--gres=gpu:1` allocates 1 GPU.**

> ⚠️ **If you see `Invalid generic resource (gres) specification`**, you asked
> for a GPU when none was available/is configured — check `sinfo -o "%N %G"`
> shows `gpu:nvidia_h200:8`. On a healthy cluster this should not happen.

---

## 3. Where to put files

**Use `/shared` for anything a job reads or writes.** `/tmp` and your home
directory on one node are *not* visible from the other node.

```bash
/shared/data        # datasets
/shared/ckpt        # checkpoints
/shared/scratch     # temp, world-writable
/shared/containers  # .sqsh container images
```

```bash
mkdir -p /shared/ckpt/myexperiment
cp -r /shared/data/my_dataset /shared/data/my_dataset_v2
```

**Why it matters:** if your job writes to `/tmp` and runs on the *other* node,
you will not find the file afterwards. This is the single most common
confusion.

---

## 4. Writing a batch script

Put this in `train.sbatch`:

```bash
#!/bin/bash
#SBATCH --job-name=mytrain
#SBATCH --partition=gpu
#SBATCH --nodes=1                  # 1 node = 8 H200s
#SBATCH --gpus-per-node=8          # all 8 GPUs on that node
#SBATCH --ntasks-per-node=8        # one task per GPU
#SBATCH --cpus-per-task=24         # 192 cores / 8 tasks
#SBATCH --time=04:00:00            # 4 hours
#SBATCH --output=/shared/ckpt/%x-%j.out      # %x=job name, %j=job id

export DATA_PATH=/shared/data/my_dataset
export CKPT_PATH=/shared/ckpt/myexperiment

# 'srun' runs the command on every allocated node, in parallel.
# Without 'srun' it runs on ONE node only.
srun python train.py --data $DATA_PATH --ckpt $CKPT_PATH
```

Submit and watch:

```bash
sbatch train.sbatch
squeue -u $USER                   # your jobs
tail -f /shared/ckpt/mytrain-123.out
```

> **`#SBATCH` lines must be at the top**, before any command. Slurm stops
> reading them at the first line that isn't a comment, and **silently ignores**
> the rest. A misplaced `#SBATCH` is a very common silent bug.

---

## 5. Single-node vs multi-node

| You want | Use |
|---|---|
| 1 GPU | `--gres=gpu:1` |
| All 8 GPUs on one node | `--nodes=1 --gpus-per-node=8 --ntasks-per-node=8` |
| Both nodes, 16 GPUs | `--nodes=2 --gpus-per-node=8 --ntasks-per-node=8` |

**Start with one node.** It's usually enough and you skip every distributed
networking issue.

### Single node, 8 GPUs (`torchrun`)

```bash
#!/bin/bash
#SBATCH --job-name=torch1n
#SBATCH --nodes=1
#SBATCH --gpus-per-node=8
#SBATCH --ntasks-per-node=8
#SBATCH --cpus-per-task=24
#SBATCH --time=04:00:00
#SBATCH --output=/shared/ckpt/%x-%j.out

srun torchrun \
  --nnodes=1 \
  --nproc_per_node=8 \
  --master_port=29500 \
  train.py
```

### Two nodes, 16 GPUs (`torchrun`)

```bash
#!/bin/bash
#SBATCH --job-name=torch2n
#SBATCH --nodes=2
#SBATCH --gpus-per-node=8
#SBATCH --ntasks-per-node=8
#SBATCH --cpus-per-task=24
#SBATCH --time=04:00:00
#SBATCH --output=/shared/ckpt/%x-%j.out

# First node in the allocation is the rendezvous host.
MASTER_ADDR=$(scontrol show hostnames "$SLURM_JOB_NODELIST" | head -1)
MASTER_PORT=29500

srun torchrun \
  --nnodes="$SLURM_NNODES" \
  --nproc_per_node=8 \
  --node_rank="$SLURM_NODEID" \
  --master_addr="$MASTER_ADDR" \
  --master_port="$MASTER_PORT" \
  train.py
```

> **Do not use `--master-addr $(hostname)`** in a multi-node job. `$(hostname)`
> runs on *each* node, so both ranks would point at themselves. Always derive
> the master from `$SLURM_JOB_NODELIST` as above.

### Nebius `srun` style

If you're used to Nebius/Soperator, `srun` is the same idea — it launches your
command across the allocation:

```bash
srun --cpus-per-task=24 python train.py
```

---

## 6. Interactive sessions

For debugging, get a shell on a node with GPUs:

```bash
srun --gres=gpu:1 --time=00:30:00 --pty bash
```

You now have an interactive shell **on the compute node** with 1 GPU. Run
`nvidia-smi`, poke at data, exit when done. Nothing runs on the login node.

---

## 7. Containers (Enroot + Pyxis)

No `module load`, no host Python setup. Use a container.

### One-off

```bash
srun --gres=gpu:1 --container-image=nvcr.io#nvidia/pytorch:24.07-py3 \
  python -c "import torch; print(torch.cuda.get_device_name(0))"
```

The image is pulled and cached to `/shared` automatically (shared by both
nodes). `#` separates the registry from the image: `nvcr.io#nvidia/pytorch:24.07-py3`.

### In a batch script

```bash
#!/bin/bash
#SBATCH --job-name=cont
#SBATCH --nodes=1
#SBATCH --gpus-per-node=8
#SBATCH --ntasks-per-node=8
#SBATCH --cpus-per-task=24
#SBATCH --time=04:00:00
#SBATCH --output=/shared/ckpt/%x-%j.out
#SBATCH --container-image=nvcr.io#nvidia/pytorch:24.07-py3
#SBATCH --container-mounts=/shared/data:/data,/shared/ckpt:/ckpt
#SBATCH --container-workdir=/workspace
#SBATCH --container-remap-root

srun python /workspace/train.py --data /data/my_dataset --ckpt /ckpt/myexp
```

### Pre-build an image once (recommended)

Caching is faster and makes runs reproducible:

```bash
enroot import -o /shared/containers/myenv.sqsh docker://nvcr.io#nvidia/pytorch:24.07-py3
```

Then every job uses the local file — no registry pull:

```bash
#SBATCH --container-image=/shared/containers/myenv.sqsh
```

> **Mount your code and data** with `--container-mounts`. A container can't see
> `/shared` unless you mount it. Format is `host:container`, comma-separated.

---

## 8. Preemption and long jobs

Checkpoints are not optional on a shared cluster. Add:

```bash
#SBATCH --requeue                      # auto-restart (same job id) if preempted
#SBATCH --signal=B:SIGTERM@120         # tell your app 120s before the kill
```

With `--requeue`, a preempted job restarts automatically and
`$SLURM_RESTART_COUNT` increments. **Your training script must resume from a
checkpoint** to take advantage of this:

```bash
#SBATCH --qos=high     # higher priority, less likely to be preempted
```

QoS: `high` (preempts others), `normal` (default), `low` (preemptible).
Use `low` for experiments, `high` for runs that must finish.

Checkpoint every few minutes and put checkpoints **on `/shared`**, or a
requeued job (which may land on the other node) will not find them.

---

## 9. Monitoring

```bash
squeue -u $USER                                  # your jobs
squeue -o "%.10i %.9P %.20j %.8u %.2t %.10M %.6D %R"   # useful fields
scontrol show job <jobid>                        # full detail + Reason=
scancel <jobid>                                  # cancel one
scancel -u $USER                                 # cancel all yours
```

Job states you'll see: `PD` pending, `R` running, `CG` completing,
`CD` completed, `F` failed.

### Why is my job pending?

```bash
squeue -j <jobid> -o "%.10i %.2t %.20R"    # the REASON column
```

| Reason | Meaning |
|---|---|
| `Resources` | GPUs busy — wait, or ask for fewer |
| `Priority` | someone with higher priority is ahead |
| `QOSMaxJobsPerUserLimit` | too many jobs for your QoS |
| `AssocGrpGRES` | you requested more GPUs than your account allows |

### After it finishes

```bash
sacct -j <jobid> -o JobID,State,Elapsed,AllocTRES
sacct --starttime today -u $USER
```

> Use **`AllocTRES`**, not `AllocGRES`. `AllocGRES` was **removed in Slurm
> 25.11** and makes `sacct` fail with "please use AllocTRES".

---

## 10. `sbatch` cheat sheet

Always available: `sbatch --help`, `man sbatch`, `srun --help`.

| Setting | Example | Notes |
|---|---|---|
| GPUs on a node | `--gpus-per-node=8` | prefer over `--gres=gpu:8` |
| GPUs per task | `--gpus-per-task=1` | with `--ntasks-per-node=8` |
| Just one GPU | `--gres=gpu:1` | for tests |
| CPU cores per task | `--cpus-per-task=24` | 192/8 = 24 |
| Job length | `--time=04:00:00` | **always set this** |
| Output file | `--output=/shared/ckpt/%x-%j.out` | `%x`=name `%j`=id |
| Error file | `--error=/shared/ckpt/%x-%j.err` | else merged into output |
| Whole node | `--exclusive` | no other job shares your node |
| All RAM | `--mem=0` | avoid OOM at allocation time |
| Nice name | `--job-name=mytrain` | use it for `squeue` |
| Auto-restart | `--requeue` | with checkpointing |
| Dependency | `--dependency=afterok:<jobid>` | chain jobs |

Pass any of these on the command line instead of in the script:
`sbatch --nodes=2 --time=01:00:00 train.sbatch`.

---

## 11. Debugging a failed job

Work in this order:

```bash
scontrol show job <jobid> | grep -E "State|Reason|ExitCode|WorkDir|StdOut"
cat /shared/ckpt/<jobname>-<jobid>.out
cat /shared/ckpt/<jobname>-<jobid>.err 2>/dev/null
```

| Symptom | Usually means |
|---|---|
| `sbatch: error: Invalid generic resource (gres) specification` | GPU request doesn't match config; check `sinfo -N -o "%N %G"` |
| Job vanished, no output file | your `--output=` directory doesn't exist. `mkdir -p` it |
| `Cannot allocate memory` at start | add `--mem=0`, or lower `--cpus-per-task` |
| `--gres` ignored / no GPU | a misplaced `#SBATCH` line (must be at the top) |
| Output file not found after the job | wrote to `/tmp`/home on the *other* node — use `/shared` |
| `NCCL`/timeout errors multi-node | wrong `--master_addr`; use `scontrol show hostnames` |
| `CUDA_VISIBLE_DEVICES` empty in the job | you didn't request a GPU |
| Job stays `PD` forever | look at the REASON column (section 9) |

**Fastest sanity check** — does a trivial GPU job work at all?

```bash
srun --gres=gpu:1 --time=00:05:00 nvidia-smi -L
```

If that works, the cluster and your account are fine and the problem is in
your script.

---

## 12. Quick reference

```bash
sinfo                                   # cluster state
sinfo -N -o "%N %T %G"                  # per-node GPUs
squeue -u $USER                         # my jobs
sbatch train.sbatch                     # submit
srun --gres=gpu:1 --pty bash            # interactive shell w/ 1 GPU
srun --gres=gpu:1 nvidia-smi -L         # GPU smoke test
scancel <jobid>                         # cancel
scontrol show job <jobid>               # why is it pending/failed
sacct -j <jobid>                        # finished job history
tail -f /shared/ckpt/<job>-<id>.out     # follow output
```

### Cluster facts

| | |
|---|---|
| Login | `ssh ubuntu@10.100.18.5` (hgx01) |
| Nodes | `hgx01`, `hgx20` — 8× H200 each |
| Partition | `gpu` (default), `debug` (2 h limit) |
| Cores/node | 192 |
| RAM/node | ~2 TB |
| Shared storage | `/shared` → `/mnt/i3d_20tb/slurm-poc` (Lustre/IB) |
| Slurm | 25.11.8 |
| Containers | Enroot + Pyxis (`.sqsh`) |
| GPU | NVIDIA H200, 143 GB, driver 550.54.14 |

---

## 13. Getting help

Before asking, collect this — it answers most questions:

```bash
squeue -u $USER
scontrol show job <jobid> | head -30
ls -l /shared/ckpt/
nvidia-smi -L          # on the compute node (via srun --pty bash)
```

Then say: **what you ran, what you expected, what happened.**
