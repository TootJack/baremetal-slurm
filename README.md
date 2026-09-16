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
poc.sh                     ONE paste-safe entry point: sync|status|fix|drains|test|containers
                           Use this rather than pasting commands from this README.
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

**Run `./poc.sh`, do not paste commands from this file.** Pasting a markdown
fence into a shell makes bash treat the ``` ``` ``` as a command
substitution; it then swallows everything you paste next and appears to hang:

```
bash: unexpected EOF while looking for matching ``'
```

That corrupted an hgx01 session and silently skipped a `git pull`. `poc.sh`
takes one plain word as an argument — nothing to paste wrongly.

**The order matters and is not symmetric.** Node 2 announces itself *before*
the controller is told about it — that removed a deadlock where the controller
needed node 2's hardware (which only node 2 can measure) while node 2 waited
for a `slurm.conf` that mentioned it.

```
# --- on hgx01 (10.100.18.5) ---
cd ~/hengjiantmp/i3d-slurm-poc
./poc.sh sync                 # fetch the latest scripts
./poc.sh fix                  # 01-base + 03 (controller) + resumes stale drains

# --- on hgx20 (10.100.18.8) ---
cd ~/hengjiantmp/i3d-slurm-poc
./poc.sh sync
./poc.sh fix                  # 01-base + 04 (publishes its own node line)

# --- back on hgx01: add node 2 from the line IT published ---
./poc.sh fix                  # 03 now sees node-hgx20.conf and includes it

# --- back on hgx20: the conf now mentions it, so slurmd starts ---
./poc.sh fix

# --- either node ---
./poc.sh status               # paste this whole block back for diagnosis
./poc.sh test                 # a real job end to end
./poc.sh containers           # Pyxis + Enroot, on BOTH nodes
```

`poc.sh` actions:

| action | what it does |
|---|---|
| `sync` | `git pull --ff-only origin main` |
| `status` | read-only health report: binaries, daemons, hosts, `slurmd -C`, GRES, `sinfo` exit code, node `Reason=`, partition list, recent daemon errors |
| `fix` | `01-base.sh`, then `03` (on hgx01, including a second pass with `NODE2_HOST`) or `04` |
| `drains` | clears stale drains; reports any node still failing validation |
| `test` | submits a real job, waits for a terminal state, prints output + accounting |
| `containers` | `05-pyxis-enroot.sh` |
| `help` | usage |

With no argument it runs `status`, which changes nothing.

> **`verify-hosts-resolution.sh` is not optional on the real nodes.** It is the
> regression test for bugs 6-7. If it fails, `hgx20` cannot reach the
> controller regardless of anything else, and `sinfo` on `hgx20` will say
> `Unable to contact slurm controller (connect failure)`.

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
| 6 | `/etc/hosts`: Debian's `127.0.1.1 <hostname>` line | own name resolves to **loopback** → `SlurmctldHost=hgx01` binds loopback → other nodes get `Unable to contact slurm controller (connect failure)` | delete the loopback line for cluster names before writing the LAN mapping |
| 7 | `SlurmctldHost=<name>(<addr>)` pinned an address | replies came from a different address than clients used → `Socket timed out on send/recv operation` | use the bare hostname; let `/etc/hosts` resolve it on every node |
| 8 | `systemctl enable --now slurmd/slurmctld` on a re-run | daemon kept the **previous** `slurm.conf` → `Node X appears to have a different slurm.conf than the slurmctld`, node stuck `inval` | `enable` + `restart`, so both daemons parse the same file |
| 9 | state dir cleared partially (left `clustername`, dropped `assoc_usage`) | `fatal: No Assoc usage file (/var/spool/slurmctld/assoc_usage) to recover` | delete the **whole** dir, then verify it is empty |
| 10 | `detect_node "$NODE2_HOST"` ran `slurmd -C` **locally** | node 2's stanza carried node 1's CPU/RAM/GPU counts → `inval` (INVALID_REG) or failed registration | node 2 publishes its own line to shared storage; the controller **reads** it and refuses to guess |
| 11 | documented order was a deadlock | 03 wrote a conf without node 2; 04 installed it verbatim → `fatal: Unable to determine this slurmd's NodeName`; only *then* did the docs say to add node 2 | 04 publishes its node line and stops; then 03 adds node 2; then 04 starts slurmd. Order documented as asymmetric + idempotent |
| 12 | `sinfo ... \|\| sinfo` as the last command under `set -e` | both fail while slurmctld restarts → **03 exits 1 despite succeeding** | report-only, never fatal; `sinfo` retried with a hint |
| 13 | `resolve_shared_root` sourced the conf file over `SHARED_ROOT` | an explicit `SHARED_ROOT=` override was silently ignored (and untestable) | environment wins over the file |

