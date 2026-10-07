# MoP: measure SNO boot contention, and A/B test the transient CPU boost

**Objective.** Capture per-second CPU, scheduling and pod-bringup data across
a full node reboot at production pod density, then run a controlled A/B to
determine whether a transient boot-window CPU boost improves boot time on
*your* hardware.

**Applies to.** OCP 4.20-4.22 SNO with `cpuPartitioning: AllNodes` and a
PerformanceProfile. Validated on 4.20.26 and 4.22.13.

**Total time.** About 2 hours, dominated by four node reboots.

**Impact.** Each MachineConfig change triggers **one MachineConfigPool
rollout and node reboot**. On SNO that is a full outage of 10-15 minutes.
Schedule a maintenance window covering the whole procedure.

---

## Phase 0 -- Pre-checks and baseline facts

Record all of this before changing anything; the analysis depends on it.

```bash
export KUBECONFIG=<your kubeconfig>
NODE=<your node name>

# Workload partitioning must be AllNodes. This is INSTALL-TIME ONLY.
oc get infrastructure cluster -o jsonpath='{.status.cpuPartitioning}{"\n"}'

# Reserved / isolated split and the extended resource that proves it is live
oc get performanceprofile -o jsonpath='{.items[0].spec.cpu}{"\n"}'
oc get node $NODE -o jsonpath='{.status.capacity.management\.workload\.openshift\.io/cores}{"\n"}'

# Pod count -- this is the variable that matters most
oc get pods -A --no-headers | wc -l

# MCP must be idle before you start
oc get mcp master
```

Expected: `AllNodes`, a reserved/isolated split, a `.../cores` value, and
`UPDATED=True UPDATING=False DEGRADED=False`.

### Are your reserved CPUs whole cores or SMT siblings?

This single check determines whether you are likely to be in the saturated
regime at all.

```bash
oc debug node/$NODE -- chroot /host bash -c '
  R=$(tr " " "\n" < /proc/cmdline | sed -n "s/^systemd.cpu_affinity=//p")
  echo "reserved: $R"
  for c in $(echo $R | tr "," " "); do
    echo "  cpu$c -> siblings $(cat /sys/devices/system/cpu/cpu$c/topology/thread_siblings_list)"
  done
  lscpu | grep -E "^(CPU\(s\)|Thread|Core|Socket|NUMA node[0-9])"'
```

If each reserved CPU's sibling is *also* in the reserved set, your N reserved
CPUs are **N/2 physical cores**. Record this -- it is the main reason two
deployments with "8 reserved CPUs" behave completely differently.

---

## Phase 1 -- Install the collector

```bash
git clone https://github.com/mrVectorz/FasterBootOCP.git && cd FasterBootOCP
cd collector
python3 -I make-machineconfig.py master > 99-boot-perf-collector.yaml
oc apply -f 99-boot-perf-collector.yaml
```

Wait for the rollout. The API will be unreachable for part of it; keep polling
with short timeouts and **do not give up early** -- expect 10-15 minutes, and
MCO often reboots twice.

```bash
while :; do
  timeout 15 oc get mcp master --no-headers 2>/dev/null
  timeout 15 oc get node $NODE --no-headers 2>/dev/null
  sleep 30
done
# Done when: mcp UPDATED=True UPDATING=False DEGRADED=False, node Ready
```

If the MCP goes **Degraded**, stop and capture:
```bash
oc get mcp master -o yaml
oc -n openshift-machine-config-operator logs -l k8s-app=machine-config-daemon --tail=100
```

### What it costs

Measured at **0.036 CPUs** on a 288-CPU node at 1 Hz, pinned to two isolated
CPUs so it never competes with the reserved pool it is measuring. Output is
~10 kB/sample gzipped, written to tmpfs and flushed to disk only on exit. It
runs 45 minutes after each boot, then stops.

---

## Phase 2 -- Baseline boot (current reserved CPU count, no workaround)

Install the workaround files but leave the unit **disabled**, so the baseline
and the boosted run have byte-identical files on disk and differ only in
whether the unit runs.

```bash
cd ../workaround
python3 -I make-boost-machineconfig.py --role master --enabled false \
    > 99-platform-cpu-boost-OFF.yaml
oc apply -f 99-platform-cpu-boost-OFF.yaml     # one reboot
```

Wait for the MCP to settle and all pods to return. Then confirm the boost did
**not** run:

