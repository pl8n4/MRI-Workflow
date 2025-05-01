#!/usr/bin/env python3
"""
optimize_fmri_throughput.py  ▸  Recommend thread‑count (cores per subject)
for AFNI @SSwarper or afni_proc.py based on reference speed‑up curves,
current machine resources, and user‑supplied RAM needs.

Why this works
--------------
For each thread‑count **t**, throughput is  jobs/h_t = concurrency_t / runtime_t.
Your measured **runtime★_t** on a reference box supplies the *shape* of the
curve.  On a new machine every runtime is multiplied by the same unknown
factor **k**.  Because *k* cancels when comparing candidates, the ranking of
thread‑counts is hardware‑independent.  A quick micro‑benchmark gives us *k*
only if you want wall‑clock predictions.

Key features
============
* Auto‑detect CPU cores and RAM via **psutil** (cross‑platform).
* Handles both @SSwarper and afni_proc with built‑in reference curves.
* RAM‑aware: caps concurrency so total RSS never exceeds a user‑defined
  fraction of physical memory (default 90 %).
* **FAST** micro‑benchmark (`--quick-bench cpu`) – a single 2048×2048 FP32
  matrix multiply – adds ≈ 5 s but saves hour‑long calibration runs.
* Clear CLI report with the **tabulate** library.

Usage examples
--------------
```bash
# 80 subjects, expect each job to peak at 6 GB, leave 10 % RAM headroom
python optimize_fmri_throughput.py --workflow sswarper \
       --subjects 80 --mem-per-job 6

# Skip micro‑benchmark, just pick best threads and show relative jobs/h
python optimize_fmri_throughput.py --workflow afni_proc --quick-bench none
```
"""
from __future__ import annotations

import argparse
import math
import time
from typing import Dict, Tuple

try:
    import psutil
except ImportError as e:  # pragma: no cover
    raise SystemExit("psutil not installed.  ➜  pip install psutil") from e
try:
    from tabulate import tabulate
except ImportError as e:  # pragma: no cover
    raise SystemExit("tabulate not installed.  ➜  pip install tabulate") from e

# ---------------------------- Reference curves ----------------------------- #
# Average runtime per subject (minutes) vs. threads collected on a 56‑core,
# 125 GB AMD EPYC 7513 node running CentOS 8.
# Extend/replace if you have newer data.
RUNTIME_TABLE: Dict[str, Dict[int, float]] = {
    "sswarper": {
        1: 125.98, 2: 86.935, 3: 74.313, 4: 65.29,
        8: 50.255, 12: 45.99, 16: 44.35, 24: 43.75, 32: 44.4,
    },
    "afni_proc": {
        1: 23.802, 2: 20.75, 3: 19.078, 4: 18.954,
        8: 17.614, 12: 17.199, 16: 17.1055, 24: 16.937, 32: 17.129,
    },
}

# -------------- Micro‑benchmark (matrix multiply) reference ---------------- #
# On the same reference node above, multiplying two 2048×2048 FP32 matrices
# using NumPy + OpenBLAS (single process) takes ≈ 0.57 s.
MICRO_BENCH_REF_SEC = 0.57


# --------------------------------------------------------------------------- #
#                               Helper functions                              #
# --------------------------------------------------------------------------- #

def detect_hardware() -> Tuple[int, float]:
    """Return (physical_cores, total_RAM_GB)."""
    phys = psutil.cpu_count(logical=False) or psutil.cpu_count(logical=True)
    ram_gb = psutil.virtual_memory().total / 1024 ** 3  # bytes → GB
    return phys, ram_gb


def quick_cpu_bench() -> float:
    """Time a single 2048×2048 FP32 GEMM using NumPy. Returns wall time (sec)."""
    import numpy as np

    n = 2048
    a = np.random.randn(n, n).astype(np.float32)
    b = np.random.randn(n, n).astype(np.float32)
    start = time.perf_counter()
    _ = a @ b
    return time.perf_counter() - start


# --------------------------------------------------------------------------- #
#                               Core algorithm                                #
# --------------------------------------------------------------------------- #

