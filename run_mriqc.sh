#!/usr/bin/env bash
# run_mriqc.sh  —  Run MRIQC for one subject with configurable cores & memory
#
# USAGE: ./run_mriqc.sh <SUBJECT_LABEL> [N_CORES] [MEM_GB]
#   e.g. 08 16 32
#
# This script assumes it’s run from a BIDS‐root directory.
# Outputs go into derivatives/mriqc, and tmp files into ./tmp.

set -euo pipefail

# --- Argument parsing ---
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <SUBJECT_LABEL> [N_CORES] [MEM_GB]"
  echo "  <SUBJECT_LABEL>    e.g. 08 (do not include 'sub-')"
  echo "  [N_CORES]          parallel processes (default: 8)"
  echo "  [MEM_GB]           memory per subject in GB (default: 16)"
  exit 1
fi

SUBJ_LABEL="$1"
N_PROCS="${2:-8}"        # number of CPU threads          (override from CLI)
MEM_GB="${3:-10}"        # GB of RAM to request           (override from CLI)

# --- Paths & image ---
DATA_ROOT="$(pwd)"
DERIV_DIR="${DATA_ROOT}/derivatives/mriqc"
SIF="${DATA_ROOT}/mriqc_latest.sif"

# --- Prep directories & env ---
echo "--- MRIQC: sub-${SUBJ_LABEL} | cores=${N_PROCS} | mem=${MEM_GB}GB ---"
mkdir -p "${DERIV_DIR}"
export TMPDIR="${DATA_ROOT}/tmp"
mkdir -p "${TMPDIR}"

# --- Run MRIQC via Singularity ---
singularity exec --cleanenv \
    --bind "${DATA_ROOT}:/data" \
    --bind "${TMPDIR}:/tmp" \
    "${SIF}" \
    mriqc /data /data/derivatives/mriqc participant \
      --participant-label "${SUBJ_LABEL}" \
      --n_procs "${N_PROCS}" \
      --mem_gb "${MEM_GB}"
