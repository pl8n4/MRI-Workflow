#!/usr/bin/env bash
# Aggregate AFNI QC across subjects and flag failures.
# Place this script in the dataset root (same dir as afni_proc.sh).
set -euo pipefail

# ---------- paths ----------
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DERIV_AFNI="${ROOT_DIR}/derivatives/afni_proc"
QC_UTILS="${ROOT_DIR}/derivatives/qc_utils"

mkdir -p "${QC_UTILS}"

GROUP_TSV="${QC_UTILS}/group_qc.tsv"
FAILED_TXT="${QC_UTILS}/failed_subjects.txt"

# ---------- thresholds (override via env) ----------
CENSOR_THRESH="${CENSOR_THRESH:-0.10}"   # >10 % censored TRs
VE_COUNT_THRESH="${VE_COUNT_THRESH:-5}"  # ≥5 variance‑lines
VE_SEV_FAIL="${VE_SEV_FAIL:-high}"       # severity level that forces fail

echo "=== [discover] searching for completed subjects ..."
mapfile -t SUB_DIRS < <(find "${DERIV_AFNI}" -maxdepth 1 -type d -name 'sub-*' | sort)
[[ ${#SUB_DIRS[@]} -eq 0 ]] && { echo "No subject dirs found."; exit 0; }

# ---------- util ----------
jq_first () {    # $1 = json file, $2.. = jq paths to test in order
    local f=$1; shift
    local p val
    for p in "$@"; do
        val=$(jq -re "$p // empty" "$f" 2>/dev/null || true)
        [[ -n $val ]] && { echo "$val"; return; }
    done
    echo "NA"
}

# ---------- header ----------
echo -e "subject\tcensor_frac\tmotion_max\tTSNR\tve_count\tve_severity" > "${GROUP_TSV}"
FAILED_SUBS=()

# ---------- per‑subject loop ----------
for S in "${SUB_DIRS[@]}"; do
    SID=$(basename "$S")                                  # e.g., sub-01
    QC_JSON="$S/QC_${SID}/apqc_${SID}.json"
    [[ ! -f "$QC_JSON" ]] && { echo "[skip] $SID (no JSON)"; continue; }

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

# ---------- results ----------
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
