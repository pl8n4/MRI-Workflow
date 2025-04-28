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
# Stimulus timing files are assumed to be in the subject's root folder (e.g. sub-XX/AV1_vis.txt)
# based on the original template - adjust if they are elsewhere (e.g., derivatives, stimuli folder).
#
# USAGE: ./run_afni_proc.sh <SUBJECT_LABEL> [N_CORES]
#        Example: ./run_afni_proc.sh FT 8
#                 ./run_afni_proc.sh 01 12

# --- Script Setup ---
# Exit immediately if a command exits with a non-zero status.
set -e
# Treat unset variables as an error when substituting.
set -u
# Pipe failures should exit the script
set -o pipefail

# --- Argument Parsing ---
# Check if subject ID is provided
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <SUBJECT_LABEL> [N_CORES]"
  echo "       (e.g., FT, 01 - do not include 'sub-')"
  echo "Error: Subject label is required."
  exit 1
fi

# Assign arguments to variables
# Subject Label (e.g., FT, 01)
SUBJ_LABEL="$1"
# BIDS Subject ID (e.g., sub-FT, sub-01)
BIDS_SUBJ="sub-${SUBJ_LABEL}"
# Number of cores for parallel processing (default to 8 if not specified)
NCORES="${2:-8}"
# Export OMP_NUM_THREADS for AFNI multi-threading
export OMP_NUM_THREADS="$NCORES"

echo "--- Running AFNI Preprocessing ---"
echo "Subject Label: ${SUBJ_LABEL}"
echo "BIDS Subject ID: ${BIDS_SUBJ}"
echo "Number of Cores: ${NCORES}"
echo "----------------------------------"

# --- Define File Paths ---
# Assumes script is run from the BIDS dataset root directory.

# --- Inputs ---
# Original anatomical T1w (input to @SSwarper, likely NIfTI format)
# Used as the 'anat_follower' for QC purposes. Assumes it's in BIDS format.
ANAT_ORIGINAL_NIFTI="${BIDS_SUBJ}/anat/${BIDS_SUBJ}_T1w.nii.gz"
# If you have an AFNI format version (+orig) you prefer for follower, use:
# ANAT_ORIGINAL_AFNI="${BIDS_SUBJ}/anat/${BIDS_SUBJ}_T1w+orig"
# We'll use the NIfTI version by default for BIDS compliance.

# EPI datasets (functional runs)
# Assumes BIDS format: sub-XX/func/sub-XX_task-<name>_run-<index>_bold.nii.gz
# Using wildcard '*' for task and run index. Adjust if your naming differs.
# NOTE: afni_proc.py can often handle NIfTI directly. The template used +orig.HEAD,
#       but we assume BIDS NIfTI inputs here. If you MUST use AFNI format inputs,
#       change the pattern accordingly (e.g., *_bold+orig.HEAD).
EPI_DSETS="${BIDS_SUBJ}/func/${BIDS_SUBJ}_task-*_bold.nii.gz"

# Stimulus timing files
# IMPORTANT: Assumes stim files are in the subject's root directory (e.g., sub-FT/AV1_vis.txt)
#            based on the original template's structure (FT/AV1_vis.txt).
#            Adjust this path if your stim files are elsewhere (e.g., derivatives/stimuli, sourcedata).
STIM_VIS="${BIDS_SUBJ}/AV1_vis.txt"
STIM_AUD="${BIDS_SUBJ}/AV2_aud.txt"

# TLRC template (MNI) - Assumes this file is accessible in the path or specify full path
# This path remains unchanged.
TLRC_BASE="MNI152_2009_template_SSW.nii.gz"

# --- Derivatives (from @SSwarper) ---
# NOTE: These paths use SUBJ_LABEL (${SID} in the previous script) based on the
#       provided run_sswarper.sh script's output naming convention.
#       If your @SSwarper script saves outputs using BIDS_SUBJ (sub-XX), update these.
SSWARPER_DIR="derivatives/sswarper/${BIDS_SUBJ}" # Output dir uses BIDS ID
ANAT_SS="${SSWARPER_DIR}/anatSS.${SUBJ_LABEL}.nii"         # Skull-stripped anat (used in -copy_anat)
ANAT_QQ="${SSWARPER_DIR}/anatQQ.${SUBJ_LABEL}.nii"         # Warped anatomical (for NL-warp)
ANAT_AFFINE="${SSWARPER_DIR}/anatQQ.${SUBJ_LABEL}.aff12.1D" # Affine matrix (for NL-warp)
ANAT_WARP="${SSWARPER_DIR}/anatQQ.${SUBJ_LABEL}_WARP.nii"   # Nonlinear warp field (for NL-warp)

# --- Outputs (from afni_proc.py) ---
# Output directory for afni_proc.py results, follows BIDS derivatives convention
PROC_DIR="derivatives/afni_proc/${BIDS_SUBJ}"

