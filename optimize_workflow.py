
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
        "--total-jobs", type=int, default=None,
        help="Total number of jobs to schedule (optional, for batching)"
    )
    args = parser.parse_args()

    cores, total_ram = detect_hardware()
    if args.mem_per_job > total_ram:
        sys.exit(
            f"mem-per-job ({args.mem_per_job} GB) exceeds total RAM ({total_ram:.1f} GB)"
        )

    # Compute capacity by RAM and CPU
    ram_cap = int((total_ram * args.safe_mem) // args.mem_per_job) or 1
    cpu_cap = cores // 1 or 1  # at least 1 core per job
    max_jobs = min(ram_cap, cpu_cap)

    print("""
* Note: performance tends to plateau around 16–24 threads per job for most workflows/scripts.
""")
    print(f"Detected hardware : {cores} logical cores, {total_ram:.1f} GB RAM")
    print(f"Per-job requirements: 1 core, {args.mem_per_job} GB RAM")
    print(f"Safe RAM fraction : {args.safe_mem * 100:.0f}%")
    print(f"→ Maximum parallel jobs: {max_jobs}")

    if args.total_jobs is not None:
        total = args.total_jobs
        batches = math.ceil(total / max_jobs)
        print(f"\nBatching strategy for {total} total jobs:")
        print(f"  • Jobs per batch      : {max_jobs}")
        print(f"  • Number of batches   : {batches}")
        print(f"  • Total slots (batches × jobs): {batches * max_jobs}")


if __name__ == "__main__":
    main()

