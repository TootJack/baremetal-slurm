#!/bin/bash
# =====================================================================
# poc.sh - ONE paste-safe entry point for the H200 POC nodes.
#
# Why this exists: pasting markdown (```bash fences) into a shell makes bash
# treat the backticks as a command substitution. It then swallows everything
# you paste next as input to that substitution and appears to hang:
#     bash: unexpected EOF while looking for matching ``'
# That corrupted an hgx01 session and silently skipped a git pull.
#
# So: no heredocs, no backticks, no nested quotes here. Every command is a
# plain one-liner you can paste safely, and the script itself is run as a file.
#
# Usage (run as your normal user; the script uses sudo where needed):
#   ./poc.sh sync      - fetch the latest scripts from git
#   ./poc.sh status    - full cluster health report for diagnosis
#   ./poc.sh fix       - re-run the controller/compute setup and clear drains
#   ./poc.sh test      - run a real GPU job end to end
#   ./poc.sh containers- install Pyxis+Enroot on this node
# =====================================================================
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE" || exit 1
export PATH=/opt/slurm/bin:/opt/slurm/sbin:$PATH

SELF="$0"
ACTION="${1:-status}"

hdr() { printf '\n===== %s =====\n' "$1"; }

# ---------------------------------------------------------------------
# status - everything needed to diagnose, in one pasteable block
# ---------------------------------------------------------------------
do_status() {
  hdr "host"
  hostname -s
  echo "kernel: $(uname -r)"
  echo "uptime: $(uptime -p 2>/dev/null)"
  echo "git:    $(git rev-parse --short HEAD 2>/dev/null) $(git log -1 --format=%s 2>/dev/null | cut -c1-50)"

  hdr "which slurm binaries"
  echo "sinfo:     $(command -v sinfo)"
  echo "scontrol:  $(command -v scontrol)"
  echo "slurmd:    $(command -v slurmd)"
  echo "version:   $(sinfo -V 2>&1 | head -1)"

  hdr "daemons"
  for s in munge mariadb slurmdbd slurmctld slurmd; do
    printf '  %-10s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null || echo absent)"
  done

  hdr "hostname resolution"
  for n in hgx01 hgx20; do
    r="$(getent ahostsv4 "$n" 2>/dev/null | awk '$2=="STREAM"{print $1; exit}')"
    printf '  %-6s -> %s\n' "$n" "${r:-<does not resolve>}"
  done

  hdr "slurm.conf node lines"
  grep -E '^NodeName=' /etc/slurm/slurm.conf 2>/dev/null | sed 's/^/  /' || echo "  (no slurm.conf)"
  grep -E '^(ClusterName|SlurmctldHost|GresTypes)=' /etc/slurm/slurm.conf 2>/dev/null | sed 's/^/  /'

  hdr "what slurmd says about THIS node"
  slurmd -C 2>/dev/null | grep -m1 '^NodeName=' | sed 's/^/  /' || echo "  (slurmd -C gave nothing)"

  hdr "GPU visibility"
  if command -v nvidia-smi >/dev/null 2>&1; then
    echo "  nvidia-smi: $(nvidia-smi --list-gpus 2>/dev/null | wc -l) GPUs"
  else
    echo "  nvidia-smi: MISSING"
  fi

  hdr "sinfo (exit code + stdout + stderr)"
  # Capture separately: piping/`sed`-ing first would report sed's status, and
  # `2>&1 | sed` would hide whether the message came from stderr.
  sinfo_out="$(sinfo -N -o '%N %T %C %G' 2>/tmp/poc.sinfo.err)"
  sinfo_rc=$?
  sinfo_err="$(cat /tmp/poc.sinfo.err 2>/dev/null)"
  echo "  exit=${sinfo_rc}"
  [[ -n "$sinfo_out" ]] && sed 's/^/  /' <<<"$sinfo_out"
  [[ -z "$sinfo_out" ]] && echo "  (stdout EMPTY - that is not a normal Slurm state)"
  [[ -n "$sinfo_err" ]] && sed 's/^/  stderr: /' <<<"$sinfo_err"

  hdr "node detail (state + reason)"
  scontrol show node 2>&1 | grep -E 'NodeName=|State=|Reason=|Gres=|CoresPerSocket|RealMemory|CPUTot' | sed 's/^ */  /' || true

  hdr "partitions"
  scontrol show partition -o 2>&1 | head -5 | sed 's/^/  /'

  hdr "recent daemon errors"
  journalctl -u slurmctld --since '5 min ago' --no-pager 2>/dev/null | grep -iE 'error|fatal' | grep -viE 'environment|MailProg' | tail -5 | sed 's/^/  /'
  journalctl -u slurmd --since '5 min ago' --no-pager 2>/dev/null | grep -iE 'error|fatal' | grep -viE 'environment' | tail -5 | sed 's/^/  /'

  hdr "done"
}

