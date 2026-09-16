# i3D.net H200 Slurm POC — Deployment

Bare-metal Slurm cluster for the MLOps POC on 2 × 8×H200 (i3D.net).
Jobs run as **sqsh containers** (Pyxis + Enroot) — no environment modules.

> **Just want to run a job?** Read **[USER-GUIDE.md](USER-GUIDE.md)**. It is
> written for ML engineers and contains no deployment content.
> This README documents the deployment for whoever maintains the cluster.

**Status:** operational. Both nodes `idle`, 16× H200 schedulable,
containerised jobs verified end to end.

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
| `/shared` | symlink → `/mnt/i3d_20tb/slurm-poc` | same |

Notes:
- Both nodes sit on the **same subnet `10.100.18.0/24`** on `bond0`, so they
  reach each other over IP. `01-base.sh` writes both `/etc/hosts` entries.
- **The IB fabric is UP.** All 8 ConnectX-7 ports read `4: ACTIVE` with
  `LINK_UP`, `link_layer = InfiniBand`, LIDs assigned and `sm_lid 1` — a subnet
  manager runs upstream on i3D's side (not locally, which is normal).
  `ip link` showing `ibp*` as `DOWN` is only the netdev state for an IPoIB
  interface with no IP configured; the RDMA path is fully functional.
- **Lustre is mounted at `/mnt/i3d_20tb` and shared between both nodes**, over
  the IB fabric (`...@o2ib:/scratch`, `ko2iblnd` loaded). Scripts use it
  automatically. `/shared` is a symlink to it so example `#SBATCH` paths work.

## Files

```
USER-GUIDE.md              job submission guide for ML engineers
poc.sh                     operational entry point: sync|status|fix|drains|test|containers
scripts/
  01-base.sh               OS prep — run on BOTH nodes
  02-users.sh              users + sudo + SSH keys — run on controller
  03-slurm-controller.sh   ctld + dbd + QoS — run on hgx01
  04-slurm-compute.sh      slurmd — run on BOTH nodes
  05-pyxis-enroot.sh       containers — run on BOTH nodes
  run-on-node.sh           staged runner (preflight|fabric|controller|containers|verify)
  lib.sh                   shared helpers (hosts, node detection, staging)
  slurm-source.sh          build Slurm 25.11.8 from source
  fabric-verify.sh         IB / shared-FS checks
  ib-test.sh               RDMA bandwidth
  lustre-fix.sh            Lustre mount repair
examples/
  train-cpt.sbatch         CPT template (needs your image + entrypoint)
  smoke-container.sbatch   container smoke test
pubkeys/                   <user>.pub files go here before running 02
test/                      regression tests and diagnostics
```

## Operating the cluster

Use `poc.sh` — one plain word per action. **Do not paste command blocks from
this file**: pasting a markdown fence into a shell makes bash treat the
backticks as a command substitution, and it then swallows everything pasted
after it (`unexpected EOF while looking for matching ``'`), so the session
appears to hang and later commands silently never run.

**The order is not symmetric.** Node 2 announces itself *before* the controller
is told about it — that removes a deadlock where the controller needed node 2's
hardware (which only node 2 can measure) while node 2 waited for a `slurm.conf`
that mentioned it.

```
# --- on hgx01 ---
cd ~/hengjiantmp/i3d-slurm-poc
./poc.sh sync                 # fetch the latest scripts
./poc.sh fix                  # 01-base + 03 (controller) + resumes stale drains

# --- on hgx20 ---
cd ~/hengjiantmp/i3d-slurm-poc
./poc.sh sync
./poc.sh fix                  # 01-base + 04 (publishes its own node line)

# --- back on hgx01: add node 2 from the line IT published ---
./poc.sh fix

# --- back on hgx20: the conf now mentions it, so slurmd starts ---
./poc.sh fix

# --- either node ---
./poc.sh status               # read-only health report
./poc.sh test                 # a real job end to end
./poc.sh containers           # Pyxis + Enroot, on BOTH nodes
```

| action | what it does |
|---|---|
| `sync` | `git pull --ff-only origin main` |
| `status` | read-only report: binaries, daemons, hosts, `slurmd -C`, GRES, `sinfo` exit code, node `Reason=`, partitions, recent daemon errors |
| `fix` | `01-base.sh`, then `03` (on hgx01, including a second pass with `NODE2_HOST`) or `04` |
| `drains` | clears stale drains; reports any node still failing validation |
| `test` | submits a real job, waits for a terminal state, prints output + accounting |
| `containers` | `05-pyxis-enroot.sh` |
| `help` | usage |

