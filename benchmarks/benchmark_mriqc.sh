#!/usr/bin/env bash
# benchmark_mriqc.sh
# Loops over thread counts and repetitions,
# times run_mriqc.sh, saves per‑run logs,
# and prints a summary table with averages.

set -euo pipefail

# user parameters
SUBJ_LABEL=${1:-08}                          # subject to test, default = 08
DATA_ROOT=${DATA_ROOT:-$(pwd)}               # dataset root directory (override via DATA_ROOT)
IMAGE_PATH=${IMAGE_PATH:-""}                 # MRIQC image path (override via IMAGE_PATH)
THREAD_LIST=${THREAD_LIST:-"4 8 12 16 24 32"} # thread counts (override via THREAD_LIST)
REPS=${REPS:-2}                              # repeats per setting (override via REPS)
RUN_SCRIPT=${RUN_SCRIPT:-"./run_mriqc.sh"}   # MRIQC wrapper script (override via RUN_SCRIPT)
LOG_DIR=${LOG_DIR:-"$DATA_ROOT/benchmark_logs"} # where to store per‑run logs

mkdir -p "$LOG_DIR"
cd "$DATA_ROOT"

# If IMAGE_PATH is set, let run_mriqc.sh pick it up as $SIF
[[ -n "$IMAGE_PATH" ]] && export SIF="$IMAGE_PATH"

read -r -a THREADS <<< "$THREAD_LIST"
declare -A ELAPSED                          # map "threads,rep" → seconds
TIMEFORMAT='%R'                            # capture only real time

echo "Benchmarking MRIQC for sub-${SUBJ_LABEL}"
for threads in "${THREADS[@]}"; do
  for ((rep=1; rep<=REPS; rep++)); do
    LOG_FILE="$LOG_DIR/mriqc_sub-${SUBJ_LABEL}_thr-${threads}_run-${rep}.log"
    echo -n "  [threads=${threads} | run #${rep}] … "

    # disable errexit so we can catch non‑zero exit
    set +e
    t=$(
      { time "$RUN_SCRIPT" "$SUBJ_LABEL" "$threads" >"$LOG_FILE" 2>&1; } 2>&1
    )
    status=$?
    set -e

    if (( status != 0 )); then
      echo "ERROR (exit code ${status}). Dumping log:"
      sed 's/^/    /' "$LOG_FILE"
      exit $status
    fi

    echo "${t}s"
    ELAPSED["${threads},${rep}"]=$t
  done
done

# summary
echo -e "\n=== Elapsed times (s) ==="
printf "%-8s" "Threads"
for ((rep=1; rep<=REPS; rep++)); do printf "%8s" "Run#${rep}"; done
printf "%8s\n" "Avg"
printf '%.0s-' {1..8}
for ((i=0;i<REPS+1;i++)); do printf '%8s' '--------'; done
echo

for threads in "${THREADS[@]}"; do
  printf "%-8s" "$threads"
  sum=0
  for ((rep=1; rep<=REPS; rep++)); do
    t=${ELAPSED["${threads},${rep}"]}
    printf "%8s" "$t"
    sum=$(awk -v a="$sum" -v b="$t" 'BEGIN{printf "%.6f", a+b}')
  done
  avg=$(awk -v tot="$sum" -v n="$REPS" 'BEGIN{printf "%.3f", tot/n}')
  printf "%8s\n" "$avg"
done
