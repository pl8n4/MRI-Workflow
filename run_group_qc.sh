#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  run_group_qc.sh
#  --------------------------------------------------------------------------
#  • Auto‑discovers all AFNI out.ss_review.* files in derivatives/afni_proc/
#  • Builds a raw group QC table with AFNI's own gen_ss_review_table.py
#  • Extracts key metrics + variance‑line info, writes cleaned group_qc.tsv
#  • Applies user‑tunable pass/fail rules and lists failing subjects
# ---------------------------------------------------------------------------
set -euo pipefail

# ---------- paths ----------
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DERIV_AFNI="${ROOT_DIR}/derivatives/afni_proc"
QC_UTILS="${ROOT_DIR}/derivatives/qc_utils"
mkdir -p "${QC_UTILS}"

GROUP_TSV="${QC_UTILS}/group_qc.tsv"
FAILED_TXT="${QC_UTILS}/failed_subjects.txt"
RAW_TABLE="$(mktemp)"

# ---------- thresholds (env‑var overrides) ----------
CENSOR_THRESH="${CENSOR_THRESH:-0.10}"   # >10 % censored TRs
VE_COUNT_THRESH="${VE_COUNT_THRESH:-5}"  # ≥5 variance lines
VE_SEV_FAIL="${VE_SEV_FAIL:-high}"       # severity flag that forces fail

echo "=== [discover] searching for out.ss_review files ..."
mapfile -t SS_FILES < <(find "${DERIV_AFNI}" \
                         -mindepth 2 -maxdepth 2 \
                         -type f -name 'out.ss_review.*.txt' \
                         | sort)
                        
if [[ ${#SS_FILES[@]} -eq 0 ]]; then
    echo "No out.ss_review.* files found — nothing to summarise."
    exit 0
fi

# ---------- build raw table with AFNI's helper ----------
echo "=== [afni] running gen_ss_review_table.py ..."
gen_ss_review_table.py -overwrite -tablefile /tmp/qctmp -infiles "${SS_FILES[@]}"


# ---------- locate column indices we care about ----------
IFS=$'\t' read -r -a HDR <<< "$(head -n1 "${RAW_TABLE}")"
declare -A COL

for i in "${!HDR[@]}"; do
  h_lc=$(printf '%s' "${HDR[$i]}" | tr '[:upper:]' '[:lower:]')

  # catch either "fraction censored per run" OR "censor fraction"
  if [[ -z ${COL[CF]:-} && ( $h_lc == *"fraction censored per run"* || $h_lc == *"censor fraction"* ) ]]; then
    COL[CF]=$i
  fi

  # catch either "max motion displacement" OR "max censored displacement"
  if [[ -z ${COL[MM]:-} && ( $h_lc == *"max motion displacement"* || $h_lc == *"max censored displacement"* ) ]]; then
    COL[MM]=$i
  fi

  # any TSNR column name
  if [[ -z ${COL[TS]:-} && $h_lc == *"tsnr"* ]]; then
    COL[TS]=$i
  fi
done

if [[ -z ${COL[CF]:-} || -z ${COL[MM]:-} ]]; then
  echo "ERROR: couldn’t find censor or motion columns in AFNI table:"
  printf '  %s\n' "${HDR[@]}"
  exit 1
fi
# ---------- helper: find JSON & pull variance‑line metrics ----------
jq_first () {               # $1=json  $2.. jq paths
    local f=$1; shift
    local q v
    for q in "$@"; do
        v=$(jq -re "$q // empty" "$f" 2>/dev/null || true)
        [[ -n $v ]] && { echo "$v"; return; }
    done
    echo ""
}
find_qc_json () {           # $1=subj_dir
    find "$1" -maxdepth 2 -type f -name 'apqc_*.json' | head -n1 || true
}

# ---------- write cleaned table & decide pass/fail ----------
echo -e "subject\tcensor_frac\tmotion_max\tTSNR\tve_count\tve_severity" > "${GROUP_TSV}"
FAILED_SUBS=()

tail -n +2 "${RAW_TABLE}" | while IFS=$'\t' read -r -a ROW; do
    SID="${ROW[0]}"                # sub‑XX

    CF="${ROW[${COL[CF]}]}"
    MM="${ROW[${COL[MM]}]}"
    TS="NA"
    [[ -n ${COL[TS]:-} ]] && TS="${ROW[${COL[TS]}]}"

    # variance‑line info (optional)
    subj_dir="${DERIV_AFNI}/${SID}"
    qc_json=$(find_qc_json "$subj_dir")
    if [[ -n $qc_json ]]; then
        VC=$(jq_first "$qc_json" '.ve_total' '.qc_metrics.ve_total' '.qc_ve_total')
        VS=$(jq_first "$qc_json" '.ve_severity' '.qc_metrics.ve_severity' '.ve_overall')
    fi
    VC=${VC:-0}
    VS=${VS:-unknown}

    echo -e "${SID}\t${CF}\t${MM}\t${TS}\t${VC}\t${VS}" >> "${GROUP_TSV}"

    fail=0
    (( $(echo "$CF > $CENSOR_THRESH" | bc -l) )) && fail=1
    (( VC >= VE_COUNT_THRESH )) && fail=1
    [[ "${VS,,}" == "${VE_SEV_FAIL,,}" ]] && fail=1
    (( fail )) && FAILED_SUBS+=("$SID")
done

# ---------- report ----------
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
rm -f "${RAW_TABLE}"
exit 0