```bash
oc debug node/$NODE -- chroot /host systemctl is-enabled platform-cpu-boost.service   # disabled
```

Now collect (see Phase 4 for the retrieval commands) and record the numbers.
**Take this baseline twice** if you can -- run-to-run variance was ~5% in our
lab, and you need to know your own variance before believing a difference.

---

## Phase 3 -- Boosted boot (same reserved CPU count, workaround enabled)

```bash
python3 -I make-boost-machineconfig.py --role master --enabled true \
    --max-platform-cpus 32 \
    --exclude-cpus "<cpuset your latency-sensitive Guaranteed pods use>" \
    > 99-platform-cpu-boost-ON.yaml
oc apply -f 99-platform-cpu-boost-ON.yaml      # one reboot
```

**Set `--exclude-cpus`.** The boost already derives its candidates from
kubelet's CPU Manager state, so CPUs already assigned to Guaranteed pods are
structurally excluded, and it re-checks every 2 s. But if you have hard
latency targets, list those CPUs explicitly and they will never be touched
even transiently.

**Do not raise `--max-platform-cpus` above 32.** Go sizes `GOMAXPROCS` from
the CPU count visible at process start, and above roughly 32 its memory
management makes throughput go *down*. The generator refuses values above 32.

### Verify the boost actually applied

It can silently do nothing. Always check:

```bash
oc debug node/$NODE -- chroot /host journalctl -u platform-cpu-boost -b -o cat
```

Expect, in order:
```
cpu_manager_state ready after Ns
applied [<wide set>]: N pod cgroups, M daemons
boost active, cap=32, tracking Guaranteed pods every 2s
...
applied [<wide set>]: 36 pod cgroups, 2 daemons      <- later passes pick up the static pods
converged N/5 (runq_wait=...us ctrs=...)
releasing boost
```

Red flags:
- `cannot read /var/lib/kubelet/cpu_manager_state` or `nothing to boost` -- it
  did not run.
- `0 pod cgroups` on **every** pass -- `kube-apiserver` and `etcd` were never
  widened, so you are only measuring half the effect.

Confirm the control plane really moved:
```bash
oc debug node/$NODE -- chroot /host bash -c '
  for d in kube-apiserver etcd kubelet crio ovs-vswitchd; do
    p=$(pgrep -x $d | head -1); [ -n "$p" ] &&
      printf "%-16s %s\n" "$d" "$(awk "/Cpus_allowed_list/{print \$2}" /proc/$p/status)"
  done'
```
The first four should show the wide set during the boost window.
`ovs-vswitchd` is deliberately untouched.

---

## Phase 4 -- Collect and analyse (run after each boot)

The collector writes to tmpfs and only lands data in `/var/log/boot-perf/` on
exit. Either wait 45 minutes or flush once the boot has converged:

```bash
oc debug node/$NODE -- chroot /host systemctl stop boot-perf-collect.service
STAMP=$(oc debug node/$NODE -- chroot /host bash -c \
         'basename $(ls -1dt /var/log/boot-perf/*/ | head -1)' | tail -1 | tr -d '\r')
echo "$STAMP"
```

Retrieve over the API -- no SSH or scp needed:

```bash
mkdir -p ./run-baseline && cd ./run-baseline
for f in 00-context.txt.gz fast.txt.gz slow.txt.gz \
         journal-units.log.gz journal-kernel.log.gz \
         systemd-blame.txt.gz systemd-critical.txt.gz; do
  oc adm node-logs $NODE --path="boot-perf/${STAMP}/${f}" > "$f"
done
gzip -t *.gz && echo "archives intact"
```

Also capture the pod-readiness KPI and the node boot time:

```bash
oc debug node/$NODE -- chroot /host awk '{print int(systime()-$1)}' /proc/uptime \
  | tail -1 | tr -d '\r' > boot_epoch.txt
oc get pods -A -o json > pods.json
```

Analyse:

```bash
python3 -I ../collector/boot-perf-report.py .
```

### What to record from each run

| metric | where | why |
|---|---|---|
| **rho** | report summary: `platform CPU demand ... (rho=X)` | **the deciding number.** >=0.9 means saturated |
| intervals >=90% busy | report summary | how much of the boot was pegged |
| run-queue wait mean / p95 | report summary | direct measure of waiting for CPU. Healthy idle is 10-40 us |
| **pod-ready p50 / p90 / p99** | see snippet below | **the KPI.** End-to-end and unambiguous |
| isolated pool idle | report summary | the headroom the boost would use |

