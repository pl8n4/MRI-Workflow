#!/usr/bin/env python3
"""
optimize_workflow.py  ─ Recommend per‑subject parallel plan
for AFNI (+MRIQC) based solely on hardware & RAM constraints.

New in 2025‑05‑04
=================
* Simplified to practical limits: cores per job & RAM per job.
* Removed runtime-based ETA; focus on maximum parallel jobs.
* Added --total-jobs argument to compute batching strategy.
* Performance tends to plateau around 16–24 threads per job for most workflows/scripts.
* Leaves configurable cores reserved for system tasks.
"""
from __future__ import annotations

import argparse
import sys
import math
import psutil


def positive_float(val: str) -> float:
    f = float(val)
    if f <= 0.0:
        raise argparse.ArgumentTypeError(f"invalid positive float value: {val}")
    return f


def fraction_float(val: str) -> float:
    f = float(val)
    if not (0.0 < f <= 1.0):
        raise argparse.ArgumentTypeError(
            f"invalid fraction for safe‑mem (must be >0 and ≤1): {val}"
        )
    return f


def detect_hardware() -> tuple[int, float]:
    """Return (logical cores, total RAM GB)."""
    cores = psutil.cpu_count(logical=True) or 1
    ram_gb = psutil.virtual_memory().total / 2**30
    return cores, ram_gb


# ---------- main ----------------------------------------------------
def main() -> None:
    parser = argparse.ArgumentParser(
        description="Compute max parallel MRI workflows based on cores & RAM.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--mem-per-job", type=positive_float, required=True,
        help="Peak RAM per subject/job in GB"
    )
    parser.add_argument(
        "--safe-mem", type=fraction_float, default=0.9,
        help="Fraction of total RAM to allow for jobs"
    )
    parser.add_argument(
        "--reserve-cores", type=int, default=2,
        help="Number of cores to leave unallocated for system tasks"
    )
    parser.add_argument(
        "--total-jobs", type=int, default=None,
        help="Total number of jobs to schedule (optional, for batching)"
    )
    args = parser.parse_args()

    # Detect hardware
    cores, total_ram = detect_hardware()
    if args.mem_per_job > total_ram:
        sys.exit(
            f"mem-per-job ({args.mem_per_job} GB) exceeds total RAM ({total_ram:.1f} GB)"
        )

    # Reserve cores for system
    reserve = max(0, args.reserve_cores)
    avail_cores = max(1, cores - reserve)

    # Compute capacity by RAM
    ram_cap = int((total_ram * args.safe_mem) // args.mem_per_job) or 1

    # Determine cores per job to distribute available cores over RAM-limited jobs
    cores_per_job = max(1, avail_cores // ram_cap)

    # Optionally cap cores per job at plateau (16-24 threads)
    plateau = 24
    if cores_per_job > plateau:
        cores_per_job = plateau

    # Compute capacity by CPU using computed cores_per_job
    cpu_cap = avail_cores // cores_per_job or 1

    # Final max parallel jobs limited by both RAM and CPU
    max_jobs = min(ram_cap, cpu_cap)

    print("""
* Note: performance tends to plateau around 16–24 threads per job for most workflows/scripts.
""")
    print(f"Detected hardware      : {cores} logical cores, {total_ram:.1f} GB RAM")
    print(f"Reserving for system   : {reserve} core(s)")
    print(f"Cores available for jobs: {avail_cores}")
    print(f"Per-job requirements   : {cores_per_job} core(s), {args.mem_per_job} GB RAM")
    print(f"Safe RAM fraction      : {args.safe_mem * 100:.0f}%")
    print(f"→ Maximum parallel jobs: {max_jobs}")

    # Batching strategy if total jobs specified
    if args.total_jobs is not None:
        total = args.total_jobs
        batches = math.ceil(total / max_jobs)
        print(f"\nBatching strategy for {total} total jobs:")
        print(f"  • Jobs per batch          : {max_jobs}")
        print(f"  • Cores per job           : {cores_per_job}")
        print(f"  • Number of batches       : {batches}")

if __name__ == "__main__":
    main()