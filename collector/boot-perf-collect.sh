#!/bin/bash
# boot-perf-collect.sh -- early-boot performance collector for SNO nodes.
#
# Runs from a systemd unit started BEFORE crio/kubelet, so it captures the
# whole pod bring-up window including the part that SSH-based collection
# misses.
#
# Design constraints, driven by what went wrong with the manual collector:
#   * It must not run on the reserved CPUs. The reserved pool is the thing
#     under investigation; a collector living there gets starved exactly when
#     the data matters (observed: a 9 s loop stretching to 586 s).
#   * The hot loop must not fork. `top`/`ps` walk 7000+ tasks and cost more
#     than the signal is worth at this pod density.
#   * Output goes to tmpfs first. The disk is a contended resource during
#     boot; writing samples to it perturbs the measurement.
#
# Output: /run/boot-perf/<boot-id>/ during the run, flushed to
#         /var/log/boot-perf/<boot-id>/ on exit (readable via
#         `oc adm node-logs <node> --path=boot-perf/...`).

set -u

INTERVAL="${BOOT_PERF_INTERVAL:-1}"          # fast-loop period, seconds
SLOW_EVERY="${BOOT_PERF_SLOW_EVERY:-15}"     # slow-loop period, seconds
DURATION="${BOOT_PERF_DURATION:-2700}"       # total run time, seconds
RUNDIR_BASE="${BOOT_PERF_RUNDIR:-/run/boot-perf}"
OUTDIR_BASE="${BOOT_PERF_OUTDIR:-/var/log/boot-perf}"
KEEP_BOOTS="${BOOT_PERF_KEEP:-5}"

BOOT_ID="$(< /proc/sys/kernel/random/boot_id)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RUNDIR="${RUNDIR_BASE}/${STAMP}-${BOOT_ID:0:8}"
OUTDIR="${OUTDIR_BASE}/${STAMP}-${BOOT_ID:0:8}"
mkdir -p "$RUNDIR" || exit 1

