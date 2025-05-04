#!/usr/bin/env bash
# Aggregate AFNI QC across subjects and flag failures.
# Put this file in the dataset root (same dir as afni_proc.sh).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DERIV_AFNI="${ROOT_DIR}/derivatives/afni_proc"
QC_UTILS="${ROOT_DIR}/derivatives/qc_utils"

mkdir -p "${QC_UTILS}"

GROUP_TSV="${QC_UTILS}/group_qc.tsv"
FAILED_TXT="${QC_UTILS}/failed_subjects.txt"

# -------- thresholds --------
CENSOR_THRESH="${CENSOR_THRESH:-0.10}"   # >10 % censored TRs
VE_COUNT_THRESH="${VE_COUNT_THRESH:-5}"  # ≥5 variance‑lines
VE_SEV_FAIL="${VE_SEV_FAIL:-high}"       # severity level that forces fail

echo "=== [discover] searching for completed subjects ..."
mapfile -t SUB_DIRS < <(find "${DERIV_AFNI}" -maxdepth 1 -type d -name 'sub-*' | sort)
[[ ${#SUB_DIRS[@]} -eq 0 ]] && { echo "No subject dirs found."; exit 0; }

# -------- helpers --------
jq_first () {        # $1=json file, $2.. jq keys
    local f=$1; shift
    local q val
    for q in "$@"; do
        val=$(jq -re "$q // empty" "$f" 2>/dev/null || true)
        [[ -n $val ]] && { echo "$val"; return; }
    done
    echo "NA"
}

find_qc_json () {    # $1 = subject dir → echo full path to apqc_*.json or blank
    local subj_dir=$1
    local qc_dir
    qc_dir=$(find "$subj_dir" -maxdepth 1 -type d -name 'QC_*' | head -n1 || true)
    [[ -z $qc_dir ]] && return
    find "$qc_dir" -maxdepth 1 -type f -name 'apqc_*.json' | head -n1
}

# -------- header --------
echo -e "subject\tcensor_frac\tmotion_max\tTSNR\tve_count\tve_severity" > "${GROUP_TSV}"
FAILED_SUBS=()

# -------- per‑subject loop --------
for S in "${SUB_DIRS[@]}"; do
    SID=$(basename "$S")                       # sub‑08
    QC_JSON=$(find_qc_json "$S")
    [[ -z $QC_JSON ]] && { echo "[skip] $SID (no QC JSON)"; continue; }

    CF=$(jq_first "$QC_JSON" '.qc_metrics.censor_fraction' '.qc_metrics.censor_frac' '.censor_fraction')
    MM=$(jq_first "$QC_JSON" '.qc_metrics.motion_enorm_max' '.qc_metrics.enorm_max' '.motion_enorm_max')
    TS=$(jq_first "$QC_JSON" '.qc_metrics.tsnr_median' '.qc_metrics.tsnr' '.tsnr')
    VC=$(jq_first "$QC_JSON" '.qc_metrics.ve_total' '.qc_ve_total' '.ve_tot')
    VS=$(jq_first "$QC_JSON" '.qc_metrics.ve_severity' '.ve_overall' '.ve_severity')

    [[ $CF == NA ]] && CF=0
    [[ $MM == NA ]] && MM=0
    [[ $TS == NA ]] && TS=0
    [[ $VC == NA ]] && VC=0
    [[ $VS == NA ]] && VS="unknown"

    echo -e "${SID}\t${CF}\t${MM}\t${TS}\t${VC}\t${VS}" >> "${GROUP_TSV}"

    fail=0
    (( $(echo "$CF > $CENSOR_THRESH" | bc -l) )) && fail=1
    (( VC >= VE_COUNT_THRESH )) && fail=1
    [[ "${VS,,}" == "${VE_SEV_FAIL,,}" ]] && fail=1
    (( fail )) && FAILED_SUBS+=("$SID")
done

# -------- results --------
if [[ ${#FAILED_SUBS[@]} -eq 0 ]]; then
    rm -f "${FAILED_TXT}"
    echo "=== [result] ✅ All subjects passed QC thresholds."
else
    printf "%s\n" "${FAILED_SUBS[@]}" > "${FAILED_TXT}"
    echo "=== [result] ⚠️  ${#FAILED_SUBS[@]} subject(s) flagged:"
    printf '    %s\n' "${FAILED_SUBS[@]}"
    echo "Failed list saved to ${FAILED_TXT}"
fi

echo "=== [aggregate] QC table saved to ${GROUP_TSV}"
exit 0
