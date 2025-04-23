#!/usr/bin/env bash
# run_sswarper.sh  --  Warp a single subject’s T1w to MNI with @SSwarper
# USAGE: ./run_sswarper.sh <SUBJECT_ID> [N_CORES]
set -euo pipefail
[[ $# -lt 1 ]] && { echo "Usage: $0 <SUBJECT_ID> [N_CORES]"; exit 1; }

SID="$1"                  # 01, FT, etc., WITHOUT "sub-" prefix
NCORES="${2:-8}"          # default 8 threads
BIDS_SUBJ="sub-${SID}"
T1="${BIDS_SUBJ}/anat/${BIDS_SUBJ}_T1w.nii.gz"

@SSwarper                                   \
    -input      "$T1"                       \
    -base       MNI152_2009_template_SSW.nii.gz \
    -subid      "$SID"                      \
    -workdir    derivatives/sswarper        \
    -n_threads  "$NCORES"

echo -e "\n[INFO] Finished @SSwarper for subject $SID"
