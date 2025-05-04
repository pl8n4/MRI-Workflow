#!/usr/bin/env bash
# Bundle QC folders of failed subjects (if any) into one tarball.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DERIV_AFNI="${ROOT_DIR}/derivatives/afni_proc"
QC_UTILS="${ROOT_DIR}/derivatives/qc_utils"
FAILED_TXT="${QC_UTILS}/failed_subjects.txt"

[[ ! -s "${FAILED_TXT}" ]] && { echo "No failed_subjects.txt or it is empty – nothing to package."; exit 0; }

timestamp=$(date +'%Y%m%d_%H%M')
TARBALL="${QC_UTILS}/QC_flagged_${timestamp}.tgz"

echo "=== [package] creating ${TARBALL} ..."
mapfile -t BAD_SUBS < "${FAILED_TXT}"
REL_PATHS=()
for SID in "${BAD_SUBS[@]}"; do
    path="${SID}/QC_${SID}"
    [[ -d "${DERIV_AFNI}/${path}" ]] && REL_PATHS+=("${path}") \
        || echo "[warn] missing QC dir for ${SID}"
done

[[ ${#REL_PATHS[@]} -eq 0 ]] && { echo "No QC dirs found to package."; exit 0; }

tar -czf "${TARBALL}" -C "${DERIV_AFNI}" "${REL_PATHS[@]}"
echo "Tarball created: ${TARBALL}"
exit 0
