#!/usr/bin/env bash
# benchmark_mriqc.sh
# Loops over a set of thread counts and repeats,
# times run_mriqc.sh, and prints a summary table with averages.

set -euo pipefail

# ----------------- user parameters -----------------
SUBJ_LABEL=${1:-08}                          # subject to test, default = 08
DATA_ROOT=${DATA_ROOT:-$(pwd)}               # dataset root directory (override via DATA_ROOT)
IMAGE_PATH=${IMAGE_PATH:-""}                 # path to MRIQC Singularity image (override via IMAGE_PATH)
THREAD_LIST=${THREAD_LIST:-"4 8 12 16 24 32"} # thread counts to trial (override via THREAD_LIST)
REPS=${REPS:-2}                              # how many repeats per setting (override via REPS)
RUN_SCRIPT=${RUN_SCRIPT:-"./run_mriqc.sh"}   # path to MRIQC runner (override via RUN_SCRIPT)
# ---------------------------------------------------

# Change to dataset root
cd "$DATA_ROOT"

# If IMAGE_PATH is set, export SIF for run_mriqc.sh to pick up
if [[ -n "${IMAGE_PATH}" ]]; then
  export SIF="$IMAGE_PATH"
fi

# Convert THREAD_LIST string to array
read -r -a THREADS <<< "$THREAD_LIST"

declare -A ELAPSED                           # associative array to hold times
TIMEFORMAT='%R'                             # only capture the 'real' time (in seconds)

echo "Benchmarking MRIQC for sub-${SUBJ_LABEL}"
for threads in "${THREADS[@]}"; do
  for ((rep=1; rep<=REPS; rep++)); do
    echo -n "  [threads=$threads | run #$rep]  … "
    # Run and capture the time (stdout/stderr suppressed)
    t=$({ time "$RUN_SCRIPT" "$SUBJ_LABEL" "$threads" >/dev/null 2>&1; } 2>&1)
    echo "${t}s"
    ELAPSED["$threads,$rep"]=$t
  done
done

# Print a summary table with averages
echo -e "\n=== Elapsed times (seconds) ==="
printf "%-8s" "Threads"
for ((rep=1; rep<=REPS; rep++)); do
  printf "%8s" "Run#$rep"
done
printf "%8s" "Avg"
echo
printf '%0.s-' {1..8}
for ((i=0; i<REPS+1; i++)); do
  printf '%8s' '--------'
done
echo

for threads in "${THREADS[@]}"; do
  printf "%-8s" "$threads"
  sum=0
  for ((rep=1; rep<=REPS; rep++)); do
    t=${ELAPSED["$threads,$rep"]}
    printf "%8s" "$t"
    sum=$(awk -v a="$sum" -v b="$t" 'BEGIN{printf "%.6f", a+b}')
  done
  avg=$(awk -v total="$sum" -v n="$REPS" 'BEGIN{printf "%.3f", total/n}')
  printf "%8s" "$avg"
  echo
done