With no argument it runs `status`, which changes nothing.

`run-on-node.sh` remains available for staged runs
(`preflight | fabric | controller | containers | verify`), teeing to
`/tmp/poc-<stage>-<ts>.log`.

## GRES

`03` takes the GPU type and count from `slurmd -C`'s own `Gres=` field — the
exact value slurmctld compares against. It never guesses from `nvidia-smi`: if
`slurmd` cannot see the GPU via NVML, configuring any count registers fewer
GPUs than configured and **DRAINs the node**.

Confirm on a node before trusting the output:

```bash
slurmd -G          # must NOT say "lib wasn't found"
slurmd -C          # must include Gres=gpu:nvidia_h200:8
```

## Verify multi-node

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

Hostname resolution is the one thing to check on every node — if a cluster name
resolves to `127.0.1.1`, Slurm will never reach the controller:

```bash
getent ahostsv4 hgx01 hgx20      # must show 10.100.18.5 / 10.100.18.8
bash test/verify-hosts-resolution.sh
```

## Fabric verification result (2026-09-16)

| Check | hgx01 | hgx20 |
|---|---|---|
| IP reachability | ✅ both | ✅ both |
| IB fabric | ✅ 8 ports ACTIVE | ✅ 8 ports ACTIVE |
| IB rate | **400 Gb/s (4X NDR)** | **400 Gb/s (4X NDR)** |
| Lustre mounted | ✅ | ✅ |
| Lustre writable | ✅ (after `lustre-fix.sh`) | ✅ |

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

## Build: SLURM_MODE=source — Slurm 25.11.8

`03`/`04` accept `SLURM_MODE` (default `source`). It builds Slurm **25.11.8**
to `/opt/slurm` on both nodes via `scripts/slurm-source.sh`.

```bash
# controller (hgx01)
sudo -E SLURM_MODE=source bash scripts/03-slurm-controller.sh
# compute (hgx20)
sudo -E SLURM_MODE=source bash scripts/04-slurm-compute.sh
# containers, both nodes
sudo bash scripts/05-pyxis-enroot.sh
```

### Why source, not the vendor/distro stack

| | Version | Problem |
|---|---|---|
| Vendor (`slurm23.02-client ... cm10.0`) | 23.02 | Lacks SOW features |
| Ubuntu `slurm-wlm` | **21.08.5** | Too old; `HAVE_NVML` undefined → GRES silently broken |
| **Source build** | **25.11.8** | `HAVE_NVML 1` verified; matches the SOW/Slinky target |

### Build facts (measured)

- **~90 s** to compile; download is 6.5 MB.
- Requires `pkg-config`, `libpmix-dev`, `libjson-c-dev`, `libhdf5-dev`,
  `libmariadb-dev`, and **`libnvidia-ml-dev`** (provides `nvml.h`).
- **Without `libnvidia-ml-dev`, `HAVE_NVML` is UNDEFINED** and GPU GRES
  silently fails — `slurm-source.sh` verifies and refuses to install.
- Pyxis builds against the Slurm version that will load it. A mismatch makes
  `slurmd` **refuse to start entirely**, not merely skip the plugin.

### Problems found and fixed by running it

| Symptom | Cause | Fix |
|---|---|---|
| `HAVE_NVML` undefined | `nvml.h` missing | install `libnvidia-ml-dev`, verify the define |
| `Exception caught: rsmi_init` | distro `rocm_smi` autodetected, no AMD GPU | `--without-rsmi` |
| `sacctmgr: fetch_config: DNS SRV lookup failed` (20 s hang) | `/etc/slurm/slurm.conf` written **after** the dbd probe | seed a minimal config before probing |
| `fatal: Database schema is too old` | DB created by Slurm 21.08/23.11 | `RESET_ACCT_DB=1` (drops history) |
| `slurmdbd` "Deactivated successfully" with no error | no `PidFile`; `Type=forking` lost the daemon | `Type=simple` + `-D` |
| `fatal: /sys/fs/cgroup is not a valid cgroup2 mountpoint` | forced `cgroup/v2` when only hybrid cgroups exist | detect with `stat -fc %T`, fall back to `cgroup/v1` |
| `slurmd initialization failed` | Pyxis built against 23.11: *"Incompatible Slurm plugin version"* | rebuild Pyxis when Slurm changes; stamp `.built-against` |

