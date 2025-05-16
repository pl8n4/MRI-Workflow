#!/usr/bin/env bash
#
# afni_proc.sh -- Preprocess fMRI data for a single subject using afni_proc.py
#
# This script adapts a standard afni_proc.py template to work with
# outputs from @SSwarper and allows specifying
# the subject ID and number of cores.
#
# With differet datasets, users would need to change timing and event config to match
# the specific study
#
# Usage: ./afni_proc.sh <SUBJECT_ID> [N_CORES]

set -euo pipefail

# Argument Parsing
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <SUBJECT_LABEL> [N_CORES]"
  echo "       (e.g., FT, 01 - do not include 'sub-')"
  exit 1
fi

# tmpdir with lots of disk space
export TMPDIR=/mydata/afni_tmp

MYDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "${MYDIR}/workflow.conf"
cd "${BIDS_ROOT}"

SID="$1"
BIDS_SUBJ="sub-${SID}"
NCORES="${2:-8}"
export OMP_NUM_THREADS="$NCORES"

echo "--- Running AFNI Preprocessing ---"
echo "Subject Label: ${SID}"
echo "BIDS Subject ID: ${BIDS_SUBJ}"
echo "Number of Cores: ${NCORES}"
echo "----------------------------------"

# Define File Paths
ANAT_ORIGINAL_NIFTI="${BIDS_SUBJ}/anat/${BIDS_SUBJ}_T1w.nii.gz"
EPI_DSETS="${BIDS_SUBJ}/func/${BIDS_SUBJ}_task-*_bold.nii.gz"

# TLRC template (MNI)
TLRC_BASE="MNI152_2009_template_SSW.nii.gz"

# Derivatives (@SSwarper outputs)
SSWARPER_DIR="derivatives/sswarper/${SID}"
ANAT_SS="${SSWARPER_DIR}/anatSS.${SID}.nii"

# Convert SSwarper .nii to AFNI +tlrc if needed
if [[ ! -f "${SSWARPER_DIR}/anatQQ.${SID}+tlrc.HEAD" ]]; then
  echo "Converting SSwarper output to AFNI format: anatQQ+tlrc"
  3dcopy "${SSWARPER_DIR}/anatQQ.${SID}.nii" \
         "${SSWARPER_DIR}/anatQQ.${SID}+tlrc"
fi
ANAT_QQ="${SSWARPER_DIR}/anatQQ.${SID}+tlrc"

ANAT_AFFINE="${SSWARPER_DIR}/anatQQ.${SID}.aff12.1D"
ANAT_WARP="${SSWARPER_DIR}/anatQQ.${SID}_WARP.nii"

# Generate AFNI 1D timing files from BIDS events.tsv
# Users would want to change conditions from food/nonfood to whatever stimulus the study uses.
# Make sure to go also change the flags.
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

# Define output directory
PROC_DIR="derivatives/afni_proc/${BIDS_SUBJ}"

# Input checks
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

# Clean previous outputs so proc.*.sh will run
if [[ -d "${PROC_DIR}" ]]; then
  echo "Removing existing output directory: ${PROC_DIR}"
  rm -rf "${PROC_DIR}"
fi

# Run afni_proc.py
afni_proc.py \
  -subj_id               "${SID}" \
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
  -regress_apply_mot_types demean deriv \
  -regress_censor_motion 0.2 \
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

echo -e "\n[INFO] afni_proc.py execution initiated for subject ${BIDS_SUBJ}."
echo "[INFO] Check proc script inside ${PROC_DIR}"
echo "[INFO] See log inside ${PROC_DIR}"
