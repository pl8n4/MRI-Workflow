#!/usr/bin/env bash
# --------------------------------------------------------------------------
# afni_proc.sh  --  Process a single subject’s fMRI data with AFNI
# Expects SSwarper output in derivatives/sswarper/<SUBJECT_ID>
# USAGE         : chmod +x afni_proc.sh
#                 ./afni_proc.sh <SUBJECT_ID> [N_CORES]
# EXAMPLE       : ./afni_proc.sh 08 6
# --------------------------------------------------------------------------

set -euo pipefail

# --- Handle inputs ---
if [[ $# -lt 1 ]]; then
    echo "Error: subject ID missing" >&2
    echo "Usage: $0 <SUBJECT_ID> [N_CORES]" >&2
    exit 1
fi
SUBJ_ID="$1"            # e.g. 08 (no 'sub-' prefix)
N_CORES="${2:-2}"       # number of threads (default: 2)

# --- Define paths ---
SSW_DIR="derivatives/sswarper/${SUBJ_ID}"
BIDS_SUBJ="sub-${SUBJ_ID}"

ANAT_SS     = "${SSW_DIR}/anatSS.${SUBJ_ID}.nii"                # skull‐stripped anatomy
ANAT_NATIVE = "${BIDS_SUBJ}/anat/${BIDS_SUBJ}_T1w.nii.gz"        # native T1w with skull
ANAT_QW     = "${SSW_DIR}/anatQQ.${SUBJ_ID}.nii"                # nonlinear‐warped anat
AFF12       = "${SSW_DIR}/anatQQ.${SUBJ_ID}.aff12.1D"           # affine matrix
WARP        = "${SSW_DIR}/anatQQ.${SUBJ_ID}_WARP.nii"           # nonlinear warp field

# --- Functional & timing ---
EPI_DS        = "${BIDS_SUBJ}/func/${BIDS_SUBJ}_task-*_*bold.nii.gz"
STIM1_TIMING  = "${BIDS_SUBJ}/beh/AV1_vis.txt"
STIM2_TIMING  = "${BIDS_SUBJ}/beh/AV2_aud.txt"
STIM_LABELS   = ( vis aud )

# --- Launch afni_proc.py ---
afni_proc.py \
    -subj_id                "${SUBJ_ID}" \
    -copy_anat              "${ANAT_SS}" \
    -anat_has_skull         no \
    -anat_follower          anat_w_skull anat "${ANAT_NATIVE}" \
    -dsets                  ${EPI_DS} \
    -blocks                 tshift align tlrc volreg mask blur scale regress \
    -radial_correlate_blocks tcat volreg \
    -tcat_remove_first_trs  2 \
    -align_unifize_epi      local \
    -align_opts_aea         -cost lpc+ZZ -giant_move -check_flip \
    -tlrc_base              MNI152_2009_template_SSW.nii.gz \
    -tlrc_NL_warp \
    -tlrc_NL_warped_dsets   "${ANAT_QW}" "${AFF12}" "${WARP}" \
    -volreg_align_to        MIN_OUTLIER \
    -volreg_align_e2a \
    -volreg_tlrc_warp \
    -volreg_compute_tsnr    yes \
    -mask_epi_anat          yes \
    -blur_size              4.0 \
    -regress_stim_times     "${STIM1_TIMING}" "${STIM2_TIMING}" \
    -regress_stim_labels    "${STIM_LABELS[@]}" \
    -regress_basis          'BLOCK(20,1)' \
    -regress_opts_3dD       -jobs "${N_CORES}" \
                            -gltsym 'SYM: vis -aud' \
                            -glt_label 1 V-A \
    -regress_motion_per_run \
    -regress_censor_motion  0.3 \
    -regress_censor_outliers 0.05 \
    -regress_3dD_stop \
    -regress_reml_exec \
    -regress_compute_fitts \
    -regress_make_ideal_sum sum_ideal.1D \
    -regress_est_blur_epits \
    -regress_est_blur_errts \
    -regress_run_clustsim   no \
    -html_review_style      pythonic \
    -execute

# Done

echo "[INFO] Finished processing subject ${SUBJ_ID}"
```

