#!/bin/bash
# platform-cpu-boost.sh -- give the control plane extra CPUs for the boot
# window only, modelled on what ovn-kubernetes already does for OVS.
#
#   platform-cpu-boost.sh show
#   platform-cpu-boost.sh once      # compute and apply one boost, then exit
#   platform-cpu-boost.sh daemon    # apply, then track guaranteed pods and
#                                   # release on convergence  (the real mode)
#   platform-cpu-boost.sh release   # back to the reserved set
#
# =============================================================================
# DESIGN
#
# ovn-kubernetes solves this exact problem for ovs-vswitchd: it asks the
# kubelet for "all the CPUs which are not affine to guaranteed workloads" and
# pins OVS there, re-evaluating whenever that set changes. This applies the
# same idea to the rest of
# the control plane, which has no such mechanism.
#
# SOURCE OF TRUTH: /var/lib/kubelet/cpu_manager_state
#
#   {"policyName":"static","defaultCpuSet":"2-71,74-143,146-215,218-287",
#    "entries":{"<podUID>":{"<ctr>":"2-17"}}}
#
# `defaultCpuSet` is the shared pool: every CPU the CPU Manager has NOT handed
# out exclusively. When a Guaranteed dataplane pod is admitted, its CPUs leave
# defaultCpuSet and appear under `entries`. Reading this file is equivalent to
# the PodResource API query ovspinning makes, needs no gRPC client, and is the
# same state kubelet itself acts on. We only ever boost onto CPUs that are in
# defaultCpuSet at that moment.
#
# -----------------------------------------------------------------------------
# GOTCHA 1 -- GOMAXPROCS above ~32 makes Go SLOWER, not faster.
#
# Two things save us, and they are worth understanding because they point at
# runtime widening rather than booting wide:
#
#   * Go reads sched_getaffinity ONCE at process start to set GOMAXPROCS.
#     Widening a RUNNING process's affinity does NOT raise its GOMAXPROCS.
#     kubelet/crio/kube-apiserver/etcd keep GOMAXPROCS at the reserved count
#     and simply stop queueing behind each other -- the contention relief
#     without the Go memory-management penalty. Booting wide, by contrast,
#     WOULD set GOMAXPROCS to the wide count and walk straight into the cliff.
#   * MAX_PLATFORM_CPUS caps the set regardless, defaulting to 32, so even a
#     process that restarts mid-boost cannot come up with GOMAXPROCS > 32.
#
# This is why this script widens at runtime and why the cap exists. Do not
# raise MAX_PLATFORM_CPUS above 32 without measuring.
#
# -----------------------------------------------------------------------------
# GOTCHA 2 -- interrupt-sensitive Guaranteed dataplane pods must not be touched.
#
# Three protections, in order of strength:
#
#   1. Only CPUs in `defaultCpuSet` are ever used. A CPU exclusively assigned
#      to a Guaranteed pod is not in that set, so it is never a candidate.
#   2. Candidates are taken from the HIGH end of defaultCpuSet. The CPU
#      Manager's topology-aware allocator hands out low-numbered full
#      cores/sockets first (observed: a 16-CPU Guaranteed pod got 2-17), so
#      taking from the top minimises the chance of ever wanting a CPU a
#      dataplane pod is about to be given. This is a heuristic, not a
#      guarantee.
#   3. In daemon mode the state file is re-read every POLL_SEC. The moment
#      defaultCpuSet shrinks, the platform set is narrowed to match --
#      BEFORE the new pod's workload ramps up. Narrowing is the safe
#      direction: it needs only a cpuset write and cannot race.
#
# Residual risk, stated plainly: there is a window of up to POLL_SEC between
# the CPU Manager assigning a CPU and this script vacating it. ovspinning has
# the same race. For a node whose dataplane pods all start during the boot
# window, set EXCLUDE_CPUS to their intended cpuset and they are never
# touched at all -- that is the belt-and-braces option and the one to use if
# latency targets are hard.
#
# -----------------------------------------------------------------------------
# WHAT THIS DOES NOT TOUCH
#
#   * ovs-vswitchd / ovsdb-server. On 4.21.z+ ovn-kubernetes already manages
#     these dynamically and correctly. Interfering wedges ovsdb -- measured:
#     every CNI ADD failing with "database connection failed (Protocol
#     error)" and pod creation stopping dead. On releases where OVS dynamic
#     pinning is not working, OVS is stuck on the reserved set and this script
#     cannot help; fix the release instead.
#   * kubelet's reservedSystemCPUs. Node allocatable and the CPU Manager
#     state file stay untouched, so no Guaranteed pod is ever restarted.
# =============================================================================
set -u

CG=/sys/fs/cgroup
STATE_FILE=/var/lib/kubelet/cpu_manager_state
RUNSTATE=/run/platform-cpu-boost.state

