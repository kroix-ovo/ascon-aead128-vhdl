#!/usr/bin/env python3
"""Combine simulated cycle counts with routed clock sweeps.

Inputs per variant:
  results/sim/<sim_name>/core_unstalled.txt  event log, architectural traffic
  results/sim/<sim_name>/core_stalled.txt    event log, randomized stalls
  results/sim/<sim_name>/perm_results.txt    permutation start-to-done edges
  results/sweeps/<sweep_name>_<strategy>.json routed clock sweep

Output: results/summary.json and results/summary.md.

Latency = measured cycles / shortest passing routed period.  Speedup is
relative to the baseline variant under the same strategy.  No number here is
a board measurement.
"""

import json


from collections import defaultdict
from pathlib import Path

EXP = Path(__file__).resolve().parents[1]
RES = EXP / "results"

# (label, simulation directory, sweep prefix)
VARIANTS = [
    ("A: original one-round baseline", "A", "A"),
    ("A + control: local keep decode (control experiment)", "A_ctrl1", "A_ctrl1"),
    ("A + control: + one-hot controller + tree tag compare (control experiment)", "A_ctrl2", "A_ctrl2"),
    ("B: two-stage reused round", "B_2stage", "B_2stage"),
    ("C: three-stage reused round", "C_3stage", "C_3stage"),
    ("D: B + A_ctrl2 control/locality changes", "D", "D"),
]
STRATEGIES = ["default", "explore", "retime", "explore_retime"]


def parse_events(path):
    events = defaultdict(lambda: defaultdict(list))
    labels = {}
    for line in path.read_text().splitlines():
        f = line.split("|")
        if f[0] == "EV":
            events[int(f[1])][f[2]].append(int(f[3]))
        elif f[0] == "TX":
            labels[int(f[1])] = (f[2], f[3], f[4], f[5])
    return events, labels


def tx_metrics(ev):
    cmd = ev["CMD"][0]
    msg = ev["MSG"]
    intervals = [b - a for a, b in zip(msg, msg[1:])]
    m = {
        "cmd_to_first_out_valid": (ev["OUTV"][0] - cmd) if ev["OUTV"] else None,
        "cmd_to_tag": ev["TAG"][0] - cmd if ev["TAG"] else None,
        "cmd_to_done": ev["DONE"][0] - cmd if ev["DONE"] else None,
        # Accept-to-accept spacing of consecutive payload beats.  Every beat
        # but the last is a full block followed by p8, so these intervals are
        # the diagram's dependent-block interval.
        "full_block_intervals": sorted(set(intervals)),
    }
    if msg:
        m["cmd_to_first_payload_accept"] = msg[0] - cmd
    return m


def cycles_for(sim_name):
    d = RES / "sim" / sim_name
    out = {}
    for mode in ("unstalled", "stalled"):
        f = d / f"core_{mode}.txt"
        if not f.exists():
            continue
        events, labels = parse_events(f)
        bench = {}
        for tx, (label, direction, kind, result) in labels.items():
            if not label.startswith("bench_"):
                continue
            assert result == "PASS" and kind == "FULL", (sim_name, label)
            bench[label] = tx_metrics(events[tx])
        all_int = sorted({i for m in bench.values() for i in m["full_block_intervals"]})
        out[mode] = {"workloads": bench, "full_block_intervals_seen": all_int}
    perm = defaultdict(set)
    for line in (d / "perm_results.txt").read_text().splitlines():
        f = line.split("|")
        if f[0] == "PERM" and f[-1] == "PASS":
            perm[int(f[3])].add(int(f[7]))
    out["perm_start_to_done_edges"] = {k: sorted(v) for k, v in perm.items()}
    return out


def sweep_for(prefix, strategy):
    f = RES / "sweeps" / f"{prefix}_{strategy}.json"
    return json.loads(f.read_text()) if f.exists() else None


def best_point(sweep):
    for p in sweep["points"]:
        if p["period_ns"] == sweep["best_pass_period_ns"]:
            return p
    return None


