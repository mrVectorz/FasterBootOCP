#!/bin/bash
# run-experiment.sh -- scale a pod-density workload against a known platform
# CPU width, sampling node contention throughout, and report the pod
# create->ready distribution.
#
#   ./run-experiment.sh <name> <replicas> [platform_cpus]
#
#   ./run-experiment.sh baseline-4cpu  300
#   ./run-experiment.sh boosted-12cpu  300  0,70-72,142-144,214-216,286-287
#
# Pod create->ready latency is the KPI: it is the single-node analogue of
# "how long does the workload take to come up after a reboot", and unlike
# task counts it is measured per pod so you get a distribution, not a guess.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
: "${KUBECONFIG:?set KUBECONFIG}"
NAME="${1:?usage: run-experiment.sh <name> <replicas> [platform_cpus]}"
REPLICAS="${2:?}"
PLATFORM_CPUS="${3:-}"
NS=boot-perf-density
NODE="${NODE:?set NODE to your node name}"
TIMEOUT="${TIMEOUT:-1500}"
SETTLE="${SETTLE:-60}"
OUT="${HERE}/../results/${NAME}"
mkdir -p "$OUT"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
nodesh() { # run a script on the node
  timeout "${2:-300}" oc debug "node/$NODE" --quiet -- \
    chroot /host bash -c "echo $(base64 -w0 "$1") | base64 -d | bash" 2>&1
}
nodecmd() {
  timeout "${2:-120}" oc debug "node/$NODE" --quiet -- chroot /host bash -c "$1" 2>&1
}

say "Preparing namespace and workload"
oc apply -f "${HERE}/density-deployment.yaml" >/dev/null
oc -n "$NS" scale deploy/density --replicas=0 >/dev/null
# Wait for a clean slate; leftover terminating pods skew the next run.
for _ in $(seq 60); do
  n=$(oc -n "$NS" get pods --no-headers 2>/dev/null | wc -l)
  (( n == 0 )) && break
  sleep 5
done
echo "namespace clean (0 pods)"

if [[ -n "$PLATFORM_CPUS" ]]; then
  say "Setting platform CPU set to ${PLATFORM_CPUS}"
  PCPUS="$PLATFORM_CPUS" nodecmd \
    "echo $(base64 -w0 "${HERE}/platform-cpus.sh") | base64 -d > /tmp/pc.sh; bash /tmp/pc.sh set '${PLATFORM_CPUS}'" 300 \
    | tee "${OUT}/platform-cpus-before.txt"
else
  say "Using the node's current platform CPU set"
  nodecmd "echo $(base64 -w0 "${HERE}/platform-cpus.sh") | base64 -d | bash -s show" 120 \
    | tee "${OUT}/platform-cpus-before.txt"
fi
PLAT=$(grep -m1 -oE 'cpus=\[[^]]*\]' "${OUT}/platform-cpus-before.txt" | head -1 | sed 's/cpus=\[//;s/\]//')
echo "sampling platform set: ${PLAT:-<cmdline default>}"

say "Starting node sampler (background)"
DUR=$(( TIMEOUT + SETTLE + 60 ))
nohup timeout $(( DUR + 120 )) oc debug "node/$NODE" --quiet -- chroot /host bash -c \
  "export SAMPLE_SECS=2 DURATION=${DUR} PLATFORM_CPUS='${PLAT}'; echo $(base64 -w0 "${HERE}/node-sampler.sh") | base64 -d | bash" \
  > "${OUT}/sampler.csv" 2> "${OUT}/sampler.err" &
SAMPLER=$!
sleep 20   # let the debug pod start and a few idle rows land
echo "sampler pid $SAMPLER, $(grep -c , "${OUT}/sampler.csv" 2>/dev/null || echo 0) rows so far"

say "Scaling to ${REPLICAS} replicas"
T_SCALE=$(date -u +%s)
date -u -d "@$T_SCALE" +%Y-%m-%dT%H:%M:%SZ > "${OUT}/t_scale.txt"
oc -n "$NS" scale deploy/density --replicas="$REPLICAS" >/dev/null

say "Waiting for readiness (timeout ${TIMEOUT}s)"
: > "${OUT}/progress.csv"
echo "elapsed_s,total,ready,running,pending" >> "${OUT}/progress.csv"
while :; do
  el=$(( $(date -u +%s) - T_SCALE ))
  read -r tot rdy run pend < <(oc -n "$NS" get pods --no-headers 2>/dev/null | awk '
    {t++; split($2,a,"/"); if (a[1]==a[2] && $3=="Running") r++;
     if ($3=="Running") g++; else if ($3=="Pending"||$3=="ContainerCreating") p++}
    END{print t+0, r+0, g+0, p+0}')
  echo "${el},${tot},${rdy},${run},${pend}" >> "${OUT}/progress.csv"
  printf '\r  t+%-5ss  ready %4s/%-4s  running %-4s pending %-4s' "$el" "$rdy" "$REPLICAS" "$run" "$pend"
  (( rdy >= REPLICAS )) && { echo; echo "ALL READY at t+${el}s"; break; }
  (( el > TIMEOUT ))   && { echo; echo "TIMEOUT at t+${el}s with ${rdy}/${REPLICAS} ready"; break; }
  sleep 5
done
T_DONE=$(date -u +%s)

say "Settling for ${SETTLE}s"
sleep "$SETTLE"

say "Capturing pod timeline"
oc -n "$NS" get pods -o json > "${OUT}/pods.json" 2>/dev/null
oc -n "$NS" get events --sort-by=.lastTimestamp -o json > "${OUT}/events.json" 2>/dev/null

say "Stopping sampler"
kill "$SAMPLER" 2>/dev/null; wait "$SAMPLER" 2>/dev/null
echo "$(grep -c , "${OUT}/sampler.csv" 2>/dev/null || echo 0) sampler rows"

say "Tearing down workload"
oc -n "$NS" scale deploy/density --replicas=0 >/dev/null

if [[ -n "$PLATFORM_CPUS" ]]; then
  say "Restoring platform CPU set"
  nodecmd "echo $(base64 -w0 "${HERE}/platform-cpus.sh") | base64 -d | bash -s reset" 300 \
    | tee "${OUT}/platform-cpus-after.txt" | tail -14
fi

cat > "${OUT}/meta.env" <<EOF
name=${NAME}
replicas=${REPLICAS}
platform_cpus=${PLAT}
t_scale=${T_SCALE}
t_done=${T_DONE}
wall_to_ready_s=$(( T_DONE - T_SCALE ))
EOF
say "Done -> ${OUT}"
cat "${OUT}/meta.env"