# --- Check Input Files ---
# Basic check to ensure necessary input files/dirs exist before running
echo "Checking for necessary inputs..."
# Check @SSwarper derivatives
if [ ! -f "${ANAT_SS}" ]; then echo "ERROR: Skull-stripped anat not found: ${ANAT_SS}"; exit 1; fi
if [ ! -f "${ANAT_QQ}" ]; then echo "ERROR: Warped anat (QQ) not found: ${ANAT_QQ}"; exit 1; fi
if [ ! -f "${ANAT_AFFINE}" ]; then echo "ERROR: Affine transform not found: ${ANAT_AFFINE}"; exit 1; fi
if [ ! -f "${ANAT_WARP}" ]; then echo "ERROR: Nonlinear warp not found: ${ANAT_WARP}"; exit 1; fi
# Check raw BIDS files
if [ ! -f "${ANAT_ORIGINAL_NIFTI}" ]; then echo "ERROR: Original T1w NIfTI not found: ${ANAT_ORIGINAL_NIFTI}"; exit 1; fi
# Check EPI files (use ls pattern matching)
if ! ls ${EPI_DSETS} 1> /dev/null 2>&1; then echo "ERROR: EPI datasets not found matching pattern: ${EPI_DSETS}"; exit 1; fi
# Check Stimulus files (adjust path if necessary)
if [ ! -f "${STIM_VIS}" ]; then echo "ERROR: Visual stim file not found: ${STIM_VIS}"; exit 1; fi
if [ ! -f "${STIM_AUD}" ]; then echo "ERROR: Auditory stim file not found: ${STIM_AUD}"; exit 1; fi
# Check TLRC template
if [ ! -f "${TLRC_BASE}" ]; then echo "ERROR: TLRC base template not found: ${TLRC_BASE}"; exit 1; fi
echo "Input checks passed."

# --- Run afni_proc.py ---
# Create the output directory if it doesn't exist
mkdir -p "${PROC_DIR}"

# Execute afni_proc.py command
# Note: Paths updated to use BIDS conventions where applicable.
afni_proc.py \
    -subj_id                  "${SUBJ_LABEL}" `# Use label for output naming consistency` \
    -out_dir                  "${PROC_DIR}" \
    -script                   "${PROC_DIR}/proc.${SUBJ_LABEL}.sh" \
    -scr_overwrite \
    -blocks                   tshift align tlrc volreg mask blur scale regress \
    -copy_anat                "${ANAT_SS}" `# Skull-stripped anat from @SSwarper` \
    -anat_has_skull           no \
    -anat_follower            anat_w_skull anat "${ANAT_ORIGINAL_NIFTI}" `# Original T1w (BIDS)` \
    -dsets                    ${EPI_DSETS} `# EPI datasets (BIDS)` \
    -tcat_remove_first_trs    2 \
    -align_unifize_epi        local \
    -align_opts_aea           -cost lpc+ZZ -giant_move -check_flip \
    -tlrc_base                "${TLRC_BASE}" \
    -tlrc_NL_warp                          `# Apply non-linear warp from @SSwarper` \
    -tlrc_NL_warped_dsets     "${ANAT_QQ}" "${ANAT_AFFINE}" "${ANAT_WARP}" `# @SSwarper outputs` \
    -volreg_align_to          MIN_OUTLIER \
    -volreg_align_e2a                      `# Align EPI base to anat` \
    -volreg_tlrc_warp                      `# Warp EPI volreg base to TLRC` \
    -volreg_compute_tsnr      yes \
    -mask_epi_anat            yes          `# Create mask from EPI and anat intersection` \
    -blur_size                4.0 \
    -regress_stim_times       "${STIM_VIS}" "${STIM_AUD}" `# Stimulus timing files` \
    -regress_stim_labels      vis aud \
    -regress_basis            'BLOCK(20,1)' \
    -regress_opts_3dD         -jobs "${NCORES}" \
                              -gltsym 'SYM: vis -aud' -glt_label 1 V-A \
    -regress_motion_per_run \
    -regress_censor_motion    0.3 \
    -regress_censor_outliers  0.05 \
    -regress_3dD_stop                      `# Stop after generating 3dDeconvolve script` \
    -regress_reml_exec                     `# Run 3dREMLfit (handles temporal autocorrelation)` \
    -regress_compute_fitts \
    -regress_make_ideal_sum   sum_ideal.1D \
    -regress_est_blur_epits \
    -regress_est_blur_errts \
    -regress_run_clustsim     no           `# Disable ClustSim` \
    -html_review_style        pythonic     `# Generate modern HTML QC report` \
    -execute

echo -e "\n[INFO] afni_proc.py execution initiated for subject ${BIDS_SUBJ}."
echo "[INFO] Check the output directory: ${PROC_DIR}"
echo "[INFO] Monitor the proc script: ${PROC_DIR}/proc.${SUBJ_LABEL}.sh"
echo "[INFO] And the output log: ${PROC_DIR}/output.proc.${SUBJ_LABEL}"

