#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 TOTAL_JOBS MEM_PER_JOB_GB"
  exit 1
fi

TOTAL_JOBS="$1"
MEM_PER_JOB_GB="$2"

# 1) Detect total logical CPU cores
NUM_CORES=$(nproc)

# 2) Detect total system RAM in GB
TOTAL_RAM_GB=$(awk '/MemTotal/ {printf "%.2f", $2/1024/1024}' /proc/meminfo)

# 3) Compute threads-per-job: evenly divide cores, cap at 16
TPJ=$(( NUM_CORES / TOTAL_JOBS ))
if (( TPJ > 16 )); then
  TPJ=16
fi

# 4) Compute max parallel jobs under 90%–RAM constraint
USABLE_RAM_GB=$(awk "BEGIN {printf \"%.2f\", $TOTAL_RAM_GB * 0.9}")
MAX_MEM_JOBS=$(awk "BEGIN {print int($USABLE_RAM_GB / $MEM_PER_JOB_GB)}")

# 5) Compute how many full batches are needed
if (( MAX_MEM_JOBS > 0 )); then
  BATCHES=$(( (TOTAL_JOBS + MAX_MEM_JOBS - 1) / MAX_MEM_JOBS ))
else
  BATCHES=0
fi

# 6) Print results
echo "Threads per job:          $TPJ"
echo "Max parallel jobs (RAM):  $MAX_MEM_JOBS"
echo "Full batches needed:      $BATCHES"
