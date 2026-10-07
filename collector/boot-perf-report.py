#!/usr/bin/env python3
"""Turn a boot-perf collection directory into the contention report.

  python3 -I boot-perf-report.py /path/to/boot-perf/<stamp>-<bootid>/

Produces the four views that actually settle the "is the reserved pool the
bottleneck" question:

  1. Reserved vs isolated pool utilisation over time.
  2. Mean run-queue wait per reserved CPU (from /proc/schedstat run_delay) --
     the direct measure of oversubscription that %busy only implies.
  3. CPU pressure (PSI) for the root, system.slice and kubepods.slice.
  4. Per-daemon CPU attribution from /proc/<pid>/stat utime+stime deltas.
"""
import gzip
import io
import re
import sys
import pathlib
import statistics as st
from collections import defaultdict

HZ = 100  # USER_HZ; RHCOS kernels use 100


def opener(d, stem):
    for name in (stem, stem + ".gz"):
        p = d / name
        if p.exists():
            return gzip.open(p, "rt") if name.endswith(".gz") else open(p)
    return io.StringIO("")


def parse_cpusets(d):
    """Determine the reserved (platform) CPU set.

    `systemd.cpu_affinity=` on the kernel command line is authoritative and is
    tried FIRST. Do not trust system.slice's cpuset: on a workload-partitioned
    node that slice frequently has NO cpuset of its own -- confinement comes
    from the inherited systemd affinity mask -- so cpuset.cpus.effective reads
    as every CPU on the box. Using it silently reports a 288-CPU "reserved"
    pool and dilutes every utilisation figure to near zero.
    """
    reserved, ncpu = set(), 0
    with opener(d, "00-context.txt") as fh:
        for line in fh:
            for tok in line.split():
                if tok.startswith("systemd.cpu_affinity="):
                    reserved = expand(tok.split("=", 1)[1])
            m = re.match(r"^CPU\(s\):\s+(\d+)", line)
            if m:
                ncpu = int(m.group(1))
    if not reserved:
        # Fallback: the slice cpuset, only meaningful when it is actually set
        # and narrower than the machine.
        with opener(d, "fast.txt") as fh:
            for line in fh:
                if line.startswith("CPUSET:/sys/fs/cgroup/system.slice/"):
                    cand = expand(line.rsplit(" ", 1)[-1].strip())
                    if cand and (not ncpu or len(cand) < ncpu):
                        reserved = cand
                    break
    return reserved, ncpu


def expand(spec):
    out = set()
    for part in spec.split(","):
        if not part:
            continue
        if "-" in part:
            a, b = part.split("-")
            out |= set(range(int(a), int(b) + 1))
        else:
            out.add(int(part))
    return out


def read_fast(d):
    """Yield one dict per sample."""
    cur = None
    with opener(d, "fast.txt") as fh:
        for line in fh:
            f = line.split()
            # Every branch below indexes f[1], and /proc/schedstat yields a
            # trailing blank line that the collector echoes as a bare "SCHED ".
            # Guard once here rather than at each use.
            if len(f) < 2:
                continue
            if f[0] == "T":
                if cur:
                    yield cur
                # Older collections put uptime on the T row; newer ones emit a
                # separate UP row (one awk pass tags by filename). Accept both.
                cur = {"t": float(f[1]),
                       "uptime": float(f[2]) if len(f) > 2 else 0.0,
                       "cpu": {}, "sched": {}, "psi": {}, "stat": {}}
            elif f[0] == "UP":
                if cur is not None:
                    cur["uptime"] = float(f[1])
            elif cur is None:
                continue
            elif f[0] == "STAT":
                if re.match(r"^cpu\d+$", f[1]):
                    cur["cpu"][int(f[1][3:])] = [int(x) for x in f[2:]]
                elif f[1] in ("ctxt", "intr", "procs_running", "procs_blocked"):
                    cur["stat"][f[1]] = int(f[2])
            elif f[0] == "SCHED":
                if re.match(r"^cpu\d+$", f[1]) and len(f) >= 11:
                    # v15: ... rq_cpu_time=f[8] run_delay=f[9] pcount=f[10]
                    cur["sched"][int(f[1][3:])] = (int(f[9]), int(f[10]))
            elif f[0] == "LOAD":
                cur["load"] = float(f[1])
            elif f[0].startswith("PSI:"):
                key = f[0][4:] + ":" + f[1]
                kv = dict(x.split("=") for x in f[2:] if "=" in x)
                cur["psi"][key] = float(kv.get("total", 0))
    if cur:
        yield cur


