#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  benchmark_mriqc.sh  —  Empirically benchmark MRIQC runtime vs. thread count
# ---------------------------------------------------------------------------
#  Usage:  ./benchmark_mriqc.sh [SUBJECT_LABEL]
#
#  * Loops over THREADS array (see below) and repeats each run REPS times.
#  * Captures wall‑clock seconds with Bash’s built‑in `time -p`.
#  * Prints an ASCII summary table compatible with benchmark_sswarper.sh and
#    benchmark_afni_proc.sh.
#
#  Environment overrides
#  ---------------------
#    DATA_ROOT   : BIDS dataset root   (default = $PWD)
#    IMG         : Singularity image   (default = poldracklab/mriqc:23.2.0)
#    THREADS     : space‑delimited list of thread counts
#    REPS        : # of repetitions per thread count
#
#  Requirements
#  ------------
#    * Singularity/Apptainer on $PATH
#    * Bash ≥4 for associative arrays
#
#  Notes
#  -----
#    * MRIQC output is sent to ${DATA_ROOT}/derivatives/mriqc
#    * Stdout/err from MRIQC is suppressed during timing to keep logs clean.
# ---------------------------------------------------------------------------

set -euo pipefail

# ----------------------------- User‑tunable vars ----------------------------
DATA_ROOT="${DATA_ROOT:-$PWD}"
IMG="${IMG:-poldracklab/mriqc:23.2.0}"

# THREADS can be overridden via env: THREADS="2 4 8" ./benchmark_mriqc.sh
declare -a THREADS=(${THREADS:-"1 2 3 4 8 12 16 24 32"})
REPS="${REPS:-2}"
SUBJ="${1:-08}"                      # BIDS label without "sub-"
BIDS_SUBJ="sub-${SUBJ}"

# Ceiling(thread*1.5) memory heuristic
mem_guess() {
  local t=$1
  echo $(( (t * 3 + 1) / 2 ))
}

# ---------------------------- Runtime containers ----------------------------
declare -A TIMES           # concatenated list of run times per thread
declare -A SUM             # running sum of times per thread (float via bc)
bc_fmt='%.5f'

# ------------------------------- Benchmarking ------------------------------
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
    time_out=$({ time -p singularity run -B "${DATA_ROOT}:/data" "${IMG}" \
                  /data /data/derivatives/mriqc participant               \
                  --participant-label "${SUBJ}" --n_procs "${thr}"        \
                  --mem_gb "${mem}" > /dev/null 2>&1; } 2>&1)
    real_sec=$(awk '/^real /{print $2}' <<< "${time_out}")
    # accumulate
    SUM[$thr]=$(printf "$bc_fmt\n" "$(bc -l <<< "${SUM[$thr]} + ${real_sec}")")
    TIMES[$thr]="${TIMES[$thr]} ${real_sec}"
    echo "[thr=${thr}] rep ${r}/${REPS} : ${real_sec} s"
  done
done

# --------------------------------- Summary ---------------------------------
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
  # average
  avg=$(bc -l <<< "${SUM[$thr]} / ${REPS}")
  printf " %10.3f\n" "${avg}"
done