Bugs 6-13 are the multi-node blockers: with the full stack installed, `hgx01`
showed the node as `inval` and `hgx20` could not reach the controller at all.
All are fixed and locked down by `test/verify-hosts-resolution.sh` (11
assertions), `test/verify-multinode-bootstrap.sh` (11),
`test/verify-two-node-flow.sh` and `test/verify-03-node2.sh` (refuses to
invent, then succeeds), plus `test/verify-end-to-end.sh` (clean run → node
`idle` → submitted job `COMPLETED` → `sacct` reports it).

> **On the real nodes, run `01-base.sh` on BOTH first.** It must print
> `hostname resolution OK (<node> sees both nodes)`; if it prints
> `!! ... resolves to '127.0.1.1'` then Slurm will never reach the controller.

> **If a name resolves to the wrong address**, the cause is usually a stray or
> duplicate `/etc/hosts` line outside the managed block. nsswitch is
> `files dns`, and within `files` the **first** match wins — so such a line
> silently beats the block and still resolves "successfully", just wrongly.
> `01-base.sh` now removes those, printing
> `removing stray/duplicate mapping(s) for <name>`. To see the sources:

```bash
# every /etc/hosts line mentioning the cluster names + what each resolves to
sudo bash -c 'source scripts/lib.sh && show_cluster_hosts_sources'
```

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

## Vendor-stack landmines (found on hgx01)

Removing the vendor Slurm leaves configuration pointing at the **deleted**
tree. These bit us in sequence and are now handled automatically.

### 1. `munge` fails: vendor `OPTIONS` overrides the key path

hgx01 error:
```
Job for munge.service failed because the control process exited with error code.
Process: ExecStart=/usr/sbin/munged --key-file=/cm/shared/apps/slurm/var/munge/keys/munge.key
```

The Ubuntu munge unit is:
```
EnvironmentFile=-/etc/default/munge
ExecStart=/usr/sbin/munged $OPTIONS
```

The vendor stack wrote `OPTIONS="--key-file=/cm/shared/apps/slurm/var/munge/keys/munge.key"`
into `/etc/default/munge`. That path belongs to the vendor tree we removed,
so `munged` exits 1 and **the whole cluster stops authenticating**.

Fix: `03`/`04` rewrite `/etc/default/munge` to
`OPTIONS="--key-file=/etc/munge/munge.key"` and clear any
`munge.service.d/*.conf` drop-ins.

*Reproduced and verified:* vendor `OPTIONS` → `failed`; after fix →
`active` + `STATUS: Success`.

### 2. Stale systemd drop-ins for slurmctld/slurmdbd

`/etc/systemd/system/slurm{ctld,dbd}.service.d/override.conf` silently
overrides the units we install. `slurm-source.sh` now clears them.

### 3. The vendor tree is `/cm/shared/apps/...`

Worth knowing when auditing leftovers:
```bash
grep -rl "/cm/" /etc/slurm /etc/default /etc/systemd/system 2>/dev/null
```

### Verified recovery from a fully tainted state

With the vendor `OPTIONS` **and** a stale drop-in planted, `03` completes
`EXIT=0`, prints `vendor munge OPTIONS found … munge OK`, and all five
daemons end active with the node `idle`.

## The munge vendor trap — SOLVED (definitively)

hgx01 kept failing even after rewriting `/etc/default/munge`:

```
Process: ExecStart=/usr/sbin/munged --key-file=/cm/shared/apps/slurm/var/munge/keys/munge.key
```

The vendor `--key-file` survived every attempt to neutralise it via
`/etc/default/munge`, because **we could not identify which layer injected
it**. Guessing was the wrong approach.