def pool_busy(prev, cur, cpus):
    """Return (busy_fraction, kernel_fraction) for a set of CPUs."""
    tb = tk = tt = 0
    for c in cpus:
        if c not in prev["cpu"] or c not in cur["cpu"]:
            continue
        a, b = prev["cpu"][c], cur["cpu"][c]
        d = [y - x for x, y in zip(a, b)]
        tot = sum(d)
        if tot <= 0:
            continue
        idle = d[3] + (d[4] if len(d) > 4 else 0)  # idle + iowait
        tb += tot - idle
        tk += d[2] + (d[5] if len(d) > 5 else 0) + (d[6] if len(d) > 6 else 0)
        tt += tot
    return (tb / tt * 100 if tt else 0.0, tk / tt * 100 if tt else 0.0)


def runq_wait_us(prev, cur, cpus):
    """Mean run-queue wait per scheduling event, microseconds."""
    dd = dp = 0
    for c in cpus:
        if c not in prev["sched"] or c not in cur["sched"]:
            continue
        dd += cur["sched"][c][0] - prev["sched"][c][0]
        dp += cur["sched"][c][1] - prev["sched"][c][1]
    return dd / dp / 1000 if dp else 0.0


def main(path):
    d = pathlib.Path(path)
    reserved, ncpu = parse_cpusets(d)
    samples = list(read_fast(d))
    if len(samples) < 2:
        sys.exit(f"no samples found under {d}")
    allcpu = set(samples[0]["cpu"])
    if not reserved:
        sys.exit("could not determine the reserved cpuset from the collection")
    iso = allcpu - reserved

    print(f"reserved cpuset ({len(reserved)} CPUs): "
          f"{','.join(str(c) for c in sorted(reserved))}")
    print(f"isolated pool:   {len(iso)} CPUs\n")
    print(f"{'up(s)':>7} {'RESbusy%':>9} {'RESkrn%':>8} {'ISObusy%':>9} "
          f"{'runq_wait_us':>13} {'load1':>7} {'runnable':>9} {'blocked':>8} "
          f"{'ctx/s':>9} {'cpuPSI/s':>9} {'sysPSI/s':>9} {'podPSI/s':>9}")

    rows = []
    for a, b in zip(samples, samples[1:]):
        dt = b["t"] - a["t"]
        if dt <= 0:
            continue
        rb, rk = pool_busy(a, b, reserved)
        ib, _ = pool_busy(a, b, iso)
        rw = runq_wait_us(a, b, reserved)

        def psi(k):
            return ((b["psi"].get(k, 0) - a["psi"].get(k, 0)) / 1e6 / dt) * 100

        rows.append((b["uptime"], rb, rk, ib, rw, b.get("load", 0),
                     b["stat"].get("procs_running", 0),
                     b["stat"].get("procs_blocked", 0),
                     (b["stat"].get("ctxt", 0) - a["stat"].get("ctxt", 0)) / dt,
                     psi("/proc/pressure/cpu:some"),
                     psi("/sys/fs/cgroup/system.slice/cpu.pressure:some"),
                     psi("/sys/fs/cgroup/kubepods.slice/cpu.pressure:some")))

    # Print one row per 10 s of uptime to keep the table readable.
    last = -1e9
    for r in rows:
        if r[0] - last < 10:
            continue
        last = r[0]
        print(f"{r[0]:7.0f} {r[1]:9.1f} {r[2]:8.1f} {r[3]:9.1f} {r[4]:13.1f} "
              f"{r[5]:7.1f} {r[6]:9d} {r[7]:8d} {r[8]:9.0f} "
              f"{r[9]:9.1f} {r[10]:9.1f} {r[11]:9.1f}")

    rb = [r[1] for r in rows]
    act = [r for r in rows if r[1] > 50]
    print(f"\n--- summary over {len(rows)} intervals "
          f"({rows[-1][0]-rows[0][0]:.0f} s of uptime) ---")
    print(f"  reserved busy      mean {st.mean(rb):5.1f}%  "
          f"p95 {sorted(rb)[int(.95*len(rb))]:5.1f}%  max {max(rb):5.1f}%")
    print(f"  time >=90% busy    {sum(1 for v in rb if v>=90)/len(rb)*100:5.1f}% "
          f"of intervals")
    if act:
        dem = st.mean(r[1] for r in act) / 100 * len(reserved)
        print(f"  platform CPU demand during active boot: {dem:5.2f} CPUs "
              f"consumed of {len(reserved)} reserved "
              f"(rho={dem/len(reserved):.2f})")
        print(f"  isolated pool idle at the same time:    "
              f"{(100-st.mean(r[3] for r in act))/100*len(iso):5.1f} CPUs free")
        print(f"  mean run-queue wait on reserved pool:   "
              f"{st.mean(r[4] for r in act):7.1f} us "
              f"(p95 {sorted(r[4] for r in act)[int(.95*len(act))]:.1f} us)")

    # ---- per-daemon CPU attribution ------------------------------------
    prev, tot, thr = {}, defaultdict(float), defaultdict(int)
    onres = defaultdict(int)   # samples seen running on a reserved CPU
    nsamp = defaultdict(int)
    first = lastt = None
    with opener(d, "slow.txt") as fh:
        for line in fh:
            if line.startswith("=== epoch="):
                lastt = float(line.split("epoch=")[1].split()[0])
                first = first or lastt
                continue
            f = line.split()
            if len(f) != 8 or not f[0].isdigit():
                continue
            pid, comm = int(f[0]), f[1]
            try:
                cpu = (int(f[3]) + int(f[4])) / HZ
                last_cpu = int(f[7])
            except ValueError:
                continue
            if pid in prev and prev[pid][0] == comm:
                dv = cpu - prev[pid][1]
                if dv > 0:
                    tot[comm] += dv
                    nsamp[comm] += 1
                    if last_cpu in reserved:
                        onres[comm] += 1
            prev[pid] = (comm, cpu)
            thr[comm] = max(thr[comm], int(f[5]))
    span = (lastt - first) if first and lastt and lastt > first else 0
    if span:
        print(f"\n--- CPU attribution over {span:.0f} s "
              f"(utime+stime deltas, all PIDs) ---")
        # "on res" is the fraction of samples where the process was last seen
        # running on a reserved CPU. Anything near 0% is NOT competing for the
        # platform pool, so its "%of pool" is meaningless -- the collector
        # itself and any isolated-pool workload fall in this bucket.
        print(f"  {'command':<24} {'cpu-s':>9} {'CPUs':>7} {'%of pool':>9} "
              f"{'on res':>7} {'max thr':>8}")
        for c, v in sorted(tot.items(), key=lambda x: -x[1])[:25]:
            frac = (onres[c] / nsamp[c] * 100) if nsamp[c] else 0.0
            flag = "" if frac >= 50 else "   <- not on reserved pool"
            print(f"  {c[:24]:<24} {v:9.1f} {v/span:7.2f} "
                  f"{v/span/len(reserved)*100:8.1f}% {frac:6.0f}% "
                  f"{thr[c]:8d}{flag}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else ".")
