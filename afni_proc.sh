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
# CHANGES (2025-04-28 to 05-01):
#   * Added automatic conversion of anatQQ NIfTI to AFNI (+tlrc) format.
#   * Auto-generate AFNI timing files from BIDS events.tsv.
#   * Use absolute TLRC_BASE path for template.
#   * Clean existing output directory so proc.*.sh runs fresh.
# -----------------------------------------------------------------------------

set -euo pipefail  # exit on error, undefined var, or pipe failure

# --- Argument Parsing ---
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <SUBJECT_LABEL> [N_CORES]"
  echo "       (e.g., FT, 01 - do not include 'sub-')"
  exit 1
fi

SUBJ_LABEL="$1"            # e.g., 01, FT (no 'sub-')
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

# --- TLRC template (MNI) ---
TLRC_BASE="/users/pl8n4/abin/MNI152_2009_template_SSW.nii.gz"

# --- Derivatives (@SSwarper outputs) ---
SSWARPER_DIR="derivatives/sswarper/${SUBJ_LABEL}"
ANAT_SS="${SSWARPER_DIR}/anatSS.${SUBJ_LABEL}.nii"

# Convert SSwarper .nii to AFNI +tlrc if needed
if [[ ! -f "${SSWARPER_DIR}/anatQQ.${SUBJ_LABEL}+tlrc.HEAD" ]]; then
  echo "Converting SSwarper output to AFNI format: anatQQ+tlrc"
  3dcopy "${SSWARPER_DIR}/anatQQ.${SUBJ_LABEL}.nii" \
         "${SSWARPER_DIR}/anatQQ.${SUBJ_LABEL}+tlrc"
fi
ANAT_QQ="${SSWARPER_DIR}/anatQQ.${SUBJ_LABEL}+tlrc"

ANAT_AFFINE="${SSWARPER_DIR}/anatQQ.${SUBJ_LABEL}.aff12.1D"
ANAT_WARP="${SSWARPER_DIR}/anatQQ.${SUBJ_LABEL}_WARP.nii"

# --- Generate AFNI 1D timing files from BIDS events.tsv ---
TASK="passiveimageviewing"
CONDITIONS=("food" "nonfood")
EVTS="${BIDS_SUBJ}/func/${BIDS_SUBJ}_task-${TASK}_events.tsv"
if [[ ! -f "${EVTS}" ]]; then
  echo "ERROR: events.tsv not found: ${EVTS}"
  exit 1
fi

echo "Generating timing files from ${EVTS} …"
for cond in "${CONDITIONS[@]}"; do
  out_1d="${BIDS_SUBJ}/${cond}.1D"
  awk -F $'\t' 'NR>1 && $3=="'"${cond}"'" {printf "%s ",$1} END {printf "\n"}' \
      "${EVTS}" > "$out_1d"
  echo "  → ${out_1d} ($(wc -w < "$out_1d") onsets)"
done
STIM_FOOD="${BIDS_SUBJ}/food.1D"
STIM_NONFOOD="${BIDS_SUBJ}/nonfood.1D"

# --- Define output directory ---
PROC_DIR="derivatives/afni_proc/${BIDS_SUBJ}"

# --- Input checks ---
echo "Checking for necessary inputs …"
[[ -f "${ANAT_SS}"     ]] || { echo "ERROR: Skull-stripped anat not found: ${ANAT_SS}"; exit 1; }
[[ -f "${ANAT_QQ}.HEAD" ]] || { echo "ERROR: AFNI anatQQ+tlrc not found: ${ANAT_QQ}+HEAD"; exit 1; }
[[ -f "${ANAT_AFFINE}" ]] || { echo "ERROR: Affine transform not found: ${ANAT_AFFINE}"; exit 1; }
[[ -f "${ANAT_WARP}"   ]] || { echo "ERROR: Nonlinear warp not found: ${ANAT_WARP}"; exit 1; }
[[ -f "${ANAT_ORIGINAL_NIFTI}" ]] || { echo "ERROR: T1w NIfTI not found: ${ANAT_ORIGINAL_NIFTI}"; exit 1; }
ls ${EPI_DSETS} 1>/dev/null 2>&1 || { echo "ERROR: EPI datasets not found: ${EPI_DSETS}"; exit 1; }
[[ -f "${STIM_FOOD}"    ]] || { echo "ERROR: Stim file missing: ${STIM_FOOD}"; exit 1; }
[[ -f "${STIM_NONFOOD}" ]] || { echo "ERROR: Stim file missing: ${STIM_NONFOOD}"; exit 1; }
[[ -f "${TLRC_BASE}"    ]] || { echo "ERROR: TLRC template not found: ${TLRC_BASE}"; exit 1; }

echo "Input checks passed."

# --- Clean previous outputs so proc.*.sh will run ---
if [[ -d "${PROC_DIR}" ]]; then
  echo "Removing existing output directory: ${PROC_DIR}"
  rm -rf "${PROC_DIR}"
fi

# --- Run afni_proc.py ---
afni_proc.py \
  -subj_id               "${SUBJ_LABEL}" \
  -out_dir               "${PROC_DIR}" \
  -scr_overwrite \
  -blocks                tshift align tlrc volreg mask blur scale regress \
  -copy_anat             "${ANAT_SS}" \
  -anat_has_skull        no \
  -anat_follower         anat_w_skull anat "${ANAT_ORIGINAL_NIFTI}" \
  -dsets                 ${EPI_DSETS} \
  -tcat_remove_first_trs 2 \
  -align_unifize_epi     local \
  -align_opts_aea        -cost lpc+ZZ -giant_move -check_flip \
  -tlrc_base             "${TLRC_BASE}" \
  -tlrc_NL_warp \
  -tlrc_NL_warped_dsets  "${ANAT_QQ}" "${ANAT_AFFINE}" "${ANAT_WARP}" \
  -volreg_align_to       MIN_OUTLIER \
  -volreg_align_e2a \
  -volreg_tlrc_warp \
  -volreg_compute_tsnr   yes \
  -mask_epi_anat         yes \
  -blur_size             4.0 \
  -regress_stim_times    "${STIM_FOOD}" "${STIM_NONFOOD}" \
  -regress_stim_labels   food nonfood \
  -regress_basis         'BLOCK(20,1)' \
  -regress_opts_3dD      -jobs "${NCORES}" -gltsym 'SYM: food -nonfood' -glt_label 1 F-NF \
  -regress_motion_per_run \
  -regress_censor_motion 0.3 \
  -regress_censor_outliers 0.05 \
  -regress_3dD_stop \
  -regress_reml_exec \
  -regress_compute_fitts \
  -regress_make_ideal_sum sum_ideal.1D \
  -regress_est_blur_epits \
  -regress_est_blur_errts \
  -regress_run_clustsim  no \
  -html_review_style     pythonic \
  -execute

# --- Final messages ---
echo -e "\n[INFO] afni_proc.py execution initiated for subject ${BIDS_SUBJ}."
echo "[INFO] Check proc script inside ${PROC_DIR}"
echo "[INFO] See log inside ${PROC_DIR}"