### Fix: replace the unit outright

`03`/`04` now write a complete `/etc/systemd/system/munge.service` that
**has no `EnvironmentFile` and does not expand `$OPTIONS`**:

```ini
ExecStart=/usr/sbin/munged --key-file=/etc/munge/munge.key
```

Nothing the vendor left behind can override a hardcoded ExecStart.

*Verified against a hostile state:* `OPTIONS` in `/etc/default/munge`
**plus** a drop-in injecting `Environment=OPTIONS=...` →
before: `failed` (effective `ExecStart=... $OPTIONS`);
after: `active`, `STATUS: Success`.

### Also fixed while proving it

| Bug | Symptom |
|---|---|
| bare `systemctl restart munge` under `set -e` | **aborted the script before diagnostics could print** — which is why the failure looked silent |
| `clustername` compared to raw file contents | Slurm stores `i3dpoc\|1632`, so the guard archived state every run → `slurmctld activating` |

Verified end state with the vendor config planted:

```
munge active | mariadb active | slurmdbd active | slurmctld active | slurmd active
[node] idle
EXIT=0
```

## GPU GRES CONFIRMED on the H200 nodes ✅

```
hgx01: slurmd -C → NodeName=hgx01 ... Gres=gpu:nvidia_h200:8
                   Found gpu:nvidia_h200:8 with Autodetect=nvml
hgx20: slurmd -C → ... Gres=gpu:nvidia_h200:8
```

`HAVE_NVML 1` at build time **and** working NVML at runtime on both nodes.
Jobs requesting `--gres=gpu` will schedule.

## Remaining fixes from the hgx01/hgx20 run

### 1. `inval` state: `fatal: CLUSTER ID MISMATCH`

The node sat in `inval` because:

```
slurmctld has been started with "ClusterID=3744" from the state files,
but the DBD thinks it should be "1540".
```

`RESET_ACCT_DB=1` mints a **new ClusterID**, but the old `/var/spool/slurmctld`
survives. My guard only compared `ClusterName`, missing the ID. Now:

- the file is parsed as `<ClusterName>|<ClusterID>` (not compared raw)
- `RESET_ACCT_DB=1` **also clears the state dir**, so the ID matches

*Verified:* stale state + fresh DB → `slurmd`/`slurmctld` start, node `idle`.

### 2. Bare `sinfo`/`slurmd` resolved to the wrong Slurm

On hgx20, bare `slurmd -C` printed **no Gres** and `sinfo` failed with
"Unable to contact slurm controller" — while `export PATH=/opt/slurm/sbin`
made both work. Cause: `/etc/profile.d` only loads for **login** shells, so
interactive `sudo` sessions fell back to the distro 21.08 client, which
cannot talk to a 25.11 daemon (protocol mismatch).

Fix in `slurm-source.sh`:
- symlink every `/opt/slurm/{bin,sbin}/*` into `/usr/local/bin`
  (precedes `/usr/bin` in the default PATH, and works under `sudo`)
- remove the distro `slurm*` packages that shadow it

### 3. `enroot import` failed as `nobody`

```
mkdir: cannot create directory '/tmp/enroot-data/65534': Permission denied
FATAL ERROR: Could not read $HOME, use -recovery-path
```

`nobody` (uid 65534) has no home. `05` now imports as a real user
(`mluser1`/`ubuntu`/`slurmadmin`) and pre-creates the enroot dirs
world-writable. Import as root is the fallback, and the resulting `.sqsh`
is verified readable with `unsquashfs -l`.

## Next

```bash
git pull    # both nodes
# hgx01: reset DB + state together, now a single flag
RESET_ACCT_DB=1 sudo -E SLURM_MODE=source bash scripts/03-slurm-controller.sh
NODE2_HOST=hgx20 RESET_ACCT_DB=1 sudo -E SLURM_MODE=source bash scripts/03-slurm-controller.sh
# hgx20
sudo -E SLURM_MODE=source bash scripts/04-slurm-compute.sh
# both
sudo bash scripts/05-pyxis-enroot.sh
sinfo -N -o "%N %T %C %G"     # expect: hgx01 idle, hgx20 idle, gpu:nvidia_h200:8
```