MAX_PLATFORM_CPUS="${MAX_PLATFORM_CPUS:-32}"   # see GOTCHA 1; do not exceed 32
POLL_SEC="${POLL_SEC:-2}"                      # see GOTCHA 2; lower = safer
MAX_BOOST_SEC="${MAX_BOOST_SEC:-1800}"
EXCLUDE_CPUS="${EXCLUDE_CPUS:-}"               # never boost onto these
# Convergence: mean run-queue wait on the reserved CPUs below this, and the
# running-container count unchanged, for STABLE_CHECKS consecutive polls.
# NOT cpu.pressure -- PSI is unavailable by default on both 4.20 and 4.22.
RUNQ_WAIT_US="${RUNQ_WAIT_US:-150}"
STABLE_CHECKS="${STABLE_CHECKS:-5}"
CHECK_EVERY="${CHECK_EVERY:-15}"               # convergence check period

# Processes confined by an inherited systemd affinity mask. These need an
# explicit sched_setaffinity as well as a cpuset change -- a cpuset widen
# alone does not move them, because since kernel 5.17 the kernel intersects
# the new cpuset with the task's remembered user mask instead of replacing it.
MASKED_DAEMONS=(kubelet crio)
# Slices to widen. ovs.slice is deliberately absent (see above).
SLICES=(system.slice)

