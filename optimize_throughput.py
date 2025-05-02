#!/usr/bin/env python3
"""
optimize_throughput.py  ─ Recommend thread‑count (cores per subject)
for AFNI @SSwarper or afni_proc.py based on reference speed‑up curves,
current machine resources, and user‑supplied RAM needs.

Key features
============
* Auto‑detect logical CPU cores & RAM via psutil.
* Derive speed‑scaling factor k by querying advertised CPU max frequency.
* RAM‑ and CPU‑aware: caps concurrency so total RSS and CPU threads never exceed limits.
* Two-phase batching: computes optimal config for full-size batches and the final remainder batch.
* Shortcut logic for highly-core-loaded, few‑subject runs: ideal threads = cores/subjects (capped) with interpolation.
* Input validation: ensures mem-per-job > 0 and safe-mem in (0,1].

Usage examples
--------------
```bash
python optimize_throughput.py --workflow sswarper \
       --subjects 100 --mem-per-job 5 --safe-mem 0.9
```
```bash
python optimize_throughput.py --workflow afni_proc \
       --subjects 50 --mem-per-job 4 --freq-scale 1.1
```
"""
from __future__ import annotations
import argparse
from typing import Dict, Tuple
import glob
import psutil
from tabulate import tabulate

# Reference runtime curves: threads → minutes per subject at ref speed
RUNTIME_TABLE: Dict[str, Dict[int, float]] = {
    "sswarper": {
        1: 125.98, 2: 86.935, 3: 74.313, 4: 65.29,
        8: 50.255, 12: 45.99, 16: 44.35, 24: 43.75, 32: 44.4
    },
    "afni_proc": {
        1: 23.802, 2: 20.75, 3: 19.078, 4: 18.954,
        8: 17.614, 12: 17.199, 16: 17.1055, 24: 16.937, 32: 17.129
    },
}

REFERENCE_CPU_FREQ_MHZ = 3700.0
CAP_THREADS = 24  # maximum threads/job cap for ideal logic


def detect_hardware() -> tuple[int, float]:
    """Return (logical_cores, total_RAM_GB)."""
    cores = psutil.cpu_count(logical=True) or 1
    mem = psutil.virtual_memory().total / (1024**3)
    return cores, mem


def detect_cpu_freq_mhz() -> float:
    """
    Return the advertised maximum CPU frequency in MHz.
    Attempts in order:
      1) psutil.cpu_freq().max
      2) sysfs cpuinfo_max_freq (/sys/devices/system/cpu/*)
      3) fall back to current /proc/cpuinfo average
      4) default REFERENCE_CPU_FREQ_MHZ
    """
    # 1) psutil max
    try:
        freq = psutil.cpu_freq()
        if freq and freq.max and freq.max > 0:
            return freq.max
    except Exception:
        pass
    # 2) sysfs advertised max
    try:
        paths = glob.glob("/sys/devices/system/cpu/cpu[0-9]*/cpufreq/cpuinfo_max_freq")
        if paths:
            mhz_vals = []
            for p in paths:
                with open(p) as f:
                    # value in kHz
                    khz = float(f.read().strip())
                    mhz_vals.append(khz / 1000.0)
            if mhz_vals:
                return sum(mhz_vals) / len(mhz_vals)
    except Exception:
        pass
    # 3) /proc/cpuinfo current
    try:
        with open('/proc/cpuinfo') as f:
            mhzs = [float(line.split(':')[1]) for line in f if 'cpu MHz' in line]
        if mhzs:
            return sum(mhzs) / len(mhzs)
    except Exception:
        pass
    # 4) default
    return REFERENCE_CPU_FREQ_MHZ


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

