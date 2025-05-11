#!/usr/bin/env bash
# run_group_afni.sh  —  Group‑level AFNI statistics with 3dttest++
#
# * One‑sample test of the FOOD‑vs‑NONFOOD contrast across all subjects
# * Extensible to two‑sample or covariate models by editing the SETS section
#
# USAGE: ./run_group_afni.sh [contrast_label] [mask]
#        contrast_label defaults to F-NF  (matches label in afni_proc.sh)
#        mask (optional) path to a group mask NIfTI or AFNI dataset
# -------------------------------------------------------------------------

set -euo pipefail

# TMPDIR with lots of space for tmp files
export TMPDIR=/mydata/group_afni_tmp

MYDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "${MYDIR}/workflow.conf"
cd "${DERIV_ROOT}/afni_proc"          # each subject has its own directory

CONTRAST="${1:-F-NF}"                 # must match the -glt_label in afni_proc
MASK="${2:-}"                         # leave empty to let 3dttest++ auto‑mask
PREFIX="${DERIV_ROOT}/group_afni/${CONTRAST}_ttest"

mkdir -p "$( dirname "$PREFIX" )"

echo "-----------------------------------------------------------"
echo " Group-level AFNI test        : $CONTRAST"
echo " Subjects found (setA)        : $TOTAL_SUBJECTS"
[[ -n "$MASK" ]] && echo " Using explicit brain mask : $MASK"
echo " Output prefix               : $PREFIX"
echo "-----------------------------------------------------------"

# ----- Build the list of sub‑brick paths -------------------------------
SET_A=()
for SID in $SUBJECT_LIST ; do
    STAT_DSET="${SID}/stats.REML+tlrc"
    coef="${STAT_DSET}[${CONTRAST}#0_Coef]"
    [[ -f ${STAT_DSET}.HEAD ]] || { echo "❌ Missing ${STAT_DSET}" ; exit 1; }
    # verify that the sub‑brick exists (quietly)
    3dinfo -label2index "${CONTRAST}#0_Coef" "${STAT_DSET}" >/dev/null 2>&1 \
        || { echo "❌ ${CONTRAST} not found in ${STAT_DSET}" ; exit 1; }
    SET_A+=( "$coef" )
done

# ----- Launch 3dttest++ -------------------------------------------------
3dttest++                                    \
    -prefix      "$PREFIX"                   \
    -setA        "$CONTRAST" "${SET_A[@]}"   \
    ${MASK:+-mask "$MASK"}                   \
    -Clustsim                                \ # optional: add cluster-sim thresh
    -DAFNI_OMP_NUM_THREADS=$OMP_NUM_THREADS

echo -e "\n✅  Group-level file written  →  ${PREFIX}+tlrc.*"
echo    "    Inspect with afni or SUMA, or feed into 3dClusterize for thresholding."