log() { printf '%s platform-cpu-boost: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

RESERVED=$(tr ' ' '\n' < /proc/cmdline | sed -n 's/^systemd.cpu_affinity=//p')
if [[ -z "$RESERVED" ]]; then
  log "ERROR: no systemd.cpu_affinity on /proc/cmdline -- this node is not"
  log "       workload-partitioned. Refusing (a later release would have to"
  log "       write an empty cpuset, which the kernel rejects with ENOSPC)."
  exit 3
fi

expand() { # "0-2,5" -> "0 1 2 5"
  local p a b out=() i x
  IFS=',' read -ra p <<< "${1:-}"
  for x in "${p[@]}"; do
    [[ -z "$x" ]] && continue
    if [[ "$x" == *-* ]]; then a=${x%-*}; b=${x#*-}
      for ((i=a;i<=b;i++)); do out+=("$i"); done
    else out+=("$x"); fi
  done
  ((${#out[@]})) && printf '%s\n' "${out[@]}" | sort -n -u
}

compact() { # "0 1 2 5" -> "0-2,5"
  awk 'BEGIN{first=1} {
        if (first) {s=$1; p=$1; first=0; next}
        if ($1==p+1) {p=$1; next}
        printf "%s%s", (o++?",":""), (s==p? s : s"-"p); s=$1; p=$1
      } END{ if(!first) printf "%s%s\n", (o++?",":""), (s==p? s : s"-"p) }'
}

# The kernel normalises cpuset strings ("0,1,2" is stored "0-2"), so every
# comparison must be set-wise. String equality silently matches nothing.
same_set() { [[ "$(expand "${1:-}" | tr '\n' ' ')" == "$(expand "${2:-}" | tr '\n' ' ')" ]]; }

default_cpuset() {
  [[ -r "$STATE_FILE" ]] || return 1
  sed -n 's/.*"defaultCpuSet":"\([^"]*\)".*/\1/p' "$STATE_FILE"
}

numa_of() { cat "/sys/devices/system/cpu/cpu$1/topology/physical_package_id" 2>/dev/null || echo 0; }

# Build the boost set: reserved, plus CPUs drawn from the HIGH end of
# defaultCpuSet, NUMA-balanced, excluding EXCLUDE_CPUS, capped at
# MAX_PLATFORM_CPUS total.
compute_target() {
  local shared excl n_res want
  shared="$(default_cpuset)" || { log "cannot read $STATE_FILE"; return 1; }
  [[ -n "$shared" ]] || { log "defaultCpuSet empty -- every CPU is exclusively assigned; not boosting"; return 1; }

  mapfile -t excl < <(expand "${EXCLUDE_CPUS}"; expand "$RESERVED")
  declare -A skip=(); for c in "${excl[@]}"; do skip[$c]=1; done

  n_res=$(expand "$RESERVED" | wc -l)
  want=$(( MAX_PLATFORM_CPUS - n_res ))
  (( want > 0 )) || { log "reserved set already >= MAX_PLATFORM_CPUS; not boosting"; return 1; }

  # Candidates high-to-low, interleaved across NUMA nodes so the boost is
  # balanced rather than piling onto one socket.
  local -A bynode=()
  while read -r c; do
    [[ -n "${skip[$c]:-}" ]] && continue
    bynode[$(numa_of "$c")]+="$c "
  done < <(expand "$shared" | sort -rn)

  local picked=() nodes=("${!bynode[@]}") progressed=1
  while (( ${#picked[@]} < want )) && (( progressed )); do
    progressed=0
    for nd in "${nodes[@]}"; do
      (( ${#picked[@]} < want )) || break
      local arr=(${bynode[$nd]})
      (( ${#arr[@]} )) || continue
      picked+=("${arr[0]}")
      bynode[$nd]="${arr[*]:1}"
      progressed=1
    done
  done

  { expand "$RESERVED"; printf '%s\n' "${picked[@]}"; } | sort -n -u | compact
}

apply_set() { # apply_set <cpuset>
  local target="$1" s f cur n=0 w=0 failed=0 pid prev
  prev="$(cat "$RUNSTATE" 2>/dev/null || echo "$RESERVED")"

  # 1. Slice cpusets FIRST -- taskset is clamped to the cpuset, so setting the
  #    mask before the cpuset just yields the intersection.
  for s in "${SLICES[@]}"; do
    [[ -d "$CG/$s" ]] || continue
    systemctl set-property --runtime "$s" "AllowedCPUs=$target" 2>/dev/null || \
      log "WARN: set-property failed on $s"
  done

  # 2. Management pod cgroups -- where kube-apiserver, etcd, ovn-controller
  #    live. These carry no inherited user mask, so a cpuset write alone moves
  #    them. Only touch cgroups currently at the reserved set or the previous
  #    target, so CPU Manager exclusive allocations are never rewritten.
  while IFS= read -r f; do
    # NOT $(< "$f" 2>/dev/null): adding a redirection defeats bash's special
    # $(< file) form, turning it into a command substitution around a null
    # command that ALWAYS yields the empty string. That silently skipped every
    # cgroup -- the boost logged "0 pod cgroups" on every run and never
    # widened kube-apiserver or etcd.
    read -r cur < "$f" 2>/dev/null || continue
    [[ -n "$cur" ]] || continue
    if same_set "$cur" "$RESERVED" || same_set "$cur" "$prev"; then
      if echo "$target" > "$f" 2>/dev/null; then ((n++)); else
        ((failed++)); (( failed <= 3 )) && log "WRITE FAILED: ${f#$CG/} (cur=$cur)"
      fi
    fi
  done < <(find "$CG/kubepods.slice" -name cpuset.cpus 2>/dev/null)

  # 3. User masks for the systemd-confined daemons.
  for s in "${MASKED_DAEMONS[@]}"; do
    while read -r pid; do
      [[ -n "$pid" ]] || continue
      taskset -apc "$target" "$pid" >/dev/null 2>&1 && ((w++))
    done < <(pgrep -x "$s" 2>/dev/null)
  done

  log "applied [$target]: $n pod cgroups, $w daemons$( ((failed)) && echo ", $failed FAILED")"
  if same_set "$target" "$RESERVED"; then rm -f "$RUNSTATE"; else echo "$target" > "$RUNSTATE"; fi
}

cmd_show() {
  local shared tgt
  shared="$(default_cpuset || echo '<unreadable>')"
  echo "reserved (systemd.cpu_affinity): $RESERVED  ($(expand "$RESERVED" | wc -l) CPUs)"
  echo "defaultCpuSet (not held by Guaranteed pods): $shared"
  echo "Guaranteed exclusive assignments: $(grep -o '"entries":{[^}]*}' "$STATE_FILE" 2>/dev/null | grep -c ':' || true)"
  echo "MAX_PLATFORM_CPUS=$MAX_PLATFORM_CPUS  EXCLUDE_CPUS=${EXCLUDE_CPUS:-<none>}"
  tgt="$(compute_target)" && echo "would boost to: $tgt  ($(expand "$tgt" | wc -l) CPUs)"
  echo "currently applied: $(cat "$RUNSTATE" 2>/dev/null || echo '<reserved>')"
  printf '%-22s %s\n' DAEMON CPUS_ALLOWED
  for d in kube-apiserver etcd kubelet crio ovn-controller ovs-vswitchd; do
    local p; p=$(pgrep -x "$d" 2>/dev/null | head -1) || true
    [[ -n "${p:-}" ]] && printf '%-22s %s\n' "$d" \
      "$(awk '/Cpus_allowed_list/{print $2}' "/proc/$p/status" 2>/dev/null)"
  done
}

# Mean run-queue wait in microseconds across the reserved CPUs, from
# /proc/schedstat run_delay/pcount. Used instead of cpu.pressure because PSI
# is unavailable by default on both 4.20 and 4.22.
runq_wait_us() {
  local -A rd0 pc0
  local c f dd=0 dp=0
  while read -r c; do
    read -r -a f <<< "$(grep -m1 "^cpu$c " /proc/schedstat)"
    rd0[$c]=${f[8]}; pc0[$c]=${f[9]}
  done < <(expand "$RESERVED")
  sleep 1
  while read -r c; do
    read -r -a f <<< "$(grep -m1 "^cpu$c " /proc/schedstat)"
    dd=$(( dd + ${f[8]} - ${rd0[$c]} )); dp=$(( dp + ${f[9]} - ${pc0[$c]} ))
  done < <(expand "$RESERVED")
  (( dp > 0 )) && echo $(( dd / dp / 1000 )) || echo 0
}

running_containers() {
  crictl --runtime-endpoint unix:///var/run/crio/crio.sock ps 2>/dev/null | awk 'NR>1' | wc -l
}

# systemd's After=kubelet.service only guarantees kubelet's process has
# exec'd, NOT that it has initialised the CPU Manager and written its state
# file. Measured: the daemon started 0 s after kubelet, found no state file,
# logged "nothing to boost" and exited -- so the boost silently never applied
# for an entire test boot. Wait for the file to exist AND parse before
# deciding there is nothing to do.
wait_for_cpu_manager_state() {
  local waited=0 limit="${STATE_WAIT_SEC:-120}"
  while (( waited < limit )); do
    if [[ -r "$STATE_FILE" ]] && [[ -n "$(default_cpuset)" ]]; then
      (( waited )) && log "cpu_manager_state ready after ${waited}s"
      return 0
    fi
    sleep 2; waited=$(( waited + 2 ))
  done
  log "ERROR: $STATE_FILE still unreadable after ${limit}s -- not boosting"
  return 1
}

cmd_daemon() {
  local deadline=$(( ${EPOCHSECONDS:-0} + MAX_BOOST_SEC ))
  local tgt cur last_shared="" shared stable=0 last_ctrs=-1 ctrs wait_us next_check=0
  wait_for_cpu_manager_state || exit 0
  tgt="$(compute_target)" || { log "nothing to boost"; exit 0; }
  apply_set "$tgt"
  log "boost active, cap=${MAX_PLATFORM_CPUS}, tracking Guaranteed pods every ${POLL_SEC}s"

  while (( EPOCHSECONDS < deadline )); do
    sleep "$POLL_SEC"
    # --- GOTCHA 2: react to Guaranteed pod churn before anything else ---
    shared="$(default_cpuset)" || continue
    if [[ "$shared" != "$last_shared" ]]; then
      last_shared="$shared"
      tgt="$(compute_target)" || { log "shared pool exhausted; releasing"; break; }
      cur="$(cat "$RUNSTATE" 2>/dev/null || echo "$RESERVED")"
      if ! same_set "$tgt" "$cur"; then
        log "Guaranteed-pod set changed -> retargeting to [$tgt]"
        apply_set "$tgt"
      fi
    fi
    # --- convergence check, less often ---
    (( EPOCHSECONDS < next_check )) && continue
    next_check=$(( EPOCHSECONDS + CHECK_EVERY ))
    # Re-apply to pick up management pod cgroups created SINCE the last pass.
    # At boot the boost lands ~2 s after kubelet, when kubepods.slice is still
    # empty -- measured: "applied [...]: 0 pod cgroups, 1 daemons". The
    # control-plane static pods (kube-apiserver, etcd, ovn-controller) are
    # created later and would otherwise keep the narrow cpuset for the whole
    # boost window, which is most of the benefit missed. apply_set only
    # rewrites cgroups sitting at the reserved set or the previous target, so
    # repeating it is idempotent and never touches CPU Manager allocations.
    cur="$(cat "$RUNSTATE" 2>/dev/null || echo "$RESERVED")"
    same_set "$cur" "$RESERVED" || apply_set "$cur"
    wait_us="$(runq_wait_us)"; ctrs="$(running_containers)"
    if (( wait_us < RUNQ_WAIT_US )) && (( ctrs > 0 )) && (( ctrs == last_ctrs )); then
      ((stable++))
      log "converged ${stable}/${STABLE_CHECKS} (runq_wait=${wait_us}us ctrs=${ctrs})"
      (( stable >= STABLE_CHECKS )) && break
    else
      (( stable )) && log "convergence reset (runq_wait=${wait_us}us ctrs=${ctrs})"
      stable=0
    fi
    last_ctrs="$ctrs"
  done
  log "releasing boost"
  apply_set "$RESERVED"
}

case "${1:-show}" in
  show)    cmd_show ;;
  once)    t="$(compute_target)" && apply_set "$t"; cmd_show ;;
  daemon)  cmd_daemon ;;
  release) apply_set "$RESERVED"; cmd_show ;;
  *) echo "usage: $0 {show|once|daemon|release}" >&2; exit 2 ;;
esac