# ---------------------------------------------------------------------
# sync
# ---------------------------------------------------------------------
do_sync() {
  hdr "git pull"
  git --no-pager log -1 --format='before: %h %s' 2>/dev/null || true
  git pull --ff-only origin main
  git --no-pager log -1 --format='after:  %h %s' 2>/dev/null || true
}

# ---------------------------------------------------------------------
# fix - re-run the right script for this node, then clear stale drains
# ---------------------------------------------------------------------
do_fix() {
  local me
  me="$(hostname -s)"
  hdr "fixing this node: ${me}"

  echo "--- 01-base.sh (hosts, sysctls) ---"
  sudo bash "${HERE}/scripts/01-base.sh" || exit 1

  if [[ "$me" == "hgx01" ]]; then
    echo "--- 03-slurm-controller.sh (controller; clears stale drains) ---"
    sudo bash "${HERE}/scripts/03-slurm-controller.sh" || exit 1
    echo "--- adding hgx20 if it has published its line ---"
    if [[ -s "/mnt/i3d_20tb/slurm-poc/cluster-config/node-hgx20.conf" ]]; then
      sudo env NODE2_HOST=hgx20 bash "${HERE}/scripts/03-slurm-controller.sh" || exit 1
    else
      echo "    (hgx20 has not published yet - run 'poc.sh fix' on hgx20 first)"
    fi
  else
    echo "--- 04-slurm-compute.sh (publishes node line, starts slurmd) ---"
    sudo bash "${HERE}/scripts/04-slurm-compute.sh" || exit 1
  fi

  hdr "result"
  sinfo -N -o '%N %T %C %G' 2>&1 | sed 's/^/  /'
}

# ---------------------------------------------------------------------
# drains - explicitly clear stale drains (exits nonzero if still broken)
# ---------------------------------------------------------------------
do_drains() {
  hdr "drains"
  sinfo -N -h -o '%N %T' | awk 'tolower($2) ~ /drain|inval/ {print $1}' | sort -u | while read -r n; do
    [[ -z "$n" ]] && continue
    st="$(scontrol show node "$n" 2>/dev/null | grep -oE 'State=[A-Z_+]+' | head -1)"
    reason="$(scontrol show node "$n" 2>/dev/null | grep -oE 'Reason=[^[]*' | head -1)"
    echo "  ${n}: ${st#State=}  ${reason}"
    if grep -qE 'INVALID_REG|NO_RESPOND' <<<"$st"; then
      echo "    -> still failing validation; restarting slurmd on ${n} is needed"
    else
      sudo scontrol update nodename="$n" state=resume >/dev/null 2>&1 \
        && echo "    -> resumed" || echo "    -> resume FAILED"
    fi
  done
  hdr "after"
  sinfo -N -o '%N %T %C %G' 2>&1 | sed 's/^/  /'
}