def best_thread_count(
    runtime_curve: Dict[int, float],
    total_ram: float,
    mem_per_job: float,
    safe_frac: float,
    cores: int,
    max_jobs: int | None = None,
) -> Tuple[int, int, float]:
    """Return (best_threads, max_concurrency, jobs_per_h_at_ref_speed)."""
    best: tuple[float, int, int] | None = None
    for t, rt_min in runtime_curve.items():
        ram_conc = int(total_ram * safe_frac // mem_per_job) or 1
        cpu_conc = cores // t or 1
        conc = min(ram_conc, cpu_conc)
        if max_jobs is not None:
            conc = min(conc, max_jobs)
        tph = conc / rt_min * 60
        cand = (tph, t, conc)
        if best is None or cand > best:
            best = cand
    if best is None:
        raise RuntimeError(
            "No valid thread count – check mem-per-job or RUNTIME_TABLE."
        )
    _, tb, cb = best
    return tb, cb, best[0]


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
        help="Fraction of RAM to reserve (0 < safe-mem ≤ 1)"
    )
    parser.add_argument(
        "--freq-scale", type=positive_float,
        help="Explicit CPU-frequency scaling factor k"
    )
    args = parser.parse_args()

    cores, ram = detect_hardware()
    if args.mem_per_job > ram:
        raise SystemExit(
            f"mem-per-job ({args.mem_per_job} GB) exceeds total RAM {ram:.1f} GB"
        )

    # build baseline curve from known benchmarks
    curve = {t: m for t, m in RUNTIME_TABLE[args.workflow].items() if t <= cores}
    if not curve:
        raise SystemExit(
            "No entries ≤ available cores; expand RUNTIME_TABLE or use fewer cores."
        )

    # Phase 1: full-batch recommendation
    best_t_full, best_conc_full, ref_tph_full = best_thread_count(
        curve, ram, args.mem_per_job, args.safe_mem, cores
    )

    # determine scaling k
    if args.freq_scale:
        k = args.freq_scale
        note = f"user-supplied k={k:.2f}×"
    else:
        cpu_mhz = detect_cpu_freq_mhz()
        k = cpu_mhz / REFERENCE_CPU_FREQ_MHZ
        note = f"detected CPU max {cpu_mhz:.0f}MHz / {REFERENCE_CPU_FREQ_MHZ:.0f}MHz = {k:.2f}×"

    tph_full = ref_tph_full * k

    # caps for info
    ram_cap_jobs = int(ram * args.safe_mem // args.mem_per_job) or 1
    cpu_cap_jobs = cores // best_t_full or 1

    print(f"Detected: {cores} logical cores, {ram:.1f} GB RAM")
    print(f"Workflow: {args.workflow}")
    print(f"Max concurrency: {best_conc_full} jobs (RAM cap={ram_cap_jobs}, CPU cap={cpu_cap_jobs})")
    print(f"Scaling factor k: {note}")

    # Ideal shortcut: threads/job = cores/subjects (capped)
    if args.subjects > 0 and cores > args.subjects:
        ideal = max(1, cores // args.subjects)
        ideal = min(ideal, CAP_THREADS)
        keys = sorted(RUNTIME_TABLE[args.workflow].keys())
        if ideal in RUNTIME_TABLE[args.workflow]:
            rt_min = RUNTIME_TABLE[args.workflow][ideal]
        else:
            lower = max((t for t in keys if t < ideal), default=None)
            upper = min((t for t in keys if t > ideal), default=None)
            if lower is not None and upper is not None:
                m_low = RUNTIME_TABLE[args.workflow][lower]
                m_high = RUNTIME_TABLE[args.workflow][upper]
                rt_min = m_low + (m_high - m_low) * (ideal - lower) / (upper - lower)
            else:
                t_near = lower if lower is not None else upper
                rt_min = RUNTIME_TABLE[args.workflow][t_near]
                ideal = t_near
        best_t = ideal
        best_conc = args.subjects
        tph = best_conc / rt_min * 60 * k
        print(f"\nOptimal config (ideal) for {args.subjects} subjects:")
        print(tabulate(
            [[best_t, best_conc, f"{tph:,.1f}"]],
            headers=["thr/job", "jobs", "jobs/h"], tablefmt="plain"
        ))
        total_time = args.subjects / tph * 3600
        h = int(total_time // 3600)
        m = int((total_time % 3600) // 60)
        print(f"Time for {args.subjects} subjects: {h} h {m} m")
        return

    # Single-batch skip logic if subjects ≤ full concurrency
    if args.subjects > 0 and args.subjects <= best_conc_full:
        total = args.subjects
        best_t, best_conc, ref_tph = best_thread_count(
            curve, ram, args.mem_per_job, args.safe_mem, cores,
            max_jobs=total
        )
        tph = ref_tph * k
        print(f"\nOptimal config for {total} subjects:")
        print(tabulate(
            [[best_t, best_conc, f"{tph:,.1f}"]],
            headers=["thr/job", "jobs", "jobs/h"], tablefmt="plain"
        ))
        total_time = total / tph * 3600
        h = int(total_time // 3600)
        m = int((total_time % 3600) // 60)
        print(f"Time for {total} subjects: {h} h {m} m")
        return

    # Two-phase fallback
    print("\nPhase 1: full batches optimal config:")
    print(tabulate(
        [[best_t_full, best_conc_full, f"{tph_full:,.1f}"]],
        headers=["thr/job", "jobs", "jobs/h"], tablefmt="plain"
    ))

    if args.subjects > 0:
        total = args.subjects
        full_batches = total // best_conc_full
        full_jobs = full_batches * best_conc_full
        t1 = full_jobs / tph_full * 3600
        h1 = int(t1 // 3600)
        m1 = int((t1 % 3600) // 60)
        print(f"Time for {full_jobs} subjects: {h1} h {m1} m")

        remainder = total - full_jobs
        if remainder > 0:
            best_t_rem, best_conc_rem, ref_tph_rem = best_thread_count(
                curve, ram, args.mem_per_job, args.safe_mem, cores,
                max_jobs=remainder
            )
            tph_rem = ref_tph_rem * k
            t2 = remainder / tph_rem * 3600
            h2 = int(t2 // 3600)
            m2 = int((t2 % 3600) // 60)
            print("\nPhase 2: remainder batch optimal config:")
            print(tabulate(
                [[best_t_rem, best_conc_rem, f"{tph_rem:,.1f}"]],
                headers=["thr/job", "jobs", "jobs/h"], tablefmt="plain"
            ))
            print(f"Time for {remainder} subjects: {h2} h {m2} m")

            total_time = t1 + t2
            ht = int(total_time // 3600)
            mt = int((total_time % 3600) // 60)
            print(f"\nTotal wall-time estimated: {ht} h {mt} m")


if __name__ == "__main__":
    main()