def best_thread_count(
    runtime_curve: Dict[int, float],
    total_ram_gb: float,
    mem_per_job: float,
    safe_mem_frac: float,
) -> Tuple[int, int, float]:
    """Return (threads_per_job, max_concurrency, jobs_per_hour)."""
    usable_ram = total_ram_gb * safe_mem_frac
    best = None  # (jobs_per_h, t, concurrency)

    for t, runtime_min in runtime_curve.items():
        concurrency = max(int(usable_ram // (mem_per_job * t)), 1)
        jobs_per_h = concurrency / runtime_min * 60  # min → h
        candidate = (jobs_per_h, t, concurrency)
        if best is None or candidate > best:
            best = candidate

    if best is None:
        raise RuntimeError("No valid thread count found – check inputs")

    jobs_per_h, t_best, concurrency_best = best
    return t_best, concurrency_best, jobs_per_h


def main():  # noqa: C901
    parser = argparse.ArgumentParser(
        description="Recommend optimal cores/subject for AFNI pipelines.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--workflow", choices=RUNTIME_TABLE.keys(), required=True,
                        help="Which benchmark curve to use (sswarper or afni_proc)")
    parser.add_argument("--subjects", type=int, default=0,
                        help="Number of subjects to process (0 → skip ETA calc)")
    parser.add_argument("--mem-per-job", type=float, required=True,
                        help="Peak resident memory per subject (GB)")
    parser.add_argument("--safe-mem", type=float, default=0.9,
                        help="Fraction of total RAM allowed for jobs")
    parser.add_argument("--quick-bench", choices=["cpu", "none"], default="cpu",
                        help="Run micro‑benchmark to scale wall‑time estimates")
    parser.add_argument("--freq-scale", type=float,
                        help="Override scaling factor k (1.0 → same speed as ref)")

    args = parser.parse_args()

    phys_cores, total_ram = detect_hardware()

    if args.mem_per_job * args.safe_mem > total_ram:
        raise SystemExit(
            f"mem‑per‑job ({args.mem_per_job} GB) too high for total RAM {total_ram:.1f} GB")

    runtime_curve = {t: m for t, m in RUNTIME_TABLE[args.workflow].items() if t <= phys_cores}
    if not runtime_curve:
        raise SystemExit("No benchmark entries ≤ available cores; extend RUNTIME_TABLE?")

    t_best, conc_best, jobs_per_h = best_thread_count(
        runtime_curve, total_ram, args.mem_per_job, args.safe_mem)

    # ------ scaling factor k ------------------------------------------------ #
    if args.freq_scale is not None:
        k = args.freq_scale
        scale_note = f"(user‑supplied {k:.2f}×)"
    elif args.quick_bench == "cpu":
        bench_t = quick_cpu_bench()
        k = bench_t / MICRO_BENCH_REF_SEC
        scale_note = f"(CPU micro‑bench {bench_t:.2f} s  ⇒  k = {k:.2f}×)"
    else:  # quick‑bench none
        k = 1.0
        scale_note = "(reference speed; estimates may differ)"

    # scaled throughput & ETA
    scaled_jobs_per_h = jobs_per_h / k
    rows = [[t_best, conc_best, f"{scaled_jobs_per_h:,.2f}"]]

    if args.subjects > 0:
        hours = args.subjects / scaled_jobs_per_h
        eta_str = time.strftime("%‑H h %‑M m", time.gmtime(hours * 3600))
    else:
        eta_str = "n/a"

    # --------------------- Report ------------------------------------------ #
    print()
    print(f"Detected: {phys_cores} physical cores, {total_ram:.1f} GB RAM")
    print(f"Workflow : {args.workflow}")
    print(f"RAM/headroom  : {args.mem_per_job} GB/job  •  safe mem frac = {args.safe_mem*100:.0f}%")
    print(f"Scaling factor k  {scale_note}")
    print("\nOptimal configuration (RAM‑safe):")
    print(tabulate(rows, headers=["threads/job", "jobs", "jobs/hour"], tablefmt="rounded_grid"))
    if args.subjects:
        print(f"\nEstimated total wall‑time for {args.subjects} subjects: {eta_str}")
    print()


if __name__ == "__main__":
    main()