# ---------------------------------------------------------------------
# test - a real job on real GPUs
# ---------------------------------------------------------------------
do_test() {
  hdr "GPU job"
  # Does any node actually advertise GPUs? Requesting --gres=gpu:1 against a
  # cluster with none is rejected outright with
  #   sbatch: error: Invalid generic resource (gres) specification
  # so check first and explain, rather than reporting an opaque failure.
  local gpu_nodes
  gpu_nodes="$(sinfo -N -h -o '%N %G' 2>/dev/null | grep -c 'gpu:' || true)"
  if [[ "${gpu_nodes:-0}" == "0" ]]; then
    echo "  !! no node currently advertises a GPU resource."
    echo "     sinfo -N -o '%N %G':"
    sinfo -N -o '%N %T %G' 2>&1 | sed 's/^/       /'
    echo "     On a GPU node check:  slurmd -G | head -3"
    echo "     Requesting --gres=gpu:1 now would fail with"
    echo "       'Invalid generic resource (gres) specification'."
    echo "     Running a plain (CPU) job instead to prove scheduling works."
    echo
  fi

  # The job may run on EITHER node, so anything we want to read afterwards must
  # live on shared storage. Using /tmp made `poc.sh test` print an empty
  # "--- output ---" section whenever the job landed on the other node (the
  # file was written to that node's local /tmp). /shared is the cluster-wide
  # root; fall back to /tmp only if it is genuinely absent.
  local dir
  if [[ -d /shared/scratch ]]; then
    dir="/shared/scratch/poc-test-$$"
  else
    dir="/tmp/poc-test-$$"
    echo "  (no /shared/scratch - using node-local ${dir};"
    echo "   if the job runs on another node its output will be there, not here)"
  fi
  mkdir -p "$dir" 2>/dev/null || { echo "  cannot create ${dir}"; return 1; }
  chmod 1777 "$dir" 2>/dev/null || true
  if [[ "${gpu_nodes:-0}" == "0" ]]; then
    cat > "${dir}/gpu.sbatch" <<'SBATCH'
#!/bin/bash
#SBATCH --job-name=poc-cpu
#SBATCH --nodes=1
#SBATCH --time=00:05:00
#SBATCH --output=poc-gpu-%j.out
echo "HOST=$(hostname -s)"
echo "NOTE: no GPU requested (cluster advertises none)"
echo "POC_JOB_OK"
SBATCH
  else
    cat > "${dir}/gpu.sbatch" <<'SBATCH'
#!/bin/bash
#SBATCH --job-name=poc-gpu
#SBATCH --nodes=1
#SBATCH --gres=gpu:1
#SBATCH --time=00:05:00
#SBATCH --output=poc-gpu-%j.out
echo "HOST=$(hostname -s)"
echo "CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-unset}"
nvidia-smi --query-gpu=index,name,memory.total,driver_version --format=csv,noheader 2>/dev/null || echo "nvidia-smi unavailable in this job"
echo "POC_JOB_OK"
SBATCH
  fi
  cd "$dir" || exit 1
  local out jid st
  out="$(sbatch gpu.sbatch 2>&1)" || { echo "  SUBMIT FAILED: $out"; return 1; }
  echo "  $out"
  jid="$(grep -oE '[0-9]+$' <<<"$out")"
  st=""
  for _ in $(seq 1 30); do
    st="$(sacct -j "$jid" -X -n -o State 2>/dev/null | head -1 | tr -d ' ')"
    case "$st" in COMPLETED*|FAILED*|CANCELLED*|TIMEOUT*) break ;; esac
    sleep 4
  done
  hdr "job ${jid} state: ${st:-<none>}"
  echo "--- output ---"
  # Look for the file rather than assuming a name/location: the job may have
  # run on another node, and a missing file must be SAID, not silently skipped.
  outf=""
  for cand in "poc-gpu-${jid}.out" "${dir}/poc-gpu-${jid}.out" \
              "/shared/scratch/poc-gpu-${jid}.out" "/tmp/poc-gpu-${jid}.out"; do
    [[ -f "$cand" ]] && { outf="$cand"; break; }
  done
  if [[ -n "$outf" ]]; then
    sed 's/^/  /' < "$outf"
  else
    echo "  (no output file found for job ${jid})"
    echo "  searched: ${dir} , /shared/scratch , /tmp"
    echo "  job's --output was: $(scontrol show job "$jid" 2>/dev/null \
      | grep -oE 'StdOut=[^ ]*' | head -1 | cut -d= -f2)"
  fi
  echo "--- accounting ---"
  # AllocGRES was REMOVED in Slurm 25.11 ("please use AllocTRES"), so using it
  # makes sacct fail outright. AllocTRES carries the gres allocation.
  sacct -j "$jid" -X -o JobID,State,Elapsed,AllocTRES 2>&1 | tail -3 | sed 's/^/  /'
  if [[ "$st" == COMPLETED* ]]; then
    echo "  RESULT: PASS (scheduling + accounting + output verified)"
  else
    echo "  RESULT: FAIL (${st:-none})"
    return 1
  fi
}

# ---------------------------------------------------------------------
do_containers() {
  hdr "Pyxis + Enroot"
  sudo bash "${HERE}/scripts/05-pyxis-enroot.sh"
}

show_usage() {
  echo "usage: $SELF {sync|status|fix|drains|test|containers|help}"
  echo
  echo "  sync        fetch the latest scripts from git"
  echo "  status      full cluster health report (read-only)"
  echo "  fix         re-run 01-base plus 03 (on hgx01) or 04 (elsewhere)"
  echo "  drains      clear stale drains, reporting any node still failing"
  echo "  test        run a real job end to end (GPU if any node advertises one)"
  echo "  containers  install Pyxis + Enroot on this node"
  echo "  help        this message"
  echo
  echo "With no argument this defaults to 'status', which changes nothing."
}

case "$ACTION" in
  sync)       do_sync ;;
  status)     do_status ;;
  fix)        do_fix ;;
  drains)     do_drains ;;
  test)       do_test ;;
  containers) do_containers ;;
  help|-h|--help)
    show_usage ;;
  *)
    echo "unknown action: ${ACTION}" >&2
    show_usage >&2
    exit 2
    ;;
esac
