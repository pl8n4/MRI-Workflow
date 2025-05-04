#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  run_group_qc.sh
#  --------------------------------------------------------------------------
#  • Auto‑discovers AFNI out.ss_review.*.txt files
#  • Builds a raw group QC table with gen_ss_review_table.py
#  • Cleans the table, extracts key metrics + variance‑line info
#  • Applies pass/fail rules and writes failed_subjects.txt
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DERIV_AFNI="${ROOT_DIR}/derivatives/afni_proc"
QC_UTILS="${ROOT_DIR}/derivatives/qc_utils"
mkdir -p "${QC_UTILS}"

GROUP_TSV="${QC_UTILS}/group_qc.tsv"
FAILED_TXT="${QC_UTILS}/failed_subjects.txt"
RAW_TABLE="$(mktemp)"

# user‑tunable thresholds (env‑var overrides)
CENSOR_THRESH="${CENSOR_THRESH:-0.10}"   # >10 % censored TRs
VE_COUNT_THRESH="${VE_COUNT_THRESH:-5}"  # ≥5 variance‑line count
VE_SEV_FAIL="${VE_SEV_FAIL:-high}"       # severity that forces review

echo "=== [discover] searching for out.ss_review files ..."
mapfile -t SS_FILES < <(
  find "${DERIV_AFNI}" \
       -mindepth 2 -maxdepth 2 \
       -type f -name 'out.ss_review.*.txt' \
       | sort
)
if [[ ${#SS_FILES[@]} -eq 0 ]]; then
  echo "No out.ss_review.*.txt files found — nothing to summarise."
  exit 0
fi

echo "=== [afni] running gen_ss_review_table.py ..."
gen_ss_review_table.py \
  -overwrite \
  -tablefile "${RAW_TABLE}" \
  -infiles "${SS_FILES[@]}"

# — locate column indices robustly —
mapfile -t HDR < <(head -n1 "${RAW_TABLE}" | tr '\t' '\n')
declare -A COL
for i in "${!HDR[@]}"; do
  h="${HDR[i],,}"
  if [[ -z ${COL[CF]:-} && ( "$h" == *fraction*per*run* || "$h" == *censor*fraction* ) ]]; then
    COL[CF]=$i
  fi
  if [[ -z ${COL[MM]:-} && ( "$h" == *max*motion*displacement* || "$h" == *max*censored*displacement* ) ]]; then
    COL[MM]=$i
  fi
  if [[ -z ${COL[TS]:-} && "$h" == *tsnr* ]]; then
    COL[TS]=$i
  fi
done

if [[ -z ${COL[CF]:-} || -z ${COL[MM]:-} ]]; then
  echo "ERROR: couldn’t find censor or motion columns. Found headers:"
  printf '  %s
' "${HDR[@]}"
  exit 1
fi

echo -e "subject	censor_frac	motion_max	TSNR	ve_count	ve_severity" > "${GROUP_TSV}"
FAILED_SUBS=()

# skip header + units (first two lines), then process each subject row
readarray -t LINES < <(tail -n +3 "${RAW_TABLE}")
for line in "${LINES[@]}"; do
  IFS=$'\t' read -r -a ROW <<< "$line"
  INFILE="${ROW[0]}"
  SID="$(basename "$(dirname "$INFILE")")"

  CF="${ROW[${COL[CF]}]}"
  MM="${ROW[${COL[MM]}]}"
  TS="NA"
  [[ -n ${COL[TS]:-} ]] && TS="${ROW[${COL[TS]}]}"

  # optional variance‑line info from JSON
  qc_json=$(find "${DERIV_AFNI}/${SID}" -maxdepth 2 -type f -name 'apqc_*.json' | head -n1 || true)
  if [[ -n $qc_json ]]; then
    VC=$(jq -re '.qc_metrics.ve_total // .ve_total // .qc_ve_total // .ve_tot' \
             "$qc_json" 2>/dev/null || echo 0)
    VS=$(jq -re '.qc_metrics.ve_severity // .ve_severity // .qc_overall' \
             "$qc_json" 2>/dev/null || echo unknown)
  else
    VC=0
    VS=unknown
  fi

  echo -e "${SID}	${CF}	${MM}	${TS}	${VC}	${VS}" >> "${GROUP_TSV}"

  fail=0
  (( $(echo "$CF > $CENSOR_THRESH" | bc -l) )) && fail=1
  (( VC >= VE_COUNT_THRESH )) && fail=1
  [[ "${VS,,}" == "${VE_SEV_FAIL,,}" ]] && fail=1
  (( fail )) && FAILED_SUBS+=("$SID")
done

if [[ ${#FAILED_SUBS[@]} -eq 0 ]]; then
  rm -f "${FAILED_TXT}"
  echo "=== [result] ✅ All subjects passed QC thresholds."
else
  printf "%s
" "${FAILED_SUBS[@]}" > "${FAILED_TXT}"
  echo "=== [result] ⚠️  ${#FAILED_SUBS[@]} subject(s) flagged:"
  printf '    %s
' "${FAILED_SUBS[@]}"
  echo "Failed list saved to ${FAILED_TXT}"
fi

echo "=== [aggregate] QC table saved to ${GROUP_TSV}"
rm -f "${RAW_TABLE}"
exit 0