## Vendor-stack landmines (found on hgx01)

Removing the vendor Slurm leaves configuration pointing at the **deleted**
tree. These are now handled automatically.

### 1. `munge` fails: vendor `OPTIONS` overrides the key path

```
Process: ExecStart=/usr/sbin/munged --key-file=/cm/shared/apps/slurm/var/munge/keys/munge.key
```

The Ubuntu munge unit expands `$OPTIONS` from `/etc/default/munge`, and the
vendor stack pointed that at the tree we removed — so `munged` exits 1 and the
whole cluster stops authenticating. Neutralising `/etc/default/munge` was not
enough: the vendor `--key-file` survived via drop-ins.

**Fix:** `03`/`04` write a complete `/etc/systemd/system/munge.service` with a
hardcoded `ExecStart` and **no `EnvironmentFile` / `$OPTIONS`**. Nothing left
behind can override a hardcoded ExecStart.

*Verified against a hostile state:* `OPTIONS` in `/etc/default/munge` **plus**
a drop-in injecting `Environment=OPTIONS=...` → before: `failed`; after:
`active`, `STATUS: Success`.

### 2. Stale systemd drop-ins for slurmctld/slurmdbd

`/etc/systemd/system/slurm{ctld,dbd}.service.d/override.conf` silently
overrides the units we install. `slurm-source.sh` clears them.

### 3. The vendor tree is `/cm/shared/apps/...`

Worth knowing when auditing leftovers:

```bash
grep -rl "/cm/" /etc/slurm /etc/default /etc/systemd/system 2>/dev/null
```

## Bugs found and fixed by actually RUNNING the scripts

`03-slurm-controller.sh` exited printing **nothing**. Root cause and the
further defects it hid — all reproduced in a real cluster, all fixed:

| # | Bug | Symptom | Fix |
|---|---|---|---|
| 1 | `tr -dc ... </dev/urandom \| head -c 24` | `set -o pipefail` + SIGPIPE (141) killed the script **before any output** | read a fixed 512-byte block; no pipe |
| 2 | password regenerated each run, but `CREATE USER IF NOT EXISTS` won't update it | run 2 → `Access denied for 'slurm'@'localhost'` | reuse `/root/.slurm_db_pass`; `ALTER USER` to force it |
| 3 | stale `StateSaveLocation` from another ClusterName | `fatal: CLUSTER NAME MISMATCH` | detect + archive old state dir |
| 4 | `mysql -p"$PASS"` when the user does not exist | **hangs forever** on a password prompt | `--defaults-extra-file` + `timeout` |
| 5 | GRES type guessed from `nvidia-smi` | node `DRAIN`ed: `gres/gpu count reported lower than configured` | use `slurmd -C`'s own `Gres=`; never invent one |
| 6 | `/etc/hosts`: Debian's `127.0.1.1 <hostname>` line | own name resolves to **loopback** → `SlurmctldHost=hgx01` binds loopback → other nodes get `Unable to contact slurm controller (connect failure)` | delete the loopback line for cluster names before writing the LAN mapping |
| 7 | `SlurmctldHost=<name>(<addr>)` pinned an address | replies came from a different address than clients used → `Socket timed out on send/recv operation` | use the bare hostname; let `/etc/hosts` resolve it on every node |
| 8 | `systemctl enable --now slurmd/slurmctld` on a re-run | daemon kept the **previous** `slurm.conf` → `Node X appears to have a different slurm.conf than the slurmctld`, node stuck `inval` | `enable` + `restart` |
| 9 | state dir cleared partially (left `clustername`, dropped `assoc_usage`) | `fatal: No Assoc usage file (/var/spool/slurmctld/assoc_usage) to recover` | delete the **whole** dir, then verify it is empty |
| 10 | `detect_node "$NODE2_HOST"` ran `slurmd -C` **locally** | node 2's stanza carried node 1's CPU/RAM/GPU counts → `inval` (INVALID_REG) | node 2 publishes its own line to shared storage; the controller **reads** it and refuses to guess |
| 11 | documented order was a deadlock | 03 wrote a conf without node 2; 04 installed it verbatim → `fatal: Unable to determine this slurmd's NodeName` | 04 publishes its node line and stops; then 03 adds node 2; then 04 starts slurmd |
| 12 | `sinfo ... \|\| sinfo` as the last command under `set -e` | both fail while slurmctld restarts → **03 exits 1 despite succeeding** | report-only, never fatal |
| 13 | `resolve_shared_root` sourced the conf file over `SHARED_ROOT` | an explicit `SHARED_ROOT=` override was silently ignored | environment wins over the file |
| 14 | node physically healthy but stuck `DRAIN` after a failed registration | jobs never run; `ReturnToService` does **not** clear it | `node_mgr.c` only returns a node to service when `IS_NODE_DOWN() && !IS_NODE_INVALID_REG() && ret2service==2` — so `03` resumes nodes that now register cleanly and leaves genuinely failing ones drained |
| 15 | state dir holding `clustername` without `assoc_usage` | `fatal: No Assoc usage file ... to recover` — slurmctld crash-loops forever, and a matching cluster name makes it look fine | detect the inconsistent dir and reset it |
| 16 | `NodeName=` line carried no CPU topology | `Reason=gres/gpu GRES autodetected core affinity 0-95 doesn't match socket boundaries (Socket 0 is cores 0-0)`, node `DRAIN+INVALID_REG` | keep `slurmd -C`'s output verbatim (`Boards`, `SocketsPerBoard`, `CoresPerSocket`, `ThreadsPerCore`); omitting `CoresPerSocket` makes slurmctld assume 1 |
| 17 | `AccountingStorageHost=127.0.0.1` | a compute node tried to reach slurmdbd on **itself** → `sacct`/`squeue` hang on hgx20 | point it at the controller, the address every node resolves identically |
| 18 | example `#SBATCH` paths used `/shared`, which did not exist | `sbatch` accepted the job then it died at launch with no output | `/shared` symlink to the real shared root (`01-base.sh`) |

