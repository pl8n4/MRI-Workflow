#!/usr/bin/env python3
#
# optimize_workflow.py
#
# Figures out how to split up jobs and resources for parallel processing.
# Calculates the best way to split jobs into batches based on subject count and RAM
# Used by run_phase.sh to set threads per job and number of parallel jobs

"""
optimize_resources.py

Compute:
  - Optimal threads-per-job (capped at 16, min 1).
  - Max concurrent jobs under a 90% RAM usage cap.
  - Number of full batches needed to run TOTAL_JOBS.

Usage:
    ./optimize_resources.py TOTAL_JOBS MEM_PER_JOB_GB
"""

import argparse
import multiprocessing
import os
import sys
import math

def get_total_ram_gb():
    try:
        page_size = os.sysconf('SC_PAGE_SIZE')
        phys_pages = os.sysconf('SC_PHYS_PAGES')
        total_bytes = page_size * phys_pages
        return total_bytes / (1024**3)
    except (AttributeError, ValueError):
        with open('/proc/meminfo') as f:
            for line in f:
                if line.startswith('MemTotal:'):
                    kb = int(line.split()[1])
                    return kb / 1024**2
        sys.exit("Unable to determine total system RAM.")

def parse_args():
    p = argparse.ArgumentParser(
        description="Compute optimal CPU and RAM allocation for batch jobs."
    )
    p.add_argument(
        "total_jobs",
        type=int,
        help="Total number of jobs to run"
    )
    p.add_argument(
        "mem_per_job_gb",
        type=float,
        help="Peak RAM required per job, in GB"
    )
    return p.parse_args()

def main():
    args = parse_args()
    J = args.total_jobs
    M = args.mem_per_job_gb

    if J < 1:
        print("Error: TOTAL_JOBS must be >= 1", file=sys.stderr)
        sys.exit(1)
    if M <= 0:
        print("Error: MEM_PER_JOB_GB must be > 0", file=sys.stderr)
        sys.exit(1)

    # Detect total logical CPU cores
    total_cores = multiprocessing.cpu_count()

    # Detect total system RAM in GB
    total_ram_gb = get_total_ram_gb()

    # Compute max jobs by RAM at 90% usage
    usable_ram_gb = total_ram_gb * 0.9
    max_mem_jobs = max(1, int(usable_ram_gb // M))

    # Actual parallel jobs is min(TOTAL_JOBS, RAM-limited)
    parallel_jobs = min(J, max_mem_jobs)

    # Compute threads-per-job: integer divide, cap [1..16]
    tpj = total_cores // parallel_jobs
    tpj = min(max(tpj, 1), 16)

    # Compute how many full batches are needed
    batches = math.ceil(J / parallel_jobs)

    print(f"Threads per job:  {tpj}")
    print(f"Parallel jobs:    {parallel_jobs}")
    print(f"Batches needed:   {batches}")

if __name__ == "__main__":
    main()
