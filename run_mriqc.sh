#!/usr/bin/env bash
set -euo pipefail

# === Configuration ===
DATA_ROOT=$(pwd)
DERIV_DIR="${DATA_ROOT}/derivatives/mriqc"
SIF="${DATA_ROOT}/mriqc_latest.sif"

# === Resource allocation ===
N_PROCS=8          # Adjust to match node cores
MEM_GB=16          # Adjust to match node memory

# === Run MRIQC ===
mkdir -p "${DERIV_DIR}"
export TMPDIR="${DATA_ROOT}/tmp"
mkdir -p "${TMPDIR}"

singularity exec --cleanenv \
    --bind "${DATA_ROOT}:/data" \
    --bind "${TMPDIR}:/tmp" \
    "${SIF}" \
    mriqc /data /data/derivatives/mriqc participant \
    --participant-label "$@" \
    --n_procs ${N_PROCS} \
    --mem_gb ${MEM_GB}