def main():
    summary = {"variants": {}}
    for label, sim, prefix in VARIANTS:
        if not (RES / "sim" / sim / "perm_results.txt").exists():
            continue
        entry = {"label": label, "cycles": cycles_for(sim), "timing": {}}
        for strat in STRATEGIES:
            sw = sweep_for(prefix, strat)
            if sw:
                bp = best_point(sw)
                entry["timing"][strat] = {
                    "best_pass_period_ns": sw["best_pass_period_ns"],
                    "best_pass_mhz": sw["best_pass_mhz"],
                    "next_fail_period_ns": sw["next_fail_period_ns"],
                    "next_fail_mhz": sw["next_fail_mhz"],
                    "non_monotonic_passes": sw["non_monotonic_passes"],
                    "luts_core": bp.get("luts_core"), "ffs_core": bp.get("ffs_core"),
                    "luts_total": bp.get("luts_total"), "ffs_total": bp.get("ffs_total"),
                    "wns_ns": bp.get("wns_ns"), "whs_ns": bp.get("whs_ns"), "wpws_ns": bp.get("wpws_ns"),
                    "worst_path": (bp.get("paths") or [None])[0],
                    "categories": bp.get("categories"),
                }
        summary["variants"][sim] = entry

    # Elapsed-time comparison against the baseline for each strategy.
    base = summary["variants"].get("A")
    # A at its highest passing tested frequency over every strategy tried.
    a_best = min(base["timing"].values(), key=lambda t: t["best_pass_period_ns"])
    a_best_period = a_best["best_pass_period_ns"]
    a_best_interval = base["cycles"]["unstalled"]["full_block_intervals_seen"][0]
    summary["a_best_period_ns"] = a_best_period
    rows = []
    for sim, v in summary["variants"].items():
        un = v["cycles"]["unstalled"]
        interval = un["full_block_intervals_seen"]
        for strat, t in v["timing"].items():
            bt = base["timing"].get(strat) if base else None
            period = t["best_pass_period_ns"]
            row = {"variant": sim, "strategy": strat, "period_ns": period, "mhz": t["best_pass_mhz"],
                   "next_fail_ns": t["next_fail_period_ns"], "block_interval_cycles": interval,
                   "luts_core": t["luts_core"], "ffs_core": t["ffs_core"]}
            row["block_interval_ns"] = [round(c * period, 3) for c in interval]
            p8 = v["cycles"]["perm_start_to_done_edges"].get(8)
            row["p8_edges"] = p8
            row["p8_ns"] = [round(c * period, 3) for c in p8]
            row["block_speedup_vs_A_best"] = round(a_best_interval * a_best_period / (interval[0] * period), 4)
            if bt:
                bint = base["cycles"]["unstalled"]["full_block_intervals_seen"]
                row["block_speedup"] = round((bint[0] * bt["best_pass_period_ns"]) / (interval[0] * period), 4)
                row["required_freq_ratio"] = round(interval[0] / bint[0], 4)
                row["achieved_freq_ratio"] = round(bt["best_pass_period_ns"] / period, 4)
                wl = {}
                for name, m in un["workloads"].items():
                    bm = base["cycles"]["unstalled"]["workloads"][name]
                    wl[name] = {
                        "cycles": m["cmd_to_done"], "ns": round(m["cmd_to_done"] * period, 2),
                        "baseline_cycles": bm["cmd_to_done"],
                        "speedup": round(bm["cmd_to_done"] * bt["best_pass_period_ns"] / (m["cmd_to_done"] * period), 4),
                        "first_out_cycles": m["cmd_to_first_out_valid"],
                        "first_out_ns": None if m["cmd_to_first_out_valid"] is None else round(m["cmd_to_first_out_valid"] * period, 2),
                    }
                row["workloads"] = wl
            rows.append(row)
    summary["comparison"] = rows
    (RES / "summary.json").write_text(json.dumps(summary, indent=2))
    (RES / "summary.md").write_text(markdown(summary), encoding="utf-8")
    print("wrote", RES / "summary.md")


