#!/usr/bin/env bash
set -euo pipefail

# ——— Config ———
DATA_ROOT=$(pwd)
DERIV_DIR="${DATA_ROOT}/derivatives/mriqc"
mkdir -p "${DERIV_DIR}"

# ——— MRIQC call via direct Docker URI — no SIF file needed ———
singularity exec --cleanenv \
    --bind "${DATA_ROOT}:/data" \
    docker://nipreps/mriqc:latest \
    mriqc /data /data/derivatives/mriqc \
        participant \
        --participant-label "$@" \
        --n_procs 8 \
        --mem_gb 16
