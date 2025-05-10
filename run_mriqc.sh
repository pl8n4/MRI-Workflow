#!/usr/bin/env bash
# run_mriqc.sh  —  Run MRIQC for one subject with configurable cores & memory
#
# USAGE: ./run_mriqc.sh <SUBJECT_LABEL> [N_CORES] [MEM_GB]
#   e.g. 08 16 32
#
# This script assumes it’s run from a BIDS‑root directory.
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

MYDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "${MYDIR}/workflow.conf"
cd "${BIDS_ROOT}"

SID="$1"
N_PROCS="${2:-8}"        # number of CPU threads          (override from CLI)
MEM_GB="${3:-10}"        # GB of RAM to request           (override from CLI)

# --- Paths & image ---
DERIV_DIR="${DERIV_ROOT}/mriqc"
SIF="${SIF_IMAGE}"

mkdir -p "${DERIV_ROOT}" "${DERIV_DIR}"

echo "--- MRIQC: sub-${SID} | cores=${N_PROCS} | mem=${MEM_GB}GB ---"

# Use a fresh TMPDIR and workdir to avoid cache reuse
export TMPDIR="${BIDS_ROOT}/tmp"
WORKDIR="${TMPDIR}/mriqc_work/sub-${SID}"
rm -rf "${WORKDIR}"
mkdir -p "${TMPDIR}" "${WORKDIR}"

# --- Run MRIQC via Singularity ----------------------------------------------
SINGULARITYENV_OMP_NUM_THREADS="${N_PROCS}" \
SINGULARITYENV_ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="${N_PROCS}" \
SINGULARITYENV_MKL_NUM_THREADS="${N_PROCS}" \
singularity exec --cleanenv \
    --bind "${BIDS_ROOT}:/data" \
    --bind "${WORKDIR}:/work" \
    "${SIF}" \
    mriqc /data /data/derivatives/mriqc participant \
      --participant-label "${SID}" \
      --n_procs        "${N_PROCS}" \
      --omp-nthreads   "${N_PROCS}" \
      --ants-nthreads  "${N_PROCS}" \
      --mem_gb         "${MEM_GB}"  \
      --work-dir       /work