def markdown(summary):
    out = ["# p8 pipelining: routed comparison", "",
           "Routed timing on xc7a100tcsg324-1 (Vivado 2023.2), registered harness. "
           "Cycles from GHDL simulation. Latency = cycles x shortest passing period. "
           "No board measurement.", ""]
    out.append(f"Speedup columns: vs A under the same strategy, and vs A at its best tested period "
               f"({summary['a_best_period_ns']} ns).")
    out.append("")
    out.append("| Variant | Strategy | Block interval (cyc) | Pass period ns (MHz) | Next fail ns | "
               "Block interval ns | Speedup vs A (same strategy) | Speedup vs best A | Needed f ratio | Achieved f ratio | p8 ns | "
               "1 KiB enc ns | Core LUT | Core FF |")
    out.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for r in summary["comparison"]:
        wl = r.get("workloads", {}).get("bench_ad0_msg1024_enc", {})
        out.append("| {v} | {s} | {c} | {p:.3f} ({m:.1f}) | {nf:.3f} | {bi} | {sp} | {spb} | {need} | {got} | {p8} | {kib} | {lut} | {ff} |".format(
            v=r["variant"], s=r["strategy"], c=r["block_interval_cycles"][0], p=r["period_ns"], m=r["mhz"],
            nf=r["next_fail_ns"], bi=r["block_interval_ns"][0], sp=r.get("block_speedup", "-"),
            spb=r["block_speedup_vs_A_best"],
            need=r.get("required_freq_ratio", "-"), got=r.get("achieved_freq_ratio", "-"),
            p8=r["p8_ns"][0], kib=wl.get("ns", "-"), lut=r["luts_core"], ff=r["ffs_core"]))
    out += ["", "## Whole-message latency at each variant's passing clock (default strategy, unstalled)", ""]
    out.append("| Variant | Workload | Cycles | ns | Baseline cycles | Speedup | First out_valid (cyc / ns) |")
    out.append("|---|---|---|---|---|---|---|")
    for r in summary["comparison"]:
        if r["strategy"] != "default":
            continue
        for name, w in r.get("workloads", {}).items():
            fo = "-" if w["first_out_cycles"] is None else f"{w['first_out_cycles']} / {w['first_out_ns']}"
            out.append(f"| {r['variant']} | {name.removeprefix('bench_')} | {w['cycles']} | {w['ns']} | "
                       f"{w['baseline_cycles']} | {w['speedup']} | {fo} |")
    out += ["", "## Stalled-interface cycles (fixed-seed random gaps and stalls; not architectural)", ""]
    out.append("| Variant | Workload | Cycles |")
    out.append("|---|---|---|")
    for sim, v in summary["variants"].items():
        for name in ("bench_ad0_msg1024_enc", "bench_ad0_msg1024_dec", "bench_ad16_msg4096_enc"):
            m = v["cycles"]["stalled"]["workloads"].get(name)
            if m:
                out.append(f"| {sim} | {name.removeprefix('bench_')} | {m['cmd_to_done']} |")
    out += ["", "## Worst path per category at the passing period (default strategy)", ""]
    for sim, v in summary["variants"].items():
        t = v["timing"].get("default")
        if not t or not t.get("categories"):
            continue
        out.append(f"### {sim} at {t['best_pass_period_ns']} ns")
        out.append("")
        out.append("| Category | Slack ns | Levels | Logic ns | Route ns | Skew ns | Max net pins | Endpoints |")
        out.append("|---|---|---|---|---|---|---|---|")
        for k, c in sorted(t["categories"].items(), key=lambda kv: kv[1]["slack"]):
            out.append(f"| {k} | {c['slack']:.3f} | {c['levels']} | {c['logic_ns']:.3f} | {c['route_ns']:.3f} | "
                       f"{c['skew_ns']:.3f} | {c['max_net_pins']} | `{c['start']}` → `{c['end']}` |")
        out.append("")
    return "\n".join(out) + "\n"


if __name__ == "__main__":
    main()
