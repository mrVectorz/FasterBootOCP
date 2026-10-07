#!/usr/bin/env python3
"""Summarise and compare run-experiment.sh results.

  python3 -I report.py results/baseline-4cpu [results/boosted-12cpu ...]
"""
import csv
import json
import pathlib
import statistics as st
import sys
from datetime import datetime, timezone


def ts(s):
    # Kubernetes timestamps are UTC ("...Z"). strptime yields a NAIVE datetime
    # and .timestamp() then interprets it as LOCAL time, silently shifting
    # every value by the UTC offset. Differences between two such values are
    # unaffected, which is why this hid for a while -- but mixing one with a
    # real epoch (e.g. node boot time) is off by hours.
    return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(
        tzinfo=timezone.utc).timestamp()


def load(d):
    d = pathlib.Path(d)
    meta = {}
    if (d / "meta.env").exists():
        for line in (d / "meta.env").read_text().splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                meta[k] = v
    rows = []
    f = d / "sampler.csv"
    if f.exists():
        for r in csv.DictReader(x for x in f.read_text().splitlines()
                                if x and not x.startswith("#")):
            try:
                rows.append({k: float(v) for k, v in r.items()})
            except (ValueError, TypeError):
                pass
    pods = []
    f = d / "pods.json"
    if f.exists():
        try:
            doc = json.loads(f.read_text())
        except json.JSONDecodeError:
            doc = {"items": []}
        for p in doc.get("items", []):
            created = p["metadata"].get("creationTimestamp")
            conds = {c["type"]: c.get("lastTransitionTime")
                     for c in (p.get("status", {}).get("conditions") or [])}
            if created and conds.get("Ready"):
                try:
                    pods.append({
                        "name": p["metadata"]["name"],
                        "created": ts(created),
                        "scheduled": ts(conds["PodScheduled"]) if conds.get("PodScheduled") else None,
                        "ready": ts(conds["Ready"]),
                    })
                except (ValueError, TypeError):
                    pass
    prog = []
    f = d / "progress.csv"
    if f.exists():
        for r in csv.DictReader(f.read_text().splitlines()):
            try:
                prog.append({k: int(v) for k, v in r.items()})
            except (ValueError, TypeError):
                pass
    return d.name, meta, rows, pods, prog


def pct(v, q):
    if not v:
        return 0.0
    v = sorted(v)
    return v[min(len(v) - 1, int(q * len(v)))]


def main(dirs):
    results = [load(d) for d in dirs]
    for name, meta, rows, pods, prog in results:
        plat = meta.get("platform_cpus", "?")
        npl = int(rows[0]["nproc"]) if rows else 0
        print(f"\n{'='*86}\n{name}   platform CPUs = [{plat}] ({npl})   "
              f"replicas = {meta.get('replicas','?')}\n{'='*86}")
        if not rows:
            print("  no sampler data")
        else:
            # Restrict to the loaded window: rows where the platform pool was
            # doing real work. Idle head/tail rows would dilute every stat.
            act = [r for r in rows if r["plat_busy_pct"] > 40] or rows
            busy = [r["plat_busy_pct"] for r in act]
            print(f"  platform busy     mean {st.mean(busy):5.1f}%  "
                  f"p95 {pct(busy,.95):5.1f}%  max {max(busy):5.1f}%")
            print(f"  >=90% busy        {sum(1 for v in busy if v>=90)/len(busy)*100:5.1f}%"
                  f" of active samples")
            print(f"  all cores >90%    "
                  f"{sum(1 for r in act if r['plat_sat_cores']>=npl)/len(act)*100:5.1f}% of samples")
            dem = st.mean(busy) / 100 * npl
            print(f"  demand consumed   {dem:5.2f} of {npl} CPUs   "
                  f"(rho = {dem/npl:.2f})")
            rw = [r["runq_wait_us"] for r in act]
            print(f"  run-queue wait    mean {st.mean(rw):7.1f} us  "
                  f"p95 {pct(rw,.95):7.1f} us  max {max(rw):7.1f} us")
            print(f"  isolated pool     mean {st.mean(r['other_busy_pct'] for r in act):5.1f}% busy")
            print(f"  load1 max         {max(r['load1'] for r in rows):6.1f}")
            print(f"  ctx switch/s      mean {st.mean(r['ctxt_per_s'] for r in act):9.0f}")
            print(f"  kernel time       mean {st.mean(r['plat_sys_pct'] for r in act):5.1f}% of pool")

        if pods:
            t0 = min(p["created"] for p in pods)
            lat = sorted(p["ready"] - p["created"] for p in pods)
            print(f"\n  pod create->ready  n={len(pods)}")
            print(f"    p50 {pct(lat,.50):7.1f}s   p90 {pct(lat,.90):7.1f}s   "
                  f"p99 {pct(lat,.99):7.1f}s   max {max(lat):7.1f}s")
            print(f"    last pod ready at t+{max(p['ready'] for p in pods)-t0:.0f}s "
                  f"(from first pod creation)")
            sch = [p["scheduled"] - p["created"] for p in pods if p["scheduled"]]
            if sch:
                print(f"    schedule latency p50 {pct(sch,.50):.1f}s  "
                      f"p99 {pct(sch,.99):.1f}s   (rest is kubelet+CRI-O+CNI)")
        if prog:
            fin = [p for p in prog if p["ready"] >= p["total"] > 0]
            print(f"\n  ramp: ", end="")
            for q in (0.25, 0.5, 0.75, 0.9, 1.0):
                tgt = int(q * int(meta.get("replicas", 0) or 0))
                hit = next((p["elapsed_s"] for p in prog if p["ready"] >= tgt), None)
                print(f"{int(q*100)}%@{hit if hit is not None else '--'}s  ", end="")
            print()

    if len(results) > 1:
        print(f"\n{'='*86}\nCOMPARISON\n{'='*86}")
        print(f"{'metric':<28}" + "".join(f"{r[0][:22]:>24}" for r in results))

        def row(label, fn):
            print(f"{label:<28}" + "".join(f"{fn(r):>24}" for r in results))

        def safe(r, f, d="--"):
            try:
                return f(r)
            except (ValueError, ZeroDivisionError, IndexError, KeyError):
                return d

        row("platform CPUs", lambda r: int(r[2][0]["nproc"]) if r[2] else "--")
        row("rho", lambda r: safe(r, lambda x: f"{st.mean([q['plat_busy_pct'] for q in x[2] if q['plat_busy_pct']>40])/100:.2f}"))
        row("runq wait p95 (us)", lambda r: safe(r, lambda x: f"{pct([q['runq_wait_us'] for q in x[2] if q['plat_busy_pct']>40],.95):.0f}"))
        row("pod ready p50 (s)", lambda r: safe(r, lambda x: f"{pct(sorted(p['ready']-p['created'] for p in x[3]),.50):.1f}"))
        row("pod ready p99 (s)", lambda r: safe(r, lambda x: f"{pct(sorted(p['ready']-p['created'] for p in x[3]),.99):.1f}"))
        row("wall to all-ready (s)", lambda r: r[1].get("wall_to_ready_s", "--"))


if __name__ == "__main__":
    main(sys.argv[1:] or ["."])