# ---------------------------------------------------------------------------
# Step off the reserved CPUs.
#
# Take the two highest non-reserved CPUs: during boot they are idle (measured:
# isolated pool at 12-15% while the reserved pool sat at 93%), and they are
# the last CPUs a NUMA-aware CNF placement would hand out.
#
# Do NOT derive the isolated set from /sys/devices/system/cpu/isolated. That
# file reflects only `domain` isolation, and PerformanceProfile generates
# `isolcpus=managed_irq,<list>` without it -- verified empty on a 288-CPU
# 4.20 SNO node whose isolated pool is 284 CPUs. Trusting it there would
# silently leave the collector on the reserved CPUs, i.e. exactly the
# starvation this pinning exists to avoid.
#
# systemd.cpu_affinity on the kernel command line is the authoritative
# reserved set on a workload-partitioned node; everything else is isolated.
# ---------------------------------------------------------------------------
expand_cpus() { # "0,70-72" -> newline-separated ints
  local p a b i
  IFS=',' read -ra p <<< "$1"
  for x in "${p[@]}"; do
    [[ -z "$x" ]] && continue
    if [[ "$x" == *-* ]]; then a=${x%-*}; b=${x#*-}
      for ((i=a;i<=b;i++)); do echo "$i"; done
    else echo "$x"; fi
  done
}

pick_collector_cpus() {
  local res ncpu iso
  res="$(tr ' ' '\n' < /proc/cmdline | sed -n 's/^systemd.cpu_affinity=//p')"
  [[ -n "$res" ]] || res="$(< /sys/fs/cgroup/system.slice/cpuset.cpus.effective)"
  [[ -n "$res" ]] || return 1
  ncpu=$(nproc --all 2>/dev/null) || return 1
  mapfile -t iso < <(
    comm -23 <(seq 0 $((ncpu-1)) | sort) <(expand_cpus "$res" | sort) | sort -n)
  (( ${#iso[@]} >= 2 )) || return 1
  echo "${iso[-2]},${iso[-1]}"
}

COLLECTOR_CPUS="${BOOT_PERF_CPUS:-$(pick_collector_cpus)}"
if [[ -n "${COLLECTOR_CPUS:-}" ]]; then
  taskset -pc "$COLLECTOR_CPUS" $$ >/dev/null 2>&1 \
    && echo "collector pinned to CPUs ${COLLECTOR_CPUS}" >&2
fi
renice -n 10 -p $$ >/dev/null 2>&1
# Record the affinity actually in force, read back from the kernel. Reporting
# the requested value instead would claim success even when taskset failed --
# and "the collector is not on the reserved pool" is the property the whole
# measurement depends on, so it must be verifiable from the collection alone.
COLLECTOR_CPUS_ACTUAL="$(awk '/Cpus_allowed_list/{print $2}' "/proc/$$/status" 2>/dev/null)"

# ---------------------------------------------------------------------------
# Static context, captured once. Topology is the first thing anyone analysing
# this data needs and the first thing the manual logs were missing.
# ---------------------------------------------------------------------------
{
  echo "### boot_id=${BOOT_ID} stamp=${STAMP}"
  echo "### cmdline"; cat /proc/cmdline
  echo "### lscpu -e"; lscpu -e 2>/dev/null
  echo "### lscpu"; lscpu 2>/dev/null
  echo "### isolated"; cat /sys/devices/system/cpu/isolated 2>/dev/null
  echo "### nohz_full"; cat /sys/devices/system/cpu/nohz_full 2>/dev/null
  echo "### collector requested CPUs: ${COLLECTOR_CPUS:-<none>}"
  echo "### collector ACTUAL Cpus_allowed_list: ${COLLECTOR_CPUS_ACTUAL:-<unknown>}"
  echo "### reserved set (for comparison): $(tr ' ' '\n' < /proc/cmdline | sed -n 's/^systemd.cpu_affinity=//p')"
  echo "### PSI available: $([[ -r /proc/pressure/cpu ]] && echo yes || echo 'NO (psi=0 on cmdline?)')"
  echo "### schedstat: $(head -1 /proc/schedstat 2>/dev/null)"
  echo "### systemd CPUAffinity"
  systemctl show -p CPUAffinity 2>/dev/null
  echo "### kubelet reservedSystemCPUs"
  grep -hoE '"reservedSystemCPUs":[^,]*' /etc/kubernetes/kubelet.conf 2>/dev/null
  echo "### crio workload partitioning"
  cat /etc/crio/crio.conf.d/*workload* 2>/dev/null
  echo "### openshift-workload-pinning"
  cat /etc/kubernetes/openshift-workload-pinning 2>/dev/null
  echo "### irqbalance banned"
  cat /etc/sysconfig/irqbalance 2>/dev/null | grep -i ban
  echo "### block devices"; lsblk -o NAME,ROTA,SIZE,TYPE,MOUNTPOINTS 2>/dev/null
  echo "### memory"; head -5 /proc/meminfo
} > "${RUNDIR}/00-context.txt" 2>&1

# ---------------------------------------------------------------------------
# sadc: binary sysstat records at 1 s. Cheaper and far more regular than
# shelling out to mpstat/iostat/vmstat, and `sar -f` can replay any view later.
# ---------------------------------------------------------------------------
SADC=""
for p in /usr/lib64/sa/sadc /usr/lib/sa/sadc; do [[ -x "$p" ]] && SADC="$p"; done
if [[ -n "$SADC" ]]; then
  "$SADC" -S ALL "$INTERVAL" "$((DURATION / INTERVAL))" "${RUNDIR}/sa.bin" &
  SADC_PID=$!
fi

# ---------------------------------------------------------------------------
# Fast loop: builtins only, no subshells, no forks.
#
# /proc/schedstat is the key file. Per-CPU field 9 (run_delay, ns) is the
# cumulative time runnable tasks spent waiting for that CPU, and field 10
# (pcount) is the number of times they were scheduled. delta(run_delay) /
# delta(pcount) is the mean run-queue wait -- the direct measurement of
# "the reserved pool is oversubscribed" that %busy can only imply.
#
# PSI is the second key signal. With workload partitioning the reserved pool
# is constrained by CPU *affinity*, not by a CFS quota, so cpu.stat's
# nr_throttled stays at 0 even at 100% saturation. Anyone looking for
# throttling counters will find nothing and wrongly conclude CPU is fine.
# cpu.pressure does not have that blind spot.
# ---------------------------------------------------------------------------
CG=/sys/fs/cgroup
# PSI is frequently UNAVAILABLE on a PerformanceProfile-tuned node: the
# low-latency TuneD profile puts psi=0 on the kernel command line, so
# /proc/pressure does not exist and no cgroup has a cpu.pressure file
# (verified on a 4.20 SNO node). These paths are therefore best-effort --
# emit() skips what is missing -- and /proc/schedstat run_delay, collected
# above and always present, is the primary saturation signal.
PSI_PATHS=(
  /proc/pressure/cpu /proc/pressure/io /proc/pressure/memory
  "$CG/system.slice/cpu.pressure" "$CG/system.slice/io.pressure"
  "$CG/kubepods.slice/cpu.pressure" "$CG/kubepods.slice/io.pressure"
)
CPUSTAT_PATHS=(
  "$CG/system.slice/cpu.stat"
  "$CG/kubepods.slice/cpu.stat"
  "$CG/ovs.slice/cpu.stat"
  "$CG/system.slice/crio.service/cpu.stat"
  "$CG/system.slice/kubelet.service/cpu.stat"
  "$CG/ovs.slice/ovs-vswitchd.service/cpu.stat"
)
# ovs.slice is a TOP-LEVEL slice, not a child of system.slice -- ovs-vswitchd
# was measured at 0.75-1.22 CPUs, so missing it loses a real consumer.
CPUSET_PATHS=(
  "$CG/system.slice/cpuset.cpus.effective"
  "$CG/kubepods.slice/cpuset.cpus.effective"
  "$CG/ovs.slice/cpuset.cpus.effective"
)

# ---------------------------------------------------------------------------
# Fast loop.
#
# One awk pass per sample over every file, instead of a bash read/printf loop
# per line. The bash version cost 0.57 CPUs on a 288-CPU node: ~600 forks-free
# but interpreted printf calls per second, which at 1 Hz is simply too much
# shell. awk does the same tagging and filtering in C with a single fork, and
# scales with CPU count far better -- the whole point is that this must not
# become a consumer worth measuring.
#
# Tagging is by FILENAME, so adding a path to one of the arrays below is all
# that is needed; missing files are skipped silently (nodes differ: ovs.slice
# does not exist without a PerformanceProfile, and /proc/pressure/* does not
# exist unless psi=1).
# ---------------------------------------------------------------------------
fast() {
  local out="${RUNDIR}/fast.txt" l deadline p
  local -a files=()
  for p in /proc/stat /proc/schedstat /proc/diskstats /proc/meminfo \
           /proc/loadavg /proc/uptime \
           "${PSI_PATHS[@]}" "${CPUSTAT_PATHS[@]}" "${CPUSET_PATHS[@]}"; do
    [[ -r "$p" ]] && files+=("$p")
  done
  exec 3>>"$out"
  # Fork-free sleep: read with a timeout on a pipe that never produces data.
  exec {napfd}<> <(:)
  deadline=$(( ${EPOCHSECONDS:-0} + DURATION ))
  while (( EPOCHSECONDS < deadline )); do
    awk -v ts="$EPOCHREALTIME" '
      FNR==1 {
        f = FILENAME
        tag = (f=="/proc/stat")      ? "STAT" :
              (f=="/proc/schedstat") ? "SCHED" :
              (f=="/proc/diskstats") ? "DISK" :
              (f=="/proc/meminfo")   ? "MEM" :
              (f=="/proc/loadavg")   ? "LOAD" :
              (f=="/proc/uptime")    ? "UP" :
              (f ~ /pressure$/)      ? "PSI:" f :
              (f ~ /cpu\.stat$/)     ? "CPUSTAT:" f :
              (f ~ /cpuset/)         ? "CPUSET:" f : "OTHER:" f
        if (f=="/proc/stat") print "T", ts
      }
      NF==0 { next }                                  # bare tag rows break parsers
      tag=="STAT"  && !/^(cpu|ctxt |intr |procs_|softirq )/ { next }
      tag=="SCHED" && !/^(cpu[0-9]|version|timestamp)/      { next }   # skip 864 domain rows
      tag=="MEM"   && !/^(MemFree|MemAvailable|Dirty|Writeback|SReclaimable):/ { next }
      { print tag, $0 }
    ' "${files[@]}" >&3 2>/dev/null
    read -r -t "$INTERVAL" -u "$napfd" l
  done
  exec 3>&-
}

# ---------------------------------------------------------------------------
# Slow loop: the expensive, forking observations. 15 s is enough to attribute
# CPU between platform daemons without the collector becoming a cost centre.
# ---------------------------------------------------------------------------
slow() {
  local out="${RUNDIR}/slow.txt" s line comm rest f deadline
  deadline=$(( ${EPOCHSECONDS:-0} + DURATION ))
  while (( EPOCHSECONDS < deadline )); do
    {
      echo "=== epoch=${EPOCHREALTIME} uptime=$(< /proc/uptime)"
      echo "--- loadavg"; cat /proc/loadavg
      # Cumulative per-process CPU time. utime+stime deltas across samples give
      # exact attribution -- unlike top's first-iteration %CPU, which is
      # averaged over the process lifetime and badly misleading at boot.
      echo "--- procs (pid comm state utime stime nthreads rss last_cpu)"
      local pid
      for s in /proc/[0-9]*/stat; do
        read -r line < "$s" 2>/dev/null || continue
        pid="${s#/proc/}"; pid="${pid%/stat}"
        # comm is parenthesised and may contain spaces; split on the LAST ')'.
        comm="${line#*(}"; comm="${comm%)*}"
        rest="${line##*) }"
        f=($rest)
        (( ${#f[@]} >= 37 )) || continue
        # f[0] is proc(5) field 3 (state), so f[i] == field (i+3):
        #   utime=14->f[11]  stime=15->f[12]  num_threads=20->f[17]
        #   rss=24->f[21]    processor=39->f[36]
        printf '%s %s %s %s %s %s %s %s\n' \
          "$pid" "$comm" "${f[0]}" "${f[11]}" "${f[12]}" \
          "${f[17]}" "${f[21]}" "${f[36]}"
      done
      echo "--- crictl"
      timeout 10 crictl --runtime-endpoint unix:///var/run/crio/crio.sock \
        pods 2>/dev/null | awk 'NR>1{n++; st[$(NF-2)]++} END{
          printf "pods_total=%d ", n; for (k in st) printf "%s=%d ", k, st[k];
          print ""}'
      timeout 10 crictl --runtime-endpoint unix:///var/run/crio/crio.sock \
        ps -a 2>/dev/null | awk 'NR>1{n++; st[$6]++} END{
          printf "ctrs_total=%d ", n; for (k in st) printf "%s=%d ", k, st[k];
          print ""}'
      echo "--- crio metrics"
      timeout 5 curl -s http://127.0.0.1:9537/metrics 2>/dev/null | \
        grep -E '^crio_(operations_latency_seconds_total|image_pulls|containers_oom)' | head -60
    } >> "$out" 2>&1
    sleep "$SLOW_EVERY"
  done
}

finish() {
  [[ -n "${SADC_PID:-}" ]] && kill "$SADC_PID" 2>/dev/null
  mkdir -p "$OUTDIR"
  # Journal for the boot: the authoritative pod-bringup timeline lives here.
  journalctl -b -o short-precise --no-pager \
    -u crio -u kubelet -u ovs-vswitchd -u systemd-udevd -u NetworkManager \
    > "${RUNDIR}/journal-units.log" 2>&1
  journalctl -b -o short-precise --no-pager -k > "${RUNDIR}/journal-kernel.log" 2>&1
  systemd-analyze blame         > "${RUNDIR}/systemd-blame.txt"         2>&1
  systemd-analyze critical-chain > "${RUNDIR}/systemd-critical.txt"     2>&1
  # fast.txt is ~40 kB/sample on an 80-CPU node (~110 MB over 45 min) and
  # compresses ~20:1. Compress in tmpfs before touching the contended disk.
  gzip -3 "${RUNDIR}"/*.txt "${RUNDIR}"/*.log 2>/dev/null
  cp -a "${RUNDIR}/." "$OUTDIR/" 2>/dev/null
  # Keep the last N boots only; this lands on the contended disk.
  ls -1dt "${OUTDIR_BASE}"/*/ 2>/dev/null | tail -n "+$((KEEP_BOOTS+1))" | \
    xargs -r rm -rf
  rm -rf "$RUNDIR"
  echo "boot-perf: collection written to ${OUTDIR}" >&2
}
trap finish EXIT TERM INT

fast &
FAST_PID=$!
slow &
SLOW_PID=$!
wait "$FAST_PID" "$SLOW_PID"
