#!/usr/bin/env bash
set -euo pipefail

# Always determine absolute script directory
MYDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "${MYDIR}/workflow.conf"

# Always explicitly cd to BIDS_ROOT before launching phases
cd "${BIDS_ROOT}"

# Safely launch phases explicitly
# MRQIC should be run manually as ./run_phase.sh MRIQC to allow for manual checking of QC

#"${MYDIR}/run_phase.sh" MRIQC
"${MYDIR}/run_phase.sh" SSW
"${MYDIR}/run_phase.sh" AFNI

# Run group QC explicitly
"${MYDIR}/run_group_qc.sh"