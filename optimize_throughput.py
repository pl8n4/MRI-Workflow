#!/usr/bin/env python3
"""
optimize_fmri_throughput.py  ▸  Recommend thread-count (cores per subject)
for AFNI @SSwarper or afni_proc.py based on reference speed-up curves,
current machine resources, and user-supplied RAM needs.

Key features
============
* Auto-detect CPU cores & RAM via psutil (physical or logical).
* Derive speed-scaling factor k by querying actual CPU max frequency.
* RAM- and CPU-aware: caps concurrency so total RSS and CPU threads never exceed limits.
* Two-phase batching: computes optimal config for full-size batches and the final remainder batch.
* Input validation: ensures mem-per-job > 0 and safe-mem in (0,1].

Usage examples
--------------
```bash
python optimize_fmri_throughput.py --workflow sswarper \
       --subjects 100 --mem-per-job 5 --safe-mem 0.9 --logical-cores
```
```bash
python optimize_fmri_throughput.py --workflow afni_proc \
       --subjects 50 --mem-per-job 4 --freq-scale 1.1
```
"""
from __future__ import annotations
import argparse
from typing import Dict, Tuple
import psutil

try:
    from tabulate import tabulate
except ImportError:
    raise SystemExit("tabulate not installed. ➜ pip install tabulate")

# Reference CPU freq for original benchmark (MHz)
REFERENCE_CPU_FREQ_MHZ = 2600.0

# Reference runtimes (minutes) for thread counts
RUNTIME_TABLE: Dict[str, Dict[int, float]] = {
    "sswarper": {1: 125.98, 2: 86.935, 3: 74.313, 4: 65.29,
                  8: 50.255, 12: 45.99, 16: 44.35, 24: 43.75, 32: 44.4},
    "afni_proc": {1: 23.802, 2: 20.75, 3: 19.078, 4: 18.954,
                  8: 17.614, 12: 17.199, 16: 17.1055, 24: 16.937, 32: 17.129},
}


def positive_float(val: str) -> float:
    f = float(val)
    if f <= 0.0:
        raise argparse.ArgumentTypeError(f"invalid positive float value: {val}")
    return f


def fraction_float(val: str) -> float:
    f = float(val)
    if not (0.0 < f <= 1.0):
        raise argparse.ArgumentTypeError(
            f"invalid fraction for safe-mem (must be >0 and ≤1): {val}"
        )
    return f


def detect_hardware(use_logical: bool = False) -> Tuple[int, float]:
    """Return (cores, total_RAM_GB), using logical or physical cores."""
    cores = psutil.cpu_count(logical=use_logical)
    # Fallback if None
    if cores is None:
        cores = psutil.cpu_count(logical=not use_logical) or 1
    total_ram = psutil.virtual_memory().total / 1024**3
    return cores, total_ram


def detect_cpu_freq_mhz() -> float:
    """Query CPU max frequency: psutil, fallback to /proc/cpuinfo."""
    freq = psutil.cpu_freq()
    if freq and freq.max:
        return freq.max
    try:
        with open('/proc/cpuinfo') as f:
            mhzs = [float(line.split(':')[1]) for line in f if 'cpu MHz' in line]
        return sum(mhzs) / len(mhzs)
    except Exception:
        return freq.current if freq and freq.current else REFERENCE_CPU_FREQ_MHZ


