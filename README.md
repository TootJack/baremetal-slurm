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
| InfiniBand | 8× ConnectX-7, **ACTIVE**, LIDs assigned ✅ | 8× ConnectX-7, **ACTIVE** ✅ |
| Fabric | IB fabric configured upstream (`sm_lid 1`) | same |
| Shared FS | **Lustre `/mnt/i3d_20tb`** over IB ✅ | same |
| Management net | bond0 2×200 GbE LACP = 400 Gb/s | same |
| sudo | passwordless ✅ | passwordless ✅ |
| `/shared` | does not exist | does not exist |

Sizeable notes:
- Both nodes sit on the **same subnet `10.100.18.0/24`** on `bond0`, so they can
  reach each other over IP — `ssh hgx02` failed only because the hostname was
  misspelled (`hgx20`) and there was no `/etc/hosts` entry. `01-base.sh` now
  writes both entries.
- **The IB fabric is UP.** All 8 ConnectX-7 ports read `4: ACTIVE` with
  `LINK_UP`, `link_layer = InfiniBand`, LIDs assigned and `sm_lid 1` — a subnet
  manager is running upstream on i3D's side (not locally, which is normal).
  `ip link` showing `ibp*` as `DOWN` is only the netdev state for an IPoIB
  interface with no IP configured; the RDMA path is fully functional.
- **Lustre is mounted at `/mnt/i3d_20tb` and shared between both nodes**, and
  it runs over the IB fabric (`...@o2ib:/scratch`, `ko2iblnd` loaded).
  Scripts use it automatically instead of a local `/shared`.

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

## Verify multi-node BEFORE installing Slurm

```bash
# on both nodes (no coordination needed)
bash scripts/fabric-verify.sh check

# optional bandwidth test (server first, then client)
#   hgx01:  bash scripts/fabric-verify.sh server
#   hgx20:  bash scripts/fabric-verify.sh client 10.100.18.5
```

Go/no-go for multi-node:
- [ ] both `10.100.18.5` and `10.100.18.8` ping OK
- [ ] all IB ports ACTIVE with LIDs
- [ ] Lustre visible and writable on BOTH nodes (a `verify-<otherhost>-*`
      file appearing proves it is genuinely shared)

## Fabric verification result (2026-09-16)

Run on both nodes — **all three gates PASS**:

| Check | hgx01 | hgx20 |
|---|---|---|
| IP reachability | ✅ both | ✅ both |
| IB fabric | ✅ 8 ports ACTIVE | ✅ 8 ports ACTIVE |
| IB rate | **400 Gb/s (4X NDR)** | **400 Gb/s (4X NDR)** |
| Lustre mounted | ✅ | ✅ |
| Lustre writable | ❌ | ❌ |
| node→node ssh | ❌ | ❌ |

**RDMA data path proven: 182.74 Gb/s** (identical on both ends).

### Notes on the numbers

- The 182 Gb/s test ran over `rocep157s0f0`, whose netdev is a **bond0 slave**
  (`enp157s0f0np0` / `eno19495np0`). That is the RoCE-over-LACP path, ~one
  200 GbE link per flow. It is a **floor, not the target**.
- `ibp26s0` failed with `Couldn't connect to 10.100.18.5:18515` because
  `ib_write_bw` uses **TCP** for its out-of-band handshake and the IPoIB
  interfaces have no IP. Not a fabric fault.
- To measure the native 400G rails: `bash scripts/ib-test.sh server|client <ip>`
  (assigns a temporary IP, measures, removes it).

### Known gaps before Slurm install

1. **Lustre not writable** → `sudo bash scripts/lustre-fix.sh diag` then `fix`.
2. **node→node ssh fails** → `04-slurm-compute.sh` no longer needs it: `03`
   publishes `munge.key` + `slurm.conf` to `<shared>/cluster-config`, so node 2
   just reads them. Install `02-users.sh` keys later if you want direct ssh.

## Bugs found and fixed by actually RUNNING the scripts (2026-09-16)

`03-slurm-controller.sh` exited printing **nothing**. Root cause and the
four further defects it hid — all reproduced in a real cluster, all fixed:

| # | Bug | Symptom | Fix |
|---|---|---|---|
| 1 | `tr -dc ... </dev/urandom \| head -c 24` | `set -o pipefail` + SIGPIPE (141) killed the script **before any output** | read a fixed 512-byte block; no pipe |
| 2 | password regenerated each run, but `CREATE USER IF NOT EXISTS` won't update it | run 2 → `Access denied for 'slurm'@'localhost'` | reuse `/root/.slurm_db_pass`; `ALTER USER` to force it |
| 3 | stale `StateSaveLocation` from another ClusterName | `fatal: CLUSTER NAME MISMATCH` | detect + archive old state dir |
| 4 | `mysql -p"$PASS"` when the user does not exist | **hangs forever** on a password prompt | `--defaults-extra-file` + `timeout` |
| 5 | GRES type guessed from `nvidia-smi` | node `DRAIN`ed: `gres/gpu count reported lower than configured` | use `slurmd -C`'s own `Gres=`; never invent one |

