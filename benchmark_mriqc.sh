#!/usr/bin/env bash
set -euo pipefail

# ----------------------------- User‑tunable vars ----------------------------
DATA_ROOT="${DATA_ROOT:-$PWD}"

# <-- MODIFIED: Using local SIF image -->
IMG="${IMG:-${DATA_ROOT}/mriqc_latest.sif}"

declare -a THREADS=(${THREADS:-"1 2 3 4 8 12 16 24 32"})
REPS="${REPS:-2}"
SUBJ="${1:-08}"
BIDS_SUBJ="sub-${SUBJ}"

# Ceiling(thread*1.5) memory heuristic
mem_guess() {
  local t=$1
  echo $(( (t * 3 + 1) / 2 ))
}

declare -A TIMES
declare -A SUM
bc_fmt='%.5f'

echo "=== MRIQC benchmark : subject ${BIDS_SUBJ}  |  image=${IMG}"
echo "Data root : ${DATA_ROOT}"
echo "Threads    : ${THREADS[*]}"
echo "Reps/run   : ${REPS}"
echo "-----------------------------------------------------------------"

for thr in "${THREADS[@]}"; do
  SUM[$thr]=0
  TIMES[$thr]=""
  for ((r=1; r<=REPS; r++)); do
    mem=$(mem_guess "$thr")

    # <-- MODIFIED: using singularity exec and local SIF image -->
    time_out=$({ time -p singularity exec --cleanenv \
                      -B "${DATA_ROOT}:/data" "${IMG}" \
                      mriqc /data /data/derivatives/mriqc participant \
                      --participant-label "${SUBJ}" \
                      --n_procs "${thr}" \
                      --mem_gb "${mem}" > /dev/null 2>&1; } 2>&1)

    real_sec=$(awk '/^real /{print $2}' <<< "${time_out}")
    SUM[$thr]=$(printf "$bc_fmt\n" "$(bc -l <<< "${SUM[$thr]} + ${real_sec}")")
    TIMES[$thr]="${TIMES[$thr]} ${real_sec}"
    echo "[thr=${thr}] rep ${r}/${REPS} : ${real_sec} s"
  done
done

printf "\n%-7s" "thr"
for ((r=1; r<=REPS; r++)); do printf " %10s" "run${r}"; done
printf " %10s\n" "avg_s"

printf -- "-------"
for ((i=1; i<=REPS+1; i++)); do printf " %10s" "----------"; done
printf "\n"

for thr in "${THREADS[@]}"; do
  read -ra tlist <<< "${TIMES[$thr]}"
  printf "%-7s" "${thr}"
  for val in "${tlist[@]}"; do
    printf " %10.3f" "${val}"
  done
  avg=$(bc -l <<< "${SUM[$thr]} / ${REPS}")
  printf " %10.3f\n" "${avg}"
done
