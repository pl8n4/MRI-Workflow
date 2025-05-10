#!/usr/bin/env bash
# run_phase.sh  — launch N subject‑level jobs for one phase in parallel
set -euo pipefail
PHASE="$1"        # MRIQC | SSW | AFNI
shift             # remaining args forwarded to per‑subject script

source workflow.conf
cd "$BIDS_ROOT"

# 1) Subject list = all sub-* folders unless restricted by $SUBS env‑var
SUBJECTS=${SUBJECT_LIST}

# 2) Pick per‑phase resources
case "$PHASE" in
  MRIQC) JOB="$RUN_MRIQC" ; RAM="$MRIQC_RAM" ;;
  SSW)   JOB="$RUN_SSW"   ; RAM="$SSW_RAM"   ;;
  AFNI)  JOB="$RUN_AFNI"  ; RAM="$AFNI_RAM"  ;;
  *)     echo "Unknown phase $PHASE" >&2 ; exit 1 ;;
esac

# 3) Ask optimize_workflow.py for TPJ, PARALLEL & BATCHES
read -r TPJ PARALLEL BATCHES <<<"$(
  "${WORKFLOW_DIR}/optimize_workflow.py" "$TOTAL_SUBJECTS" "$RAM" \
    | awk '/Threads per job|Parallel jobs|Batches needed/ {print $NF}' \
    | tr '\n' ' '
)"
echo "[${PHASE}] threads/job=${TPJ}  parallel_jobs=${PARALLEL}  batches=${BATCHES}"

export OMP_NUM_THREADS="$TPJ"   # per‑job thread fan‑out

# 4) Launch ------------------------------------------------------------------
if [[ "$LAUNCHER" == "local" ]]; then
    parallel -u \
        -j "$PARALLEL" \
        "$JOB" {} "$TPJ" "$RAM" ::: $SUBJECT_LIST \
        > /dev/null 2>&1
    
    if [[ "${PHASE}" == "MRIQC" && "${RUN_MRIQC_GROUP,,}" == "true" ]]; then
        echo "→ All MRIQC participant runs done; launching MRIQC group stage…"
        singularity exec --cleanenv \
            --bind "${BIDS_ROOT}:/data" \
            "${SIF_IMAGE}" \
            mriqc /data /data/derivatives/mriqc group
        echo "✔ group_*.tsv & group_*.html now in derivatives/mriqc/"
    fi

else
  # build and submit slurm array: one task per subject, capped by $PARALLEL
  mapfile -t array <<<"$SUBJECTS"
  SLURM_ARRAY="${array[*]}"
  sbatch --partition="$SLURM_PARTITION" \
         --cpus-per-task="$TPJ" --mem="${RAM}G" \
         --array=0-$((${#array[@]}-1))%$PARALLEL \
         --export=ALL,JOB="$JOB",SUBJECTS="$SLURM_ARRAY" \
         <<'EOF'
#!/usr/bin/env bash
idx=$SLURM_ARRAY_TASK_ID
set -- $SUBJECTS ; SUBJ=${!idx+1}
$JOB "$SUBJ" "$OMP_NUM_THREADS" "$RAM"
EOF
fi