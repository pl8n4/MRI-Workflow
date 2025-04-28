#!/usr/bin/env bash
# run_afni_proc.sh -- Preprocess fMRI data for a single subject using afni_proc.py
#
# This script adapts a standard afni_proc.py template to work with
# outputs from @SSwarper (run via run_sswarper.sh) and allows specifying
# the subject ID and number of cores.
#
# It assumes the script is run from the root directory of a BIDS-like dataset.
# Raw data is expected in BIDS format (e.g., sub-XX/anat/, sub-XX/func/).
# Derivatives from @SSwarper are expected in derivatives/sswarper/sub-XX/.
#
# -----------------------------------------------------------------------------
# CHANGES (2025-04-28):
#   * Replaced legacy AV1_vis / AV2_aud timing-file expectations with an
#     automatic conversion of the subject's BIDS events.tsv into AFNI 1D timing
#     files (food.1D and nonfood.1D).
#   * Updated stimulus-related input checks and afni_proc.py regression options
#     to use these generated timing files.
# -----------------------------------------------------------------------------

# --- Script Setup ---
set -euo pipefail          # exit on error, undefined var, or pipe failure

# --- Argument Parsing ---
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <SUBJECT_LABEL> [N_CORES]"
  echo "       (e.g., FT, 01 - do not include 'sub-')"
  exit 1
fi

SUBJ_LABEL="$1"                   # 01, FT, etc.
BIDS_SUBJ="sub-${SUBJ_LABEL}"
NCORES="${2:-8}"
export OMP_NUM_THREADS="$NCORES"

echo "--- Running AFNI Preprocessing ---"
echo "Subject Label: ${SUBJ_LABEL}"
echo "BIDS Subject ID: ${BIDS_SUBJ}"
echo "Number of Cores: ${NCORES}"
echo "----------------------------------"

# --- Define File Paths ---
ANAT_ORIGINAL_NIFTI="${BIDS_SUBJ}/anat/${BIDS_SUBJ}_T1w.nii.gz"
EPI_DSETS="${BIDS_SUBJ}/func/${BIDS_SUBJ}_task-*_bold.nii.gz"

# TLRC template (MNI)
TLRC_BASE="MNI152_2009_template_SSW.nii.gz"

# --- Derivatives (@SSwarper outputs) ---
SSWARPER_DIR="derivatives/sswarper/${SUBJ_LABEL}"
ANAT_SS="${SSWARPER_DIR}/anatSS.${SUBJ_LABEL}.nii"
ANAT_QQ="${SSWARPER_DIR}/anatQQ.${SUBJ_LABEL}.nii"
ANAT_AFFINE="${SSWARPER_DIR}/anatQQ.${SUBJ_LABEL}.aff12.1D"
ANAT_WARP="${SSWARPER_DIR}/anatQQ.${SUBJ_LABEL}_WARP.nii"

# =============================================================================
# === CHANGES: auto-generate AFNI timing files from BIDS events.tsv ==========
# =============================================================================
TASK="passiveimageviewing"            # adjust if your task name differs
CONDITIONS=("food" "nonfood")         # list each trial_type to model
EVTS="${BIDS_SUBJ}/func/${BIDS_SUBJ}_task-${TASK}_events.tsv"

if [[ ! -f "${EVTS}" ]]; then
  echo "ERROR: events.tsv not found: ${EVTS}"
  exit 1
fi

echo "Generating timing files from ${EVTS} …"
for cond in "${CONDITIONS[@]}"; do
  out_1d="${BIDS_SUBJ}/${cond}.1D"
  # overwrite to stay current at every run
  awk -F $'\t' 'NR>1 && $3=="'"${cond}"'" {printf "%s ",$1} END {printf "\n"}' \
      "${EVTS}" > "$out_1d"
  echo "  → ${out_1d} ($(wc -w < "$out_1d") onsets)"
done

STIM_FOOD="${BIDS_SUBJ}/food.1D"
STIM_NONFOOD="${BIDS_SUBJ}/nonfood.1D"
# =============================================================================

# --- Outputs ---
PROC_DIR="derivatives/afni_proc/${BIDS_SUBJ}"

