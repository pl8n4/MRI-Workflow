#!/usr/bin/env bash
# benchmark_afni_proc.sh
# Loops over a set of thread counts and repeats,
# times afni_proc.sh, and prints a summary table.

set -euo pipefail

# user parameters
SUBJ_LABEL=${1:-08}                 # subject to test, default = 08
THREADS=(4 8 12 16 24 32)           # thread counts to trial
REPS=2                              # how many repeats per setting


declare -A ELAPSED                   # associative array to hold times
TIMEFORMAT='%R'                     # only capture the 'real' time (in seconds)

echo "Benchmarking AFNI processing for sub-${SUBJ_LABEL}"
for threads in "${THREADS[@]}"; do
  for ((rep=1; rep<=REPS; rep++)); do
    echo -n "  [threads=$threads | run #$rep]  … "
    # Run and capture the time (stdout/stderr suppressed here)
    t=$( { time ./afni_proc.sh "$SUBJ_LABEL" "$threads" >/dev/null 2>&1; } 2>&1 )
    echo "${t}s"
    ELAPSED["$threads,$rep"]=$t
  done
done

# Print a summary table
echo -e "\n=== Elapsed times (seconds) ==="
printf "%-8s" "Threads"
for ((rep=1; rep<=REPS; rep++)); do
  printf "%8s" "Run#$rep"
done
echo
printf '%0.s-' {1..8}
for ((rep=1; rep<=REPS; rep++)); do
  printf '%8s' '--------'
done
echo

for threads in "${THREADS[@]}"; do
  printf "%-8s" "$threads"
  for ((rep=1; rep<=REPS; rep++)); do
    printf "%8s" "${ELAPSED["$threads,$rep"]}"
  done
  echo
done
