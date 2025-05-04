#!/usr/bin/env python3
"""
optimize_workflow.py  ─ Recommend per‑subject threading plans
for AFNI (@SSwarper, afni_proc) **and MRIQC** based on reference
speed‑up curves, current hardware, and RAM constraints.

New in 2025‑05‑04
=================
* Added **MRIQC** workflow:
  • placeholder runtime curve in `RUNTIME_TABLE["mriqc"]`
    (1, 2, 4, 8, 12‑thread points).
  • default peak RAM per job = **10 GB** (overridable via
    `--mem-per-job`).
* CLI help/choices auto‑extend from `RUNTIME_TABLE`; no flags
  changed, so existing calls stay valid.
* Clearly marked where to drop empirical runtimes or load an
  external JSON in future (see “‑‑‑ USER‑EDITABLE SECTION ‑‑‑”).
"""
from __future__ import annotations

import argparse
import glob
from typing import Dict, Tuple

import psutil
from tabulate import tabulate

# --------------------------------------------------------------------
# USER‑EDITABLE SECTION – reference runtimes at 3.7 GHz
# --------------------------------------------------------------------
RUNTIME_TABLE: Dict[str, Dict[int, float]] = {
    # @SSwarper (AFNI)
    "sswarper": {
        1: 125.98, 2: 86.935, 3: 74.313, 4: 65.29,
        8: 50.255, 12: 45.99, 16: 44.35, 24: 43.75, 32: 44.4
    },
    # afni_proc.py (AFNI)
    "afni_proc": {
        1: 23.802, 2: 20.75, 3: 19.078, 4: 18.954,
        8: 17.614, 12: 17.199, 16: 17.1055, 24: 16.937, 32: 17.129
    },
    # MRIQC ‑‑ placeholder numbers, replace after benchmarks
    "mriqc": {
        1: 90.0,     # ← replace with real minutes/subject
        2: 65.0,
        4: 48.0,
        8: 35.0,
        12: 32.0,
    },
}
DEFAULT_MEM_GB: dict[str, float] = {
    "mriqc": 10.0,  # ≈ 8‑12 GB typically required
}
# --------------------------------------------------------------------

REFERENCE_CPU_FREQ_MHZ = 3700.0          # workstation used for benchmarks
CAP_THREADS = 24                         # don’t bother > 24 threads/job


# ---------- helpers -------------------------------------------------
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


def detect_hardware() -> Tuple[int, float]:
    """Return (logical cores, total RAM GB)."""
    return psutil.cpu_count(logical=True) or 1, psutil.virtual_memory().total / 2**30


def detect_cpu_freq_mhz() -> float:
    """Best‑effort advertised max‑freq in MHz."""
    try:
        f = psutil.cpu_freq()
        if f and f.max:
            return f.max
    except Exception:
        pass
    try:
        with open("/proc/cpuinfo") as fh:
            mhz = [float(l.split(":")[1]) for l in fh if "cpu MHz" in l]
        return sum(mhz) / len(mhz)
    except Exception:
        return REFERENCE_CPU_FREQ_MHZ


