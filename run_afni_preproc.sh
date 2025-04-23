#!/usr/bin/env bash
# ============================================================================
# AFNI fMRI preprocessing (Example 6b‑style, with auto timing generation)
# Usage: ./run_afni_preproc_6b.sh <SUBJECT_ID> [N_JOBS]
# ---------------------------------------------------------------------------
#  * Drop this script in the root of your BIDS dataset (ds000xxx) on CloudLab.
#  * Requires @SSwarper outputs in derivatives/sswarper/sub-<ID>/anat_warped/
#  * If AFNI‑style timing files are missing, it will convert BIDS events.tsv
#    to stim_times files automatically using AFNI's timing_tool.py.
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
DATASET_ROOT="$(cd "$(dirname "$0")" && pwd)"
BIDS_ROOT="$DATASET_ROOT"
DERIV_ROOT="$DATASET_ROOT/derivatives"
STIM_DIR="$DERIV_ROOT/stimuli"
mkdir -p "$STIM_DIR"

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

# @SSwarper outputs
ANAT_SS="$QWARP_DIR/anatSS.${SUBJ}.nii"
ANAT_QWARP="$QWARP_DIR/anatQQ.${SUBJ}.nii"
AFF12="$QWARP_DIR/anatQQ.${SUBJ}.aff12.1D"
WARP="$QWARP_DIR/anatQQ.${SUBJ}_WARP.nii"

# ------------------------ HELPER: make timing files -------------------------
make_timing_from_tsv() {
  local tsv_files=( "$BIDS_ROOT/sub-${SUBJ}/func/"*events.tsv )
  if [[ ! -e "${tsv_files[0]}" ]]; then
    echo "ERROR: No events.tsv files found to auto‑generate timing." >&2
    return 1
  fi

  echo "↻ Converting events.tsv → AFNI stim_times …"

  # Detect column indices for onset, duration, trial_type from header
  local header collist onset_i dur_i tt_i
  header=$(head -n1 "${tsv_files[0]}")
  IFS=$'\t' read -r -a collist <<< "$header"
  for i in "${!collist[@]}"; do
    case "${collist[$i]}" in
      onset)      onset_i=$((i+1)); ;;
      duration)   dur_i=$((i+1)); ;;
      trial_type) tt_i=$((i+1)); ;;
    esac
  done
  if [[ -z "${onset_i:-}" || -z "${dur_i:-}" || -z "${tt_i:-}" ]]; then
    echo "ERROR: Couldn't infer onset/duration/trial_type columns." >&2
    return 1
  fi

  # Gather unique condition names across all runs
  local conds
  conds=$(awk -v col=$tt_i -F'\t' 'NR>1 {print $col}' "${tsv_files[@]}" | sort -u)
  [[ -z "$conds" ]] && { echo "ERROR: No trial_type values found." >&2; return 1; }

  # Run timing_tool.py
  timing_tool.py \
      -tsv_events   "${tsv_files[@]}" \
      -multi_timing "${STIM_DIR}/sub-${SUBJ}" \
      -tsv_cols     onset duration trial_type \
      -tsv_condval  ${conds} \
      -write_timing_tr  \
      -overwrite

  # timing_tool writes *_<cond>.1D ; collect list
}

# -------------------- Find or auto‑generate stim files ----------------------
STIM_FILES=( $(ls "$STIM_DIR/sub-${SUBJ}_"*.{1D,txt} 2>/dev/null || true) )
if [ ${#STIM_FILES[@]} -eq 0 ]; then
  make_timing_from_tsv || {
    echo "✗ Could not build timing files; aborting." >&2
    exit 1
  }
  STIM_FILES=( $(ls "$STIM_DIR/sub-${SUBJ}_"*.{1D,txt} 2>/dev/null) )
fi

# Build label list from filenames
LABELS=()
for f in "${STIM_FILES[@]}"; do
  base=$(basename "$f")          # sub-05_<label>.1D
  label=${base#sub-${SUBJ}_}
  label=${label%.*}
  LABELS+=("$label")
done

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
    -regress_stim_labels      ${LABELS[*]} \
    -regress_basis            'BLOCK(20,1)' \
    -regress_opts_3dD         -jobs ${N_JOBS} -gltsym 'SYM: ${LABELS[0]} -${LABELS[1]:-baseline}' -glt_label 1 ${LABELS[0]}-vs-${LABELS[1]:-B} \
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
