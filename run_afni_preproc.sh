#!/usr/bin/env bash
# ============================================================================
# AFNI fMRI preprocessing (Example 6b‑style, cluster/cloud version)
# Usage: ./run_afni_preproc_6b.sh <SUBJECT_ID> [N_JOBS]
# ---------------------------------------------------------------------------
#  * Designed to live in the root of your BIDS dataset directory (ds000xxx)
#  * Keeps the Example 6b options intact while making all paths dynamic.
#  * Requires that you have already run @SSwarper for each subject, such that
#    the warped/anatQQ* files live under $DERIV_ROOT/sswarper/sub-<ID>/.
#  * Tested on CloudLab Ubuntu20 nodes with AFNI ≥ 24.0.00.
# ============================================================================
set -euo pipefail

# ----------------------- ARGUMENTS & CORES ----------------------------------
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <SUBJECT_ID> [<N_JOBS>]" >&2
  exit 1
fi
SUBJ=$1                # e.g. 05 (without the "sub-" prefix)
N_JOBS=${2:-10}        # default to 10 CPU threads if not given
export OMP_NUM_THREADS=${OMP_NUM_THREADS:-$N_JOBS}

# ----------------------- DIRECTORY SETTINGS ---------------------------------
# Assume this script lives in the dataset root (~/ds000157, etc.)
DATASET_ROOT="$(cd "$(dirname "$0")" && pwd)"
BIDS_ROOT="$DATASET_ROOT"
DERIV_ROOT="$DATASET_ROOT/derivatives"

# Where your @SSwarper outputs live (edit if you store them elsewhere)
QWARP_DIR="$DERIV_ROOT/sswarper/sub-${SUBJ}/anat_warped"

# ------------------------- INFO HEADER --------------------------------------
cat <<EOF
=== AFNI preprocessing (Example 6b) =========================================
Dataset   : $DATASET_ROOT
Subject   : $SUBJ
Cores     : $OMP_NUM_THREADS
============================================================================
EOF

# ------------------------ WORKING DIRECTORY ---------------------------------
WORK_DIR="$DERIV_ROOT/afni_preproc_6b/sub-${SUBJ}"
mkdir -p "$WORK_DIR" && cd "$WORK_DIR"

# --------------------------- INPUT FILES ------------------------------------
FUNC_DSETS=$(ls "$BIDS_ROOT/sub-${SUBJ}/func/"*task-*bold.nii* | sort)
ANAT_ORIG=$(ls "$BIDS_ROOT/sub-${SUBJ}/anat/"*T1w.nii* | head -n1)

# @SSwarper outputs (skull‑stripped + non‑linear warp dsets)
ANAT_SS="$QWARP_DIR/anatSS.${SUBJ}.nii"
ANAT_QWARP="$QWARP_DIR/anatQQ.${SUBJ}.nii"
AFF12="$QWARP_DIR/anatQQ.${SUBJ}.aff12.1D"
WARP="$QWARP_DIR/anatQQ.${SUBJ}_WARP.nii"

# Stim timing files (edit the glob pattern or list manually if needed)
STIM_FILES=( $(ls "$BIDS_ROOT/sub-${SUBJ}/func/"*events*.txt 2>/dev/null || true) )

# -------------------------- AFNI_PROC COMMAND -------------------------------
afni_proc.py \
    -subj_id                  ${SUBJ} \
    -script                   proc.${SUBJ}.tcsh \
    -out_dir                  results \
    -copy_anat                ${ANAT_SS} \
    -anat_has_skull           no \
    -anat_follower            anat_w_skull anat ${ANAT_ORIG} \
    -dsets                    ${FUNC_DSETS} \
    -blocks                   tshift align tlrc volreg mask blur scale regress \
    -radial_correlate_blocks  tcat volreg \
    -tcat_remove_first_trs    2 \
    -align_unifize_epi        local \
    -align_opts_aea           -cost lpc+ZZ -giant_move -check_flip \
    -tlrc_base                MNI152_2009_template_SSW.nii.gz \
    -tlrc_NL_warp \
    -tlrc_NL_warped_dsets     ${ANAT_QWARP} ${AFF12} ${WARP} \
    -volreg_align_to          MIN_OUTLIER \
    -volreg_align_e2a \
    -volreg_tlrc_warp \
    -volreg_compute_tsnr      yes \
    -mask_epi_anat            yes \
    -blur_size                4.0 \
    -regress_stim_times       ${STIM_FILES[*]} \
    -regress_stim_labels      vis aud \
    -regress_basis            'BLOCK(20,1)' \
    -regress_opts_3dD         -jobs ${N_JOBS} -gltsym 'SYM: vis -aud' -glt_label 1 V-A \
    -regress_motion_per_run \
    -regress_censor_motion    0.3 \
    -regress_censor_outliers  0.05 \
    -regress_3dD_stop \
    -regress_reml_exec \
    -regress_compute_fitts \
    -regress_make_ideal_sum   sum_ideal.1D \
    -regress_est_blur_epits \
    -regress_est_blur_errts \
    -regress_run_clustsim     no \
    -html_review_style        pythonic \
    -execute

# ----------------------------- DONE -----------------------------------------
echo "✓ Finished sub-${SUBJ} → ${WORK_DIR}/results"
