#!/usr/bin/env python3
"""Clock-period sweep for one variant and one implementation strategy.

Procedure (identical for every variant):
  1. Coarse bracket: four periods at 0.5 ns spacing around --start, extended
     downward until a failure appears and upward until a pass appears.
  2. Refine at 0.1 ns inside the bracket formed by the shortest passing
     period and the next shorter failing period.
  3. Refine once more at 0.05 ns (the declared search resolution).

A run passes only when setup, hold, and pulse-width slack are all >= 0,
routing has no errors, and DRC reports no errors (see impl_one.tcl).
The result is the shortest passing tested period and the next shorter tested
period that failed.  Routed results are not monotonic in the period, so every
tested point is kept in sweep.json and non-monotonic points are reported.
"""

import argparse
import json
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

EXP = Path(__file__).resolve().parents[1]
REPO = EXP.parents[1]
VIVADO = r"C:\Xilinx\Vivado\2023.2\bin\vivado.bat"
RESOLUTION = 0.05


def run_one(variant, rtl_dir, strategy, period):
    out = EXP / "results" / "runs" / f"{variant}_{strategy}" / f"p{period:.3f}"
    result = out / "result.json"
    if result.exists():
        return json.loads(result.read_text())
    out.mkdir(parents=True, exist_ok=True)
    cmd = [VIVADO, "-mode", "batch", "-nojournal", "-log", str(out / "vivado.log"),
           "-source", str(EXP / "scripts" / "impl_one.tcl"), "-tclargs",
           str(rtl_dir), f"{period:.3f}", strategy, str(out)]
    # A run with no result.json is a tool failure (seen once: Vivado could not
    # read its own temporary synthesis script under parallel load), not a
    # timing failure, so it is retried once before being recorded as failed.
    for _ in range(2):
        subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False, cwd=out)
        if result.exists():
            break
    if not result.exists():
        return {"period_ns": period, "pass": False, "error": "no result.json; see vivado.log"}
    return json.loads(result.read_text())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--variant", required=True)
    ap.add_argument("--rtl", required=True, type=Path)
    ap.add_argument("--strategy", default="default")
    ap.add_argument("--start", type=float, required=True, help="first-guess period (ns)")
    ap.add_argument("--jobs", type=int, default=4)
    args = ap.parse_args()

    results = {}

    def batch(periods):
        periods = sorted({round(p, 3) for p in periods if p > 2.0 and round(p, 3) not in results})
        if not periods:
            return
        with ThreadPoolExecutor(args.jobs) as pool:
            for p, r in zip(periods, pool.map(lambda q: run_one(args.variant, args.rtl.resolve(), args.strategy, q), periods)):
                results[p] = r
                print(f"{args.variant}/{args.strategy} period={p:.3f} wns={r.get('wns_ns')} "
                      f"whs={r.get('whs_ns')} wpws={r.get('wpws_ns')} pass={r['pass']}", flush=True)

    def bracket():
        passing = [p for p, r in results.items() if r["pass"]]
        if not passing:
            return None, None
        best = min(passing)
        shorter_fail = [p for p, r in results.items() if not r["pass"] and p < best]
        return best, (max(shorter_fail) if shorter_fail else None)

    s = round(args.start * 20) / 20
    batch([s - 1.0, s - 0.5, s, s + 0.5])
    for _ in range(6):
        best, fail = bracket()
        if best is None:
            top = max(results)
            batch([top + 0.5, top + 1.0])
        elif fail is None:
            batch([best - 0.5, best - 1.0])
        else:
            break
    best, fail = bracket()
    if best is None or fail is None:
        sys.exit("could not bracket the passing region")

    for step in (0.1, RESOLUTION):
        while True:
            best, fail = bracket()
            points = []
            p = round(best - step, 3)
            while p > fail + 1e-9:
                points.append(p)
                p = round(p - step, 3)
            if not points:
                break
            batch(points[:args.jobs])

    best, fail = bracket()
    nonmono = sorted(p for p, r in results.items() if r["pass"] and any(
        not results[q]["pass"] for q in results if q > p))
    summary = {
        "variant": args.variant, "strategy": args.strategy, "rtl": str(args.rtl),
        "resolution_ns": RESOLUTION,
        "best_pass_period_ns": best, "best_pass_mhz": round(1000 / best, 2),
        "next_fail_period_ns": fail, "next_fail_mhz": round(1000 / fail, 2),
        "non_monotonic_passes": nonmono,
        "points": [results[p] | {"period_ns": p} for p in sorted(results)],
    }
    out = EXP / "results" / "sweeps" / f"{args.variant}_{args.strategy}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(summary, indent=2))
    print(f"BEST {args.variant}/{args.strategy}: pass {best:.3f} ns ({1000/best:.1f} MHz), "
          f"next fail {fail:.3f} ns ({1000/fail:.1f} MHz)")


if __name__ == "__main__":
    main()