# --- Check Input Files ---
echo "Checking for necessary inputs …"
# @SSwarper outputs
[[ -f "${ANAT_SS}"     ]] || { echo "ERROR: Skull-stripped anat not found: ${ANAT_SS}";     exit 1; }
[[ -f "${ANAT_QQ}"     ]] || { echo "ERROR: Warped anat (QQ) not found: ${ANAT_QQ}";        exit 1; }
[[ -f "${ANAT_AFFINE}" ]] || { echo "ERROR: Affine transform not found: ${ANAT_AFFINE}";   exit 1; }
[[ -f "${ANAT_WARP}"   ]] || { echo "ERROR: Nonlinear warp not found: ${ANAT_WARP}";       exit 1; }
# Raw BIDS files
[[ -f "${ANAT_ORIGINAL_NIFTI}" ]] || { echo "ERROR: Original T1w NIfTI not found: ${ANAT_ORIGINAL_NIFTI}"; exit 1; }
ls ${EPI_DSETS} 1>/dev/null 2>&1 || { echo "ERROR: EPI datasets not found matching pattern: ${EPI_DSETS}"; exit 1; }
# Stimulus timing files produced above
[[ -f "${STIM_FOOD}"    ]] || { echo "ERROR: Stim file not found: ${STIM_FOOD}";    exit 1; }
[[ -f "${STIM_NONFOOD}" ]] || { echo "ERROR: Stim file not found: ${STIM_NONFOOD}"; exit 1; }
# TLRC template
[[ -f "${TLRC_BASE}"    ]] || { echo "ERROR: TLRC base template not found: ${TLRC_BASE}"; exit 1; }

echo "Input checks passed."

# --- Run afni_proc.py ---
mkdir -p "${PROC_DIR}"

afni_proc.py \
    -subj_id                 "${SUBJ_LABEL}" \
    -out_dir                 "${PROC_DIR}" \
    -script                  "${PROC_DIR}/proc.${SUBJ_LABEL}.sh" \
    -scr_overwrite \
    -blocks                  tshift align tlrc volreg mask blur scale regress \
    -copy_anat               "${ANAT_SS}" \
    -anat_has_skull          no \
    -anat_follower           anat_w_skull anat "${ANAT_ORIGINAL_NIFTI}" \
    -dsets                   ${EPI_DSETS} \
    -tcat_remove_first_trs   2 \
    -align_unifize_epi       local \
    -align_opts_aea          -cost lpc+ZZ -giant_move -check_flip \
    -tlrc_base               "${TLRC_BASE}" \
    -tlrc_NL_warp \
    -tlrc_NL_warped_dsets    "${ANAT_QQ}" "${ANAT_AFFINE}" "${ANAT_WARP}" \
    -volreg_align_to         MIN_OUTLIER \
    -volreg_align_e2a \
    -volreg_tlrc_warp \
    -volreg_compute_tsnr     yes \
    -mask_epi_anat           yes \
    -blur_size               4.0 \
    # === CHANGES: use generated timing files ===
    -regress_stim_times      "${STIM_FOOD}" "${STIM_NONFOOD}" \
    -regress_stim_labels     food nonfood \
    -regress_basis           'BLOCK(20,1)' \
    -regress_opts_3dD        -jobs "${NCORES}" \
                             -gltsym 'SYM: food -nonfood' -glt_label 1 F-NF \
    -regress_motion_per_run \
    -regress_censor_motion   0.3 \
    -regress_censor_outliers 0.05 \
    -regress_3dD_stop \
    -regress_reml_exec \
    -regress_compute_fitts \
    -regress_make_ideal_sum  sum_ideal.1D \
    -regress_est_blur_epits \
    -regress_est_blur_errts \
    -regress_run_clustsim    no \
    -html_review_style       pythonic \
    -execute

echo -e "\n[INFO] afni_proc.py execution initiated for subject ${BIDS_SUBJ}."
echo "[INFO] Check the output directory: ${PROC_DIR}"
echo "[INFO] Monitor the proc script: ${PROC_DIR}/proc.${SUBJ_LABEL}.sh"
echo "[INFO] And the output log: ${PROC_DIR}/output.proc.${SUBJ_LABEL}"
