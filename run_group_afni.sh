# run_group_afni.sh  —  Group‑level AFNI statistics with 3dttest++
#
# * One‑sample test of the stim vs no stim contrast across all subjects
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
cd "${DERIV_ROOT}/afni_proc"          

CONTRAST="${1:-F-NF}"                 # must match the -glt_label in afni_proc
MASK="${2:-}"                         # leave empty to let 3dttest++ auto‑mask
PREFIX="../group_afni/${CONTRAST}_ttest"

mkdir -p "$( dirname "$PREFIX" )"

echo "-----------------------------------------------------------"
echo " Group-level AFNI test        : $CONTRAST"
echo " Subjects found (setA)        : $TOTAL_SUBJECTS"
[[ -n "$MASK" ]] && echo " Using explicit brain mask : $MASK"
echo " Output prefix               : $PREFIX"
echo "-----------------------------------------------------------"

# Build the list of sub‑brick paths
SET_A=()
for SID in $SUBJECT_LIST ; do
    if [[ -f sub-${SID}/stats.REML+tlrc.HEAD ]]; then
        STAT_BASENAME="sub-${SID}/stats.REML+tlrc"
    else
        STAT_BASENAME=$(ls sub-${SID}/stats.${SID}_REML+tlrc.HEAD 2>/dev/null | head -n1 | sed 's/\.HEAD$//')
    fi
    [[ -n "$STAT_BASENAME" ]] \
        || { echo "❌ No stats.*_REML+tlrc file for sub-${SID}" ; exit 1; }

    coef="${STAT_BASENAME}[${CONTRAST}#0_Coef]"
    SET_A+=("${coef}")
done

# Launch 3dttest++
3dttest++                             \
    -prefix   "$PREFIX"               \
    -setA     "${SET_A[@]}"           \
    ${MASK:+-mask "$MASK"}            \
    -Clustsim "${OMP_NUM_THREADS}"    \
    -DAFNI_OMP_NUM_THREADS="${OMP_NUM_THREADS}"

echo -e "\n✅  Group-level file written  →  ${PREFIX}+tlrc.*"
