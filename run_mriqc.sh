#!/usr/bin/env bash
# run_mriqc.sh  –  QC raw BIDS data with MRIQC (participant mode)
set -euo pipefail
DATA_ROOT=$(pwd)                  # dataset root (BIDS)
DERIV_DIR="${DATA_ROOT}/derivatives/mriqc"
N_CPUS="${N_CPUS:-8}"             # threads per subject
MEM_GB="${MEM_GB:-16}"            # memory per subject

# Usage: ./run_mriqc.sh 08 09 10      # participant labels, *no* sub- prefix
singularity run -B "${DATA_ROOT}:/data" \
    poldracklab/mriqc:23.2.0 /data /data/derivatives/mriqc participant \
    --participant-label "$@" \
    --n_procs "${N_CPUS}" --mem_gb "${MEM_GB}"