Pod readiness relative to node boot:

```bash
python3 -I - . "$(cat boot_epoch.txt)" <<'EOF'
import json,sys
from datetime import datetime, timezone
d,be=sys.argv[1],int(sys.argv[2])
def ts(s): return datetime.strptime(s,"%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
lat=sorted(ts(c["Ready"])-be for p in json.load(open(f"{d}/pods.json")).get("items",[])
  for c in [{x["type"]:x.get("lastTransitionTime") for x in (p.get("status",{}).get("conditions") or [])}]
  if c.get("Ready"))
lat=[x for x in lat if x>0]
q=lambda f: lat[min(len(lat)-1,int(f*len(lat)))]
print(f"pods ready after boot: n={len(lat)} p50 {q(.5):.0f}s p90 {q(.9):.0f}s p99 {q(.99):.0f}s max {max(lat):.0f}s")
EOF
```

> **Metric caveat.** The report derives "the reserved pool" from
> `systemd.cpu_affinity`, i.e. your configured reserved CPUs. When the boost
> widens the platform, work moves *off* those CPUs, so `reserved busy` and
> `run-queue wait` in the boosted run cover a shrinking share of the platform
> and understate its activity. **Compare pod-ready times between runs**, not
> busy percentages.

---

## Phase 5 -- Interpret

| finding | conclusion |
|---|---|
| rho < 0.85 in the baseline | CPU is not your binding constraint. The boost will not help and may cost a few percent. Look at the pod-creation pipeline instead -- CNI, image and mount setup, kubelet pod workers. |
| rho >= 0.9 **and** boosted pod-ready is materially better than baseline | The workaround is working. Consider deploying it, and consider whether you can now *reduce* steady-state reserved CPUs. |
| rho >= 0.9 but boosted is no better | CPU contention is real but something else is serialising bring-up. Check `journal-units.log.gz` for CNI and sandbox errors, and the report's CPU attribution for an unexpected consumer. |

"Materially better" means outside your own measured run-to-run variance --
which is why Phase 2 asks for two baselines.

### Useful greps on the captured journal

```bash
zcat journal-units.log.gz | grep -c 'Unreasonably long'          # OVS starved of CPU
zcat journal-units.log.gz | grep -c 'waiting for main to quiesce' # OVS main-loop stalls
zcat journal-units.log.gz | grep 'FailedCreatePodSandBox' | head  # CNI failures
zcat 00-context.txt.gz | grep -E 'ACTUAL Cpus_allowed_list|reserved set|PSI available'
```

The last one is the collector's self-audit: its **actual** affinity, read back
from the kernel, must not overlap your reserved set. If it does, the collector
was competing with what it was measuring and the numbers are suspect.

---

## Phase 6 -- Clean up

```bash
oc delete mc 99-master-platform-cpu-boost      # one reboot
oc delete mc 99-master-boot-perf-collector     # one reboot
```

The boost uses `--runtime` properties only and never writes to `/etc`, so a
reboot without the unit returns the node to its configured state regardless.
Collected data under `/var/log/boot-perf/` is not removed; delete it on the
node if required.

---

## Appendix -- reference numbers from a lab SNO

288 CPUs (no SMT), 487 pods, same node and procedure throughout, varying only
`spec.cpu.reserved`:

| run | reserved | boost | rho | >=90% busy | runq p95 | ready p50 | p90 | p99 |
|---|---|---|---|---|---|---|---|---|
| baseline 1 | 8 | no | 0.77 | 7.0% | 480 us | 200 s | 222 s | 224 s |
| baseline 2 | 8 | no | 0.76 | 2.4% | 497 us | 211 s | 229 s | 229 s |
| boosted | 8 | yes | 0.71 | 4.0% | 402 us | 228 s | 232 s | 234 s |
| baseline | 4 | no | 0.91 | 55.3% | 1097 us | 247 s | 279 s | 282 s |
| **boosted** | **4** | **yes** | **0.80** | **12.0%** | **848 us** | **204 s** | **226 s** | **228 s** |

A node that converges in ~200 s is not in trouble. For contrast, a 4.20 node
with 4 reserved CPUs and 428 pods reached rho 0.95, run-queue wait 961 us, and
flapped Ready/NotReady with 331 pods stuck in `ContainerCreating` for over 30
minutes.