def best_thread_count(
    runtime_curve: Dict[int, float],
    total_ram: float,
    mem_per_job: float,
    safe_frac: float,
    cores: int,
    max_jobs: int | None = None,
) -> Tuple[int, int, float]:
    """
    Return (threads/job, jobs, jobs/h @ reference CPU).
    """
    best: tuple[float, int, int] | None = None
    ram_conc = int(total_ram * safe_frac // mem_per_job) or 1
    for t, rt_min in runtime_curve.items():
        cpu_conc = cores // t or 1
        conc = min(ram_conc, cpu_conc)
        if max_jobs is not None:
            conc = min(conc, max_jobs)
        tph = conc / rt_min * 60
        cand = (tph, t, conc)
        if best is None or cand > best:
            best = cand
    if best is None:
        raise RuntimeError("No viable config – check RAM limits or runtime table.")
    _, thr, nj = best
    return thr, nj, best[0]


# ---------- main ----------------------------------------------------
def main() -> None:
    parser = argparse.ArgumentParser(
        description="Recommend optimal batching for AFNI + MRIQC.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--workflow", choices=RUNTIME_TABLE.keys(), required=True,
        help="Which pipeline speed‑curve to use.",
    )
    parser.add_argument(
        "--subjects", type=int, default=0,
        help="# of subjects (0 → skip ETA).",
    )
    parser.add_argument(
        "--mem-per-job", type=positive_float, default=None, required=False,
        help="Peak RAM per job (GB).  MRIQC defaults to 10 GB if omitted.",
    )
    parser.add_argument(
        "--safe-mem", type=fraction_float, default=0.9,
        help="Fraction of total RAM you allow jobs to use.",
    )
    parser.add_argument(
        "--freq-scale", type=positive_float,
        help="Override CPU‑frequency scaling factor k.",
    )
    args = parser.parse_args()

    # Workflow‑specific default RAM
    if args.mem_per_job is None:
        default_mem = DEFAULT_MEM_GB.get(args.workflow)
        if default_mem:
            args.mem_per_job = default_mem
        else:
            parser.error("--mem-per-job is required for workflow "
                         f"'{args.workflow}'")

    cores, ram = detect_hardware()
    if args.mem_per_job > ram:
        raise SystemExit(
            f"mem-per-job ({args.mem_per_job} GB) exceeds total RAM "
            f"{ram:.1f} GB."
        )

    curve = {t: m for t, m in RUNTIME_TABLE[args.workflow].items() if t <= cores}
    if not curve:
        raise SystemExit(
            "No runtime entries ≤ available cores; extend RUNTIME_TABLE "
            "or use fewer cores."
        )

    # 1️⃣  Full‑batch optimisation
    best_t, best_jobs, ref_tph = best_thread_count(
        curve, ram, args.mem_per_job, args.safe_mem, cores
    )

    # Scaling factor k
    if args.freq_scale:
        k = args.freq_scale
        note = f"user‑supplied k = {k:.2f}×"
    else:
        cpu_mhz = detect_cpu_freq_mhz()
        k = cpu_mhz / REFERENCE_CPU_FREQ_MHZ
        note = f"detected {cpu_mhz:.0f}/{REFERENCE_CPU_FREQ_MHZ:.0f} MHz → k = {k:.2f}×"

    tph = ref_tph * k
    ram_cap = int(ram * args.safe_mem // args.mem_per_job) or 1
    cpu_cap = cores // best_t or 1

    print(f"Detected hardware : {cores} logical cores, {ram:.1f} GB RAM")
    print(f"Workflow         : {args.workflow}")
    print(f"Max concurrency  : {best_jobs} jobs (RAM cap = {ram_cap}, "
          f"CPU cap = {cpu_cap})")
    print(f"Scaling factor   : {note}")

    # If subject count small enough for single batch use precise search
    if 0 < args.subjects <= best_jobs:
        thr, jobs, ref_tph2 = best_thread_count(
            curve, ram, args.mem_per_job, args.safe_mem, cores,
            max_jobs=args.subjects
        )
        tph2 = ref_tph2 * k
        ETA_sec = args.subjects / tph2 * 3600
        print("\nOptimal config for this run:")
        print(tabulate([[thr, jobs, f"{tph2:,.1f}"]],
              headers=["thr/job", "jobs", "jobs/h"], tablefmt="plain"))
        print(f"Estimated wall‑time: {int(ETA_sec//3600)} h "
              f"{int((ETA_sec%3600)//60)} m")
        return

    # Otherwise present batching plan
    print("\nPhase 1 – full batches:")
    print(tabulate([[best_t, best_jobs, f"{tph:,.1f}"]],
          headers=["thr/job", "jobs", "jobs/h"], tablefmt="plain"))

    if args.subjects <= 0:
        return  # nothing more to estimate

    total = args.subjects
    full_batches = total // best_jobs
    done = full_batches * best_jobs
    t1 = done / tph * 3600
    h1, m1 = divmod(int(t1 // 60), 60)
    print(f"Time for {done} subjects: {h1} h {m1} m")

    remain = total - done
    if remain:
        thr_r, jobs_r, ref_tph_r = best_thread_count(
            curve, ram, args.mem_per_job, args.safe_mem, cores,
            max_jobs=remain
        )
        tph_r = ref_tph_r * k
        t2 = remain / tph_r * 3600
        h2, m2 = divmod(int(t2 // 60), 60)
        print("\nPhase 2 – remainder:")
        print(tabulate([[thr_r, jobs_r, f"{tph_r:,.1f}"]],
              headers=["thr/job", "jobs", "jobs/h"], tablefmt="plain"))
        print(f"Time for {remain} subjects: {h2} h {m2} m")
        total_sec = t1 + t2
    else:
        total_sec = t1

    ht, mt = divmod(int(total_sec // 60), 60)
    print(f"\nTotal wall‑time estimate: {ht} h {mt} m")


if __name__ == "__main__":
    main()
