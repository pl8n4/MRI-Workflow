#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 TOTAL_JOBS MEM_PER_JOB_GB"
  exit 1
fi

TOTAL_JOBS="$1"
MEM_PER_JOB_GB="$2"

# 1) Resources
NUM_CORES=$(nproc)
TOTAL_RAM_GB=$(awk '/MemTotal/ {printf "%.2f", $2/1024/1024}' /proc/meminfo)

# 2) RAM-based parallelism (90% of RAM)
USABLE_RAM_GB=$(awk "BEGIN {printf \"%.2f\", $TOTAL_RAM_GB * 0.9}")
MAX_MEM_JOBS=$(awk "BEGIN {print int($USABLE_RAM_GB / $MEM_PER_JOB_GB)}")
(( MAX_MEM_JOBS < 1 )) && MAX_MEM_JOBS=1

# 3) How many will actually run at once?
if (( MAX_MEM_JOBS < TOTAL_JOBS )); then
  PARALLEL_JOBS=$MAX_MEM_JOBS
else
  PARALLEL_JOBS=$TOTAL_JOBS
fi

# 4) Compute threads per job, reserving 2 cores
RESERVE_CORES=2
USABLE_CORES=$(( NUM_CORES - RESERVE_CORES ))
(( USABLE_CORES < 1 )) && USABLE_CORES=1

TPJ=$(( USABLE_CORES / PARALLEL_JOBS ))
(( TPJ > 16 )) && TPJ=16
(( TPJ < 1 ))  && TPJ=1

# 5) Batches needed
BATCHES=$(( (TOTAL_JOBS + MAX_MEM_JOBS - 1) / MAX_MEM_JOBS ))

# 6) Output
echo "Threads per job:          $TPJ"
echo "Max parallel jobs (RAM):  $MAX_MEM_JOBS"
echo "Full batches needed:      $BATCHES"
