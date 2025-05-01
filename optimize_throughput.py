#!/usr/bin/env python3
"""
optimize_fmri_throughput.py  ▸  Recommend thread-count (cores per subject)
for AFNI @SSwarper or afni_proc.py based on reference speed-up curves,
current machine resources, and user-supplied RAM needs.

Key features
============
* Auto-detect CPU cores & RAM via psutil.
* Derive speed-scaling factor k by querying the actual CPU max frequency.
* RAM- and CPU-aware: caps concurrency so total RSS and CPU threads never
  exceed user-defined memory fraction (default 90%) and available cores.
* Input validation: ensures mem-per-job > 0 and safe-mem in (0,1].

Usage examples
--------------
```bash
# 80 subjects, sswarper, each uses ~6 GB, leave 10% RAM free
python optimize_fmri_throughput.py --workflow sswarper \
       --subjects 80 --mem-per-job 6 --safe-mem 0.9
```
```bash
# override scale factor:
python optimize_fmri_throughput.py --workflow afni_proc \
       --subjects 80 --mem-per-job 6 --freq-scale 1.2
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


def detect_hardware() -> Tuple[int, float]:
    """Return (physical_cores, total_RAM_GB)."""
    cores = psutil.cpu_count(logical=False) or psutil.cpu_count()
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
    cores: int
) -> Tuple[int, int, float]:
    """Return (best_threads, max_concurrency, jobs_per_h_at_ref_speed)."""
    usable_ram = total_ram * safe_frac
    best: tuple[float, int, int] | None = None
    for t, rt_min in runtime_curve.items():
        ram_conc = int(usable_ram // (mem_per_job * t)) or 1
        cpu_conc = cores // t or 1
        conc = min(ram_conc, cpu_conc)
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
    args = parser.parse_args()

    cores, ram = detect_hardware()
    if args.mem_per_job * args.safe_mem > ram:
        raise SystemExit(
            f"mem-per-job ({args.mem_per_job} GB) * safe-mem ({args.safe_mem}) "
            f"> total RAM {ram:.1f} GB"
        )

    curve = {t: m for t, m in RUNTIME_TABLE[args.workflow].items() if t <= cores}
    if not curve:
        raise SystemExit(
            "No entries ≤ available cores; expand RUNTIME_TABLE or use fewer cores."
        )

    best_t, best_conc, ref_tph = best_thread_count(
        curve, ram, args.mem_per_job, args.safe_mem, cores
    )

    if args.freq_scale:
        k = args.freq_scale
        note = f"user-supplied k={k:.2f}×"
    else:
        cpu_mhz = detect_cpu_freq_mhz()
        k = cpu_mhz / REFERENCE_CPU_FREQ_MHZ
        note = (
            f"detected CPU max {cpu_mhz:.0f}MHz / "
            f"{REFERENCE_CPU_FREQ_MHZ:.0f}MHz = {k:.2f}×"
        )

    # Correct throughput scaling: multiply by k (faster CPU => higher jobs/h)
    tph = ref_tph * k
    if args.subjects > 0:
        secs = args.subjects / tph * 3600
        h = int(secs // 3600)
        m = int((secs % 3600) // 60)
        eta = f"{h} h {m} m"
    else:
        eta = "n/a"

    print(f"Detected: {cores} physical cores, {ram:.1f} GB RAM")
    print(f"Workflow: {args.workflow}")
    print(f"RAM/job: {args.mem_per_job} GB  safe_frac={args.safe_mem*100:.0f}%")
    print(f"Scaling factor k: {note}")
    print("\nOptimal (threads/job, concurrent jobs, jobs/hour):")
    print(tabulate(
        [[best_t, best_conc, f"{tph:,.1f}"]],
        headers=["thr/job","jobs","jobs/h"],
        tablefmt="plain"
    ))
    if args.subjects > 0:
        print(f"Estimated total wall-time ({args.subjects} subj): {eta}")

if __name__ == "__main__":
    main()
