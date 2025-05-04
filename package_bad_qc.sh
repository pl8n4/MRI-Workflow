#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  package_bad_qc.sh   — tar up QC folders for subjects listed in failed_subjects.txt
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DERIV_AFNI="${ROOT_DIR}/derivatives/afni_proc"
QC_UTILS="${ROOT_DIR}/derivatives/qc_utils"
FAILED_TXT="${QC_UTILS}/failed_subjects.txt"

[[ ! -s "${FAILED_TXT}" ]] && { echo "No failed_subjects.txt or it is empty — nothing to package."; exit 0; }

timestamp=$(date +'%Y%m%d_%H%M')
TARBALL="${QC_UTILS}/QC_flagged_${timestamp}.tgz"

echo "=== [package] creating ${TARBALL} ..."
mapfile -t BAD_SUBS < "${FAILED_TXT}"
REL_PATHS=()

for SID in "${BAD_SUBS[@]}"; do
    subj_dir="${DERIV_AFNI}/${SID}"
    qc_dir=$(find "$subj_dir" -maxdepth 2 -type d -name 'QC_*' | head -n1 || true)
    if [[ -n $qc_dir ]]; then
        REL_PATHS+=("${qc_dir#${DERIV_AFNI}/}")
    else
        echo "[warn] missing QC dir for ${SID}"
    fi
done

[[ ${#REL_PATHS[@]} -eq 0 ]] && { echo "No QC dirs found to package."; exit 0; }

tar -czf "${TARBALL}" -C "${DERIV_AFNI}" "${REL_PATHS[@]}"
echo "Tarball created: ${TARBALL}"
exit 0
