#!/usr/bin/env bash
# run_sswarper.sh  --  Warp a single subject’s T1w to MNI with @SSwarper
# USAGE: ./run_sswarper.sh <SUBJECT_ID> [N_CORES]
set -euo pipefail
[[ $# -lt 1 ]] && { echo "Usage: $0 <SUBJECT_ID> [N_CORES]"; exit 1; }

MYDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "${MYDIR}/workflow.conf"
cd "${BIDS_ROOT}"

SID="$1"
LABEL="sub-${SID}"
NCORES="${2:-8}"
export OMP_NUM_THREADS="$NCORES"
T1="${LABEL}/anat/${LABEL}_T1w.nii.gz"

SSW_TEMPLATE="MNI152_2009_template_SSW.nii.gz"

@SSwarper                                   \
    -input      "$T1"                       \
    -base       "${SSW_TEMPLATE}"           \
    -subid      "$SID"                      \
    -odir    "derivatives/sswarper/${SID}"

echo -e "\n[INFO] Finished @SSwarper for subject $SID"