Bugs 6-18 are the multi-node blockers: with the full stack installed, `hgx01`
showed the node as `inval` and `hgx20` could not reach the controller at all.
All are fixed and locked down by the regression tests:

| test | covers |
|---|---|
| `verify-hosts-resolution.sh` | `/etc/hosts` mapping, loopback shadow, stray duplicates |
| `verify-multinode-bootstrap.sh` | node-line publish/read, atomicity |
| `verify-node-topology.sh` | full CPU topology preserved verbatim |
| `verify-two-node-flow.sh`, `verify-03-node2.sh` | 03 refuses to invent node 2, then succeeds |
| `verify-stale-node-line.sh` | rejects a line published without topology |
| `verify-drain-clear.sh` | stale drain is resumed, still-failing node is not |
| `verify-inconsistent-state.sh` | cluster recovers from an inconsistent state dir |
| `verify-shared-and-accounting.sh` | `/shared` and accounting host |
| `verify-user-guide-commands.sh` | every command in USER-GUIDE.md is valid |
| `verify-end-to-end.sh` | clean bring-up → node `idle` → job `COMPLETED` |

Also fixed: `sacctmgr` calls are all `timeout`-wrapped (they could block),
`01-base.sh` repairs half-configured dpkg before `apt-get install` (hgx20 hit
`E: Unmet dependencies`), NTP uses chrony since `timedatectl set-ntp` reports
"NTP not supported" on these images, and `04-slurm-compute.sh` no longer
requires `CTRL_HOST` (Lustre provides the staging area).

> **If a name resolves to the wrong address**, the cause is usually a stray or
> duplicate `/etc/hosts` line outside the managed block. nsswitch is
> `files dns`, and within `files` the **first** match wins — so such a line
> silently beats the block and still resolves "successfully", just wrongly.
> `01-base.sh` removes those. To inspect:

```bash
sudo bash -c 'source scripts/lib.sh && show_cluster_hosts_sources'
```

## Verified end state

```
Slurm 25.11.8 (source build at /opt/slurm), Pyxis + Enroot
sinfo:
  gpu*   up infinite  2  idle  hgx[01,20]
  debug  up  2:00:00  2  idle  hgx[01,20]
per node: gpu:nvidia_h200:8(S:0-1)
daemons: munge, mariadb, slurmdbd, slurmctld, slurmd — all active
a submitted GPU job completes and is reported by sacct
```

## Next

The platform is complete. What remains is the benchmark deliverable, which
needs a real training stack:

1. Build a container image once:
   `enroot import -o /shared/containers/pytorch.sqsh docker://nvcr.io#nvidia/pytorch:24.07-py3`
2. Point `examples/train-cpt.sbatch` at your entrypoint (it is a template — it
   exits with a clear message until the image and `train.py` exist).
3. For a no-container smoke test now: `./poc.sh test`
