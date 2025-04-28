#!/usr/bin/env bash
# run_afni_proc.sh -- Preprocess fMRI data for a single subject using afni_proc.py
#
# This script adapts a standard afni_proc.py template to work with
# outputs from @SSwarper (run via run_sswarper.sh) and allows specifying
# the subject ID and number of cores.
#
# It assumes the script is run from the root directory of the dataset
# and that the data follows a structure where subject-specific files
# are found in directories named after the subject ID (e.g., 'FT/', '01/')
# and derivative files are in 'derivatives/'.
#
# USAGE: ./run_afni_proc.sh <SUBJECT_ID> [N_CORES]
#        Example: ./run_afni_proc.sh FT 8

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
  echo "Usage: $0 <SUBJECT_ID> [N_CORES]"
  echo "Error: Subject ID is required."
  exit 1
fi

# Assign arguments to variables
# Subject ID (e.g., FT, 01). Assumes no 'sub-' prefix needed for raw data dirs based on template.
# If your raw data is in sub-${SID}, adjust paths below accordingly.
SID="$1"
# Number of cores for parallel processing (default to 8 if not specified)
NCORES="${2:-8}"
# Export OMP_NUM_THREADS for AFNI multi-threading
export OMP_NUM_THREADS="$NCORES"

echo "--- Running AFNI Preprocessing ---"
echo "Subject ID: ${SID}"
echo "Number of Cores: ${NCORES}"
echo "----------------------------------"

# --- Define File Paths ---
# Assumes script is run from the dataset root directory.

# Input anatomical data (skull-stripped, output from @SSwarper)
# Adjust filename pattern if @SSwarper output differs
ANAT_SS="derivatives/sswarper/${SID}/anatSS.${SID}.nii"

# Input anatomical data (with skull, original T1w)
# Assumes a BIDS-like structure for the original T1w within the subject's raw data directory
# If your original T1w path is different, adjust this line.
ANAT_ORIGINAL="${SID}/${SID}_anat+orig" # Template used FT/FT_anat+orig

# EPI datasets (functional runs)
# Uses wildcard '*' to capture multiple runs (e.g., r1, r2) based on template pattern
# Assumes EPI files are in the subject's raw data directory
# Adjust path and pattern (e.g., to sub-${SID}/func/...) if needed.
EPI_DSETS="${SID}/${SID}_epi_r*+orig.HEAD" # Template used FT/FT_epi_r?+orig.HEAD

# @SSwarper output files for non-linear registration to template space
SSWARPER_DIR="derivatives/sswarper/${SID}"
ANAT_QQ="${SSWARPER_DIR}/anatQQ.${SID}.nii"         # Warped anatomical
ANAT_AFFINE="${SSWARPER_DIR}/anatQQ.${SID}.aff12.1D" # Affine matrix
ANAT_WARP="${SSWARPER_DIR}/anatQQ.${SID}_WARP.nii"   # Nonlinear warp field

# Stimulus timing files
# Assumes they are in the subject's raw data directory. Adjust if needed.
STIM_VIS="${SID}/AV1_vis.txt"
STIM_AUD="${SID}/AV2_aud.txt"

# TLRC template (MNI) - Assumes this file is accessible in the path or specify full path
TLRC_BASE="MNI152_2009_template_SSW.nii.gz"

# Output directory for afni_proc.py results
PROC_DIR="derivatives/afni_proc/${SID}"

# --- Check Input Files ---
# Basic check to ensure necessary input files/dirs exist before running
echo "Checking for necessary inputs..."
if [ ! -f "${ANAT_SS}" ]; then echo "ERROR: Skull-stripped anat not found: ${ANAT_SS}"; exit 1; fi
if [ ! -f "${ANAT_ORIGINAL}.HEAD" ] && [ ! -f "${ANAT_ORIGINAL}.nii.gz" ]; then echo "ERROR: Original anat not found: ${ANAT_ORIGINAL}"; exit 1; fi
if ! ls ${EPI_DSETS} 1> /dev/null 2>&1; then echo "ERROR: EPI datasets not found matching pattern: ${EPI_DSETS}"; exit 1; fi
if [ ! -f "${ANAT_QQ}" ]; then echo "ERROR: Warped anat (QQ) not found: ${ANAT_QQ}"; exit 1; fi
if [ ! -f "${ANAT_AFFINE}" ]; then echo "ERROR: Affine transform not found: ${ANAT_AFFINE}"; exit 1; fi
if [ ! -f "${ANAT_WARP}" ]; then echo "ERROR: Nonlinear warp not found: ${ANAT_WARP}"; exit 1; fi
if [ ! -f "${STIM_VIS}" ]; then echo "ERROR: Visual stim file not found: ${STIM_VIS}"; exit 1; fi
if [ ! -f "${STIM_AUD}" ]; then echo "ERROR: Auditory stim file not found: ${STIM_AUD}"; exit 1; fi
if [ ! -f "${TLRC_BASE}" ]; then echo "ERROR: TLRC base template not found: ${TLRC_BASE}"; exit 1; fi
echo "Input checks passed."

# --- Run afni_proc.py ---
# Create the output directory if it doesn't exist
mkdir -p "${PROC_DIR}"

# Execute afni_proc.py command
# Note: This command is adapted from the user-provided template.
# Options are explained via comments where clarification might be useful.
afni_proc.py \
    -subj_id                  "${SID}" \
    -out_dir                  "${PROC_DIR}" \
    -script                   "${PROC_DIR}/proc.${SID}.sh" \
    -scr_overwrite \
    -blocks                   tshift align tlrc volreg mask blur scale regress \
    -copy_anat                "${ANAT_SS}" \
    -anat_has_skull           no \
    -anat_follower            anat_w_skull anat "${ANAT_ORIGINAL}" \
    -dsets                    ${EPI_DSETS} \
    -tcat_remove_first_trs    2 \
    -align_unifize_epi        local \
    -align_opts_aea           -cost lpc+ZZ -giant_move -check_flip \
    -tlrc_base                "${TLRC_BASE}" \
    -tlrc_NL_warp                          `# Apply non-linear warp from @SSwarper` \
    -tlrc_NL_warped_dsets     "${ANAT_QQ}" "${ANAT_AFFINE}" "${ANAT_WARP}" \
    -volreg_align_to          MIN_OUTLIER \
    -volreg_align_e2a                      `# Align EPI base to anat` \
    -volreg_tlrc_warp                      `# Warp EPI volreg base to TLRC` \
    -volreg_compute_tsnr      yes \
    -mask_epi_anat            yes          `# Create mask from EPI and anat intersection` \
    -blur_size                4.0 \
    -regress_stim_times       "${STIM_VIS}" "${STIM_AUD}" \
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

echo -e "\n[INFO] afni_proc.py execution initiated for subject ${SID}."
echo "[INFO] Check the output directory: ${PROC_DIR}"
echo "[INFO] Monitor the proc script: ${PROC_DIR}/proc.${SID}.sh"
echo "[INFO] And the output log: ${PROC_DIR}/output.proc.${SID}"