def best_thread_count(
    runtime_curve: Dict[int, float],
    total_ram: float,
    mem_per_job: float,
    safe_frac: float,
    cores: int,
    max_jobs: int | None = None,
) -> Tuple[int, int, float]:
    """Return (best_threads, max_concurrency, jobs_per_h_at_ref_speed)."""
    usable_ram = total_ram * safe_frac
    ram_conc = int(usable_ram // mem_per_job) or 1
    best: tuple[float, int, int] | None = None
    for t, rt_min in runtime_curve.items():
        cpu_conc = cores // t or 1
        conc = min(ram_conc, cpu_conc)
        if max_jobs is not None:
            conc = min(conc, max_jobs)
        tph = conc / rt_min * 60  # jobs/hour at reference speed
        cand = (tph, t, conc)
        if best is None or cand > best:
            best = cand
    if best is None:
        raise RuntimeError(
            "No valid thread count – check mem-per-job or RUNTIME_TABLE."
        )
    tph, tb, cb = best
    return tb, cb, tph


def main():
    parser = argparse.ArgumentParser(
        description="Recommend optimal cores/subject for AFNI pipelines.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--workflow", choices=RUNTIME_TABLE,
        required=True, help="Which curve to use."
    )
    parser.add_argument(
        "--subjects", type=int, default=0,
        help="# of subjects (0 → skip ETA)"
    )
    parser.add_argument(
        "--mem-per-job", type=positive_float, required=True,
        help="Peak RAM per job (GB, must be >0)"
    )
    parser.add_argument(
        "--safe-mem", type=fraction_float, default=0.9,
        help="Fraction of RAM to use (must be >0 and ≤1)"
    )
    parser.add_argument(
        "--freq-scale", type=positive_float,
        help="Override speed-scaling factor k"
    )
    parser.add_argument(
        "--logical-cores", action="store_true", default=False,
        help="Use logical CPU count (including hyperthreads) instead of physical cores"
    )
    args = parser.parse_args()

    cores, ram = detect_hardware(args.logical_cores)
    if args.mem_per_job > ram:
        raise SystemExit(
            f"mem-per-job ({args.mem_per_job} GB) exceeds total RAM {ram:.1f} GB"
        )

    curve = {t: m for t, m in RUNTIME_TABLE[args.workflow].items() if t <= cores}
    if not curve:
        raise SystemExit(
            "No entries ≤ available cores; expand RUNTIME_TABLE or use fewer cores."
        )

    # Phase 1: full-size batches
    best_t_full, best_conc_full, ref_tph_full = best_thread_count(
        curve, ram, args.mem_per_job, args.safe_mem, cores
    )

    # Determine scaling factor k
    if args.freq_scale:
        k = args.freq_scale
        note = f"user-supplied k={k:.2f}×"
    else:
        cpu_mhz = detect_cpu_freq_mhz()
        k = cpu_mhz / REFERENCE_CPU_FREQ_MHZ
        note = (
            f"detected CPU max {cpu_mhz:.0f}MHz / {REFERENCE_CPU_FREQ_MHZ:.0f}MHz = {k:.2f}×"
        )

    tph_full = ref_tph_full * k

    print(f"Detected: {cores} cores, {ram:.1f} GB RAM ({'logical' if args.logical_cores else 'physical'} count)")
    print(f"Workflow: {args.workflow}")
    print(f"RAM limit allows {best_conc_full} jobs (mem-per-job={args.mem_per_job} GB)")
    print(f"Scaling factor k: {note}")

    # Show full-phase recommendation
    print("\nPhase 1: full batches optimal config:")
    print(tabulate(
        [[best_t_full, best_conc_full, f"{tph_full:,.1f}"]],
        headers=["thr/job","jobs","jobs/h"], tablefmt="plain"
    ))

    if args.subjects > 0:
        total = args.subjects
        full_batches = total // best_conc_full
        full_jobs = full_batches * best_conc_full
        t1 = full_jobs / tph_full * 3600
        h1 = int(t1 // 3600)
        m1 = int((t1 % 3600) // 60)
        R = total - full_jobs

        print(f"Time for {full_jobs} subjects: {h1} h {m1} m")

        if R > 0:
            # Phase 2: remainder batch
            best_t_rem, best_conc_rem, ref_tph_rem = best_thread_count(
                curve, ram, args.mem_per_job, args.safe_mem, cores, max_jobs=R
            )
            tph_rem = ref_tph_rem * k
            t2 = R / tph_rem * 3600
            h2 = int(t2 // 3600)
            m2 = int((t2 % 3600) // 60)

            print("\nPhase 2: remainder batch optimal config:")
            print(tabulate(
                [[best_t_rem, best_conc_rem, f"{tph_rem:,.1f}"]],
                headers=["thr/job","jobs","jobs/h"], tablefmt="plain"
            ))
            print(f"Time for {R} subjects: {h2} h {m2} m")

            # Total ETA
            t_tot = t1 + t2
            ht = int(t_tot // 3600)
            mt = int((t_tot % 3600) // 60)
            print(f"\nTotal wall-time estimated: {ht} h {mt} m")


if __name__ == "__main__":
    main()
