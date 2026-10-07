#!/bin/bash
# node-sampler.sh -- emit one CSV row per interval describing contention on
# the platform CPU set. Runs on the node; prints to stdout.
#
# PSI is NOT used here. The PerformanceProfile-tuned RHCOS node carries
# psi=0 on its kernel command line, so /proc/pressure does not exist and no
# cgroup has a cpu.pressure file. The primary saturation signal is therefore
# /proc/schedstat run_delay, which is always available.
#
#   SAMPLE_SECS=1 DURATION=600 PLATFORM_CPUS=0,72,144,216 ./node-sampler.sh
set -u
INTERVAL="${SAMPLE_SECS:-2}"
DURATION="${DURATION:-600}"
CG=/sys/fs/cgroup

PLAT="${PLATFORM_CPUS:-$(tr ' ' '\n' < /proc/cmdline | sed -n 's/^systemd.cpu_affinity=//p')}"
expand() {
  local p a b out=() i; IFS=',' read -ra p <<< "$1"
  for x in "${p[@]}"; do [[ -z "$x" ]] && continue
    if [[ "$x" == *-* ]]; then a=${x%-*}; b=${x#*-}; for ((i=a;i<=b;i++)); do out+=("$i"); done
    else out+=("$x"); fi; done
  printf '%s\n' "${out[@]}" | sort -n
}
mapfile -t PCPUS < <(expand "$PLAT")
NP=${#PCPUS[@]}
echo "# platform_cpus=$PLAT count=$NP interval=${INTERVAL}s" >&2

declare -A pj pu pn ps pi pw pq pk prd ppc
read_stat() {
  local l f
  while read -r l; do
    f=($l); (( ${#f[@]} )) || continue
    case "${f[0]}" in
      cpu[0-9]*) c=${f[0]#cpu}
        cj[$c]="${f[1]} ${f[2]} ${f[3]} ${f[4]} ${f[5]} ${f[6]} ${f[7]}" ;;
      ctxt) CTXT=${f[1]} ;;
      intr) INTR=${f[1]} ;;
      procs_running) PRUN=${f[1]} ;;
      procs_blocked) PBLK=${f[1]} ;;
    esac
  done < /proc/stat
  while read -r l; do
    f=($l); (( ${#f[@]} >= 10 )) || continue
    [[ ${f[0]} == cpu[0-9]* ]] || continue
    c=${f[0]#cpu}
    rd[$c]=${f[8]}; pc[$c]=${f[9]}
  done < /proc/schedstat
}

declare -A cj rd pc ocj ord opc
echo "ts,uptime,plat_busy_pct,plat_sys_pct,plat_iowait_pct,plat_sat_cores,other_busy_pct,runq_wait_us,load1,procs_running,procs_blocked,ctxt_per_s,intr_per_s,nproc"
read_stat
for c in "${!cj[@]}"; do ocj[$c]=${cj[$c]}; done
for c in "${!rd[@]}"; do ord[$c]=${rd[$c]}; opc[$c]=${pc[$c]}; done
OCTXT=$CTXT; OINTR=$INTR; T0=$EPOCHREALTIME
deadline=$((EPOCHSECONDS + DURATION))

while (( EPOCHSECONDS < deadline )); do
  sleep "$INTERVAL"
  read_stat
  now=$EPOCHREALTIME
  dt=$(awk -v a="$T0" -v b="$now" 'BEGIN{printf "%.3f", b-a}')
  T0=$now

  tb=0; tt=0; tk=0; tw=0; sat=0; ob=0; ot=0; drd=0; dpc=0
  for c in "${!cj[@]}"; do
    a=(${ocj[$c]}); b=(${cj[$c]}); ocj[$c]=${cj[$c]}
    [[ ${#a[@]} -eq 7 ]] || continue
    tot=0; for i in 0 1 2 3 4 5 6; do d[$i]=$(( ${b[$i]} - ${a[$i]} )); tot=$((tot+${d[$i]})); done
    (( tot > 0 )) || continue
    busy=$(( tot - d[3] - d[4] ))
    if [[ " ${PCPUS[*]} " == *" $c "* ]]; then
      tb=$((tb+busy)); tt=$((tt+tot)); tk=$((tk+d[2]+d[5]+d[6])); tw=$((tw+d[4]))
      (( busy * 100 / tot >= 90 )) && ((sat++))
      drd=$(( drd + ${rd[$c]} - ${ord[$c]} )); dpc=$(( dpc + ${pc[$c]} - ${opc[$c]} ))
    else
      ob=$((ob+busy)); ot=$((ot+tot))
    fi
  done
  for c in "${!rd[@]}"; do ord[$c]=${rd[$c]}; opc[$c]=${pc[$c]}; done

  awk -v ts="$now" -v up="$(cut -d' ' -f1 /proc/uptime)" \
      -v tb="$tb" -v tt="$tt" -v tk="$tk" -v tw="$tw" -v sat="$sat" \
      -v ob="$ob" -v ot="$ot" -v drd="$drd" -v dpc="$dpc" \
      -v ld="$(cut -d' ' -f1 /proc/loadavg)" -v pr="$PRUN" -v pb="$PBLK" \
      -v dc="$((CTXT-OCTXT))" -v di="$((INTR-OINTR))" -v dt="$dt" -v np="$NP" \
      'BEGIN{printf "%.2f,%s,%.1f,%.1f,%.1f,%d,%.1f,%.1f,%s,%s,%s,%.0f,%.0f,%d\n",
        ts, up, (tt?tb/tt*100:0), (tt?tk/tt*100:0), (tt?tw/tt*100:0), sat,
        (ot?ob/ot*100:0), (dpc?drd/dpc/1000:0), ld, pr, pb, dc/dt, di/dt, np}'
  OCTXT=$CTXT; OINTR=$INTR
done
