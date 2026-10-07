# FasterBootOCP

Tools and a method for diagnosing -- and in some cases fixing -- slow pod
bring-up after a reboot on OpenShift **Single Node OpenShift (SNO)** with
**workload partitioning** and high pod density (500+ pods).

## The problem

On a workload-partitioned node the platform (kubelet, CRI-O, kube-apiserver,
etcd, OVN) is confined to a small set of *reserved* CPUs. The rest of the
machine is *isolated* and belongs to the workload.

That split is sized for steady state. But during boot the platform does
several times its steady-state work -- it has to recreate every pod sandbox
on the node at once -- while the isolated CPUs sit almost completely idle
because the workload has not started yet.

The result, on a node with enough pods, is a machine that is simultaneously
**saturated and idle**: a handful of reserved CPUs pegged at 100% while the
large majority of the box does nothing. Boot time degrades sharply and
non-linearly.

Raising the reserved CPU count fixes boot, but wastes those CPUs for the rest
of the node's life. The goal here is to get the boot-time behaviour of a large
reserved pool while keeping a small one at steady state.

## What is in this repo

| | |
|---|---|
| **[`MOP.md`](MOP.md)** | **Start here.** Method of Procedure: install the collector, take a baseline boot, take a boosted boot, compare. |
| `collector/` | Automated boot-time diagnostics. A MachineConfig-managed systemd unit that starts *before* CRI-O and kubelet, so it captures the first minute of boot that SSH-based collection cannot reach. |
| `workaround/` | Transient boot-window CPU boost. Temporarily widens the platform's CPU affinity onto idle isolated CPUs, then releases it on convergence. |
| `harness/` | Optional lab harness for reproducing the effect with a synthetic pod-density workload. |

## Does the workaround actually help?

**Only when the reserved pool is genuinely saturated.** Measured on a lab SNO
(288 CPUs, no SMT, 487 pods, identical procedure, varying only the reserved
CPU count):

| reserved CPUs | rho without boost | pods ready p99: without -> with boost | verdict |
|---|---|---|---|
| 8 | 0.77 | 224-229 s -> 234 s | no benefit, ~8-14% worse on p50 |
| **4** | **0.91** | **282 s -> 228 s (-19%)** | **clear benefit** |

In the saturated case it is a good trade:

| configuration | pods ready p50 | p99 |
|---|---|---|
| 8 reserved CPUs, no boost | 200 / 211 s | 224 / 229 s |
| **4 reserved CPUs + boost** | **204 s** | **228 s** |
| 4 reserved CPUs, no boost | 247 s | 282 s |

**Halving the permanently reserved CPUs and applying a transient boot-window
boost recovered the boot performance of the larger pool.**

So: **measure rho first.** The collector reports it directly. Below ~0.85 the
workaround is not worth deploying. At or above ~0.9 it is.

### "8 reserved CPUs" does not mean the same thing on every machine

If the reserved set is made of **hyperthread sibling pairs**, N reserved CPUs
is only N/2 physical cores, and two SMT siblings deliver roughly 1.2-1.3x one
core rather than 2x. A deployment with 8 reserved CPUs on 4 physical cores has
roughly the throughput of 5 cores, not 8 -- and can be deeply saturated where
another machine with 8 whole cores is comfortable.

Check before assuming:

```bash
for c in $(tr ' ' '\n' < /proc/cmdline | sed -n 's/^systemd.cpu_affinity=//p' | tr ',' ' '); do
  echo "cpu$c siblings: $(cat /sys/devices/system/cpu/cpu$c/topology/thread_siblings_list)"
done
```

## Two measurement traps

**PSI is not available.** `/proc/pressure/*` and cgroup `cpu.pressure` do not
exist on a stock RHCOS node -- the kernel defaults PSI off, and some tuning
profiles explicitly disable it. Use `/proc/schedstat` `run_delay`, which the
collector and report do. To get PSI you must add `psi=1` via
`PerformanceProfile.spec.additionalKernelArgs` and reboot.

**Cgroup throttling counters read zero even at full saturation.**
`system.slice/cpu.stat` shows `nr_throttled 0` with the pool pegged at 100%,
because workload partitioning constrains the platform by CPU *affinity*, not
by a CFS quota (only `kubepods.slice` gets a quota). Checking throttling to
decide whether CPU is the problem will tell you it is not.

## Scope and caveats

- Validated on OCP 4.20 and 4.22 SNO with `cpuPartitioning: AllNodes` and a
  PerformanceProfile.
- The lab workload is synthetic -- one container running `sleep`, no PVCs,
  probes, init containers or additional network attachments. Real CNF pods are
  considerably more expensive to start, which should push rho up and make the
  saturated case more likely, but this is untested.
- The workaround deliberately does **not** touch `ovs-vswitchd` or
  `ovsdb-server`; ovn-kubernetes manages those dynamically and interfering
  with them wedged ovsdb in testing.
- It also does **not** change `reservedSystemCPUs`, so node allocatable and
  the CPU Manager state file are untouched and no Guaranteed pod is restarted.

## Licence

GPL-3.0 (see `LICENSE`).

Provided as-is. This is not a supported Red Hat product and carries no
warranty. The workaround in `workaround/` changes CPU affinity of running
control-plane processes; test it in a lab before using it anywhere that
matters.