Also fixed: `sacctmgr` calls are all `timeout`-wrapped (they could block),
`01-base.sh` now repairs half-configured dpkg before `apt-get install`
(hgx20 hit `E: Unmet dependencies`), NTP uses chrony since
`timedatectl set-ntp` reports "NTP not supported" on these images, and
`04-slurm-compute.sh` no longer requires `CTRL_HOST` (Lustre provides it).

**Verified:** clean run and re-run both exit 0; node reports `idle`.

### The GRES trap (important for hgx01/hgx20)

Slurm only emits `Gres=` from `slurmd -C` when it can talk to the GPU via
NVML. If `libnvidia-ml.so.1` is not on the loader path, `slurmd -C` shows
**no Gres at all** — and configuring any GRES count then DRAINs the node.
The script now refuses to guess and prints a loud warning instead. On the
H200 nodes, confirm before trusting the output:

```bash
slurmd -G          # must NOT say "lib wasn't found"
slurmd -C          # must include Gres=gpu:nvidia_h200:8
```

## SLURM_MODE=source — Slurm 25.11.8 from source (chosen)

`03`/`04` now accept `SLURM_MODE` (default `source`). It builds Slurm
**25.11.8** to `/opt/slurm` on both nodes via `scripts/slurm-source.sh`.

```bash
# controller (hgx01) - first run also drops the stale accounting DB
RESET_ACCT_DB=1 sudo -E SLURM_MODE=source bash scripts/03-slurm-controller.sh
# compute (hgx20)
sudo -E SLURM_MODE=source bash scripts/04-slurm-compute.sh
# containers, both nodes
sudo bash scripts/05-pyxis-enroot.sh
```

### Why source (and not the vendor/distro stack)

| | Version | Problem |
|---|---|---|
| Vendor (`slurm23.02-client ... cm10.0`) | 23.02 | Lacks SOW features; my first attempt *replaced* it |
| Ubuntu `slurm-wlm` | **21.08.5** | Too old; `HAVE_NVML` undefined → GRES silently broken |
| **Source build** | **25.11.8** | `HAVE_NVML 1` verified; matches the SOW/Slinky target |

### Build facts (measured)

- **~87 s** to compile on 20 cores; download is 6.5 MB.
- Requires `pkg-config`, `libpmix-dev`, `libjson-c-dev`, `libhdf5-dev`,
  `libmariadb-dev`, and **`libnvidia-ml-dev`** (provides `nvml.h`).
- **Without `libnvidia-ml-dev`, `HAVE_NVML` is UNDEFINED** and GPU GRES
  silently fails — `slurm-source.sh` verifies and refuses to install.

### Problems found and fixed by running it

| Symptom | Cause | Fix |
|---|---|---|
| `HAVE_NVML` undefined | `nvml.h` missing | install `libnvidia-ml-dev`, verify the define |
| `Exception caught: rsmi_init` | distro `rocm_smi` autodetected, no AMD GPU | `--without-rsmi` |
| `sacctmgr: fetch_config: DNS SRV lookup failed` (20 s hang) | `/etc/slurm/slurm.conf` written **after** the dbd probe | seed a minimal config before probing |
| `fatal: Database schema is too old` | DB created by Slurm 21.08/23.11 | `RESET_ACCT_DB=1` (drops history); verified a fresh DB starts fine |
| `slurmdbd` "Deactivated successfully" with no error | no `PidFile`; `Type=forking` lost the daemon | `Type=simple` + `-D` |
| `fatal: /sys/fs/cgroup is not a valid cgroup2 mountpoint` | forced `cgroup/v2` when only hybrid cgroups exist | detect with `stat -fc %T`, fall back to `cgroup/v1` |
| **`slurmd initialization failed`** | Pyxis built against 23.11: *"Incompatible Slurm plugin version (23.11.4)"* | rebuild Pyxis when the Slurm version changes, stamp `.built-against` |

### Verified end state (test cluster)

```
slurmctld 25.11.8  /  slurmd 25.11.8  /  slurmdbd 25.11.8
sinfo: node = idle
daemons: munge, mariadb, slurmdbd, slurmctld, slurmd all active
```

Note Pyxis builds against the version of Slurm that will load it — a mismatch
makes `slurmd` **refuse to start entirely**, not merely skip the plugin.
