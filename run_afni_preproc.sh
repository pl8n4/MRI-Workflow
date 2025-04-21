#!/usr/bin/env bash
# ===========================================================================
# AFNI fMRI preprocessing (single‐subject, cluster version)
# Usage: ./run_afni_preproc_cluster.sh <SUBJECT_ID> [N_JOBS]
# ===========================================================================
set -euo pipefail

# ----------------------- ARGUMENTS & CORES -------------------------
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <subject ID> [<N_JOBS>]"
  exit 1
fi
SUBJ=$1
N_JOBS=${2:-10}
export OMP_NUM_THREADS=${OMP_NUM_THREADS:-$N_JOBS}

# ------------------------ DIRECTORY SETTINGS -----------------------
# Assume this script lives in the dataset root (e.g. ~/ds00XXXXX)
DATASET_ROOT="$(cd "$(dirname "$0")" && pwd)"
BIDS_ROOT="$DATASET_ROOT"
DERIV_ROOT="$DATASET_ROOT/derivatives"

# ---------------------- PREPROCESSING OPTIONS ----------------------
T_PATTERN="alt+z2"       # slice‐timing pattern
BLUR_SIZE=4.0              # smoothing FWHM (mm)
CENS_MOT=0.3               # motion censor threshold (FD, mm)
CENS_OUT=0.1               # outlier censor threshold (fraction)

# -------------------------- INFO HEADER ----------------------------
echo "=== AFNI preprocessing =========================="
echo "Dataset   : $DATASET_ROOT"
echo "Subject   : $SUBJ"
echo "Cores     : $OMP_NUM_THREADS"
echo "=============================================="

# ------------------------ WORKING DIRECTORY -----------------------
WORK_DIR="$DERIV_ROOT/afni_preproc/sub-${SUBJ}"
mkdir -p "$WORK_DIR" && cd "$WORK_DIR"

# ------------------------ INPUT FILES -----------------------------
FUNC_DSETS=$(ls "$BIDS_ROOT/sub-${SUBJ}/func/"*task-*_bold.nii* | sort)
ANAT_DSET=$(ls "$BIDS_ROOT/sub-${SUBJ}/anat/"*T1w.nii* | head -n1)

# ----------------------- AFNI_PROC COMMAND ------------------------
afni_proc.py \
    -subj_id            ${SUBJ} \
    -script             proc.${SUBJ}.tcsh \
    -out_dir            results \
    -dsets              ${FUNC_DSETS} \
    -copy_anat          ${ANAT_DSET} \
    -anat_has_skull     no \
    -blocks despike tshift align tlrc volreg blur mask scale regress \
    -tshift_opts_ts     -tpattern ${T_PATTERN} \
    -align_opts_aea     -giant_move -check_flip \
    -tlrc_base          MNI_avg152T1+tlrc \
    -tlrc_NL_warp \
    -volreg_align_to    MIN_OUTLIER \
    -volreg_align_e2a \
    -volreg_tlrc_warp \
    -blur_size          ${BLUR_SIZE} \
    -mask_apply         epi \
    -regress_stim_times "$BIDS_ROOT/sub-${SUBJ}/func/sub-${SUBJ}_task-*_events.tsv" \
    -regress_stim_labels  cond1 cond2 \
    -regress_basis_multi 'BLOCK(4,1)' 'BLOCK(4,1)' \
    -regress_motion_per_run \
    -regress_censor_motion  ${CENS_MOT} \
    -regress_censor_outliers ${CENS_OUT} \
    -regress_est_blur_epits \
    -regress_est_blur_errts \
    -html_review_style   pythonic \
    -jobs               ${N_JOBS} \
    -execute

echo "✓ Finished sub-${SUBJ} → ${WORK_DIR}/results"
