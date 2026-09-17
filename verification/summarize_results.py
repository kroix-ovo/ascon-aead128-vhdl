#!/usr/bin/env python3
"""Summarize TextIO latency records and optional Vivado implementation data."""

from __future__ import annotations

import argparse
import json
import re
from collections import defaultdict
from pathlib import Path
from statistics import mean

ROOT = Path(__file__).resolve().parents[1]
CLOCK_HZ = 100_000_000


def parse_machine_records(path: Path) -> list[dict[str, str]]:
    records = []
    if not path.exists():
        return records
    for line in path.read_text(encoding="ascii").splitlines():
        if not line.startswith("CASE|"):
            continue
        fields = line.split("|")
        if len(fields) % 2:
            raise ValueError(f"malformed pipe record: {line[:80]}")
        record = {fields[index]: fields[index + 1] for index in range(0, len(fields), 2)}
        records.append(record)
    return records


def summarize_cycles(records: list[dict[str, str]]) -> dict:
    grouped: dict[tuple[str, int], list[int]] = defaultdict(list)
    for record in records:
        grouped[(record["MODE"], int(record["MSG_LEN"]))].append(int(record["CYCLES"]))

    summary = {"encryption": {}, "decryption": {}}
    for (mode, length), cycles in sorted(grouped.items()):
        mode_name = "encryption" if mode == "ENC" else "decryption"
        entry = {
            "samples": len(cycles),
            "minimum_cycles": min(cycles),
            "maximum_cycles": max(cycles),
            "mean_cycles": round(mean(cycles), 3),
        }
        if length:
            entry["mean_payload_throughput_mbps"] = round(
                length * 8 * CLOCK_HZ / mean(cycles) / 1_000_000, 3
            )
        summary[mode_name][str(length)] = entry
    return summary


def find_number(report: Path, labels: list[str]) -> float | None:
    if not report.exists():
        return None
    for line in report.read_text(errors="replace").splitlines():
        if any(label.lower() in line.lower() for label in labels):
            numbers = re.findall(r"(?<![A-Za-z])[-+]?\d+(?:\.\d+)?", line.replace(",", ""))
            if numbers:
                return float(numbers[0])
    return None


def vivado_metrics(report_dir: Path, artifact_dir: Path) -> dict:
    utilization = report_dir / "post_route_utilization.txt"
    power = report_dir / "post_route_power.txt"
    slack = report_dir / "setup_slack.txt"
    critical = report_dir / "critical_warnings.txt"

    wns = None
    if slack.exists():
        match = re.search(r"WNS_NS=([-+]?\d+(?:\.\d+)?)", slack.read_text())
        if match:
            wns = float(match.group(1))
    warnings = [line for line in critical.read_text(errors="replace").splitlines() if line.strip()] if critical.exists() else []
    data = {
        "part": "xc7a100tcsg324-1",
        "clock_mhz": 100.0,
        "slice_luts": find_number(utilization, ["Slice LUTs"]),
        "slice_registers": find_number(utilization, ["Slice Registers"]),
        "block_ram_tiles": find_number(utilization, ["Block RAM Tile"]),
        "wns_ns": wns,
        "total_on_chip_power_w": find_number(power, ["Total On-Chip Power"]),
        "critical_warning_count": len(warnings),
        "bitstream": str(artifact_dir / "ascon_demo_top.bit"),
    }
    data["complete"] = bool(
        (artifact_dir / "ascon_demo_top.bit").exists()
        and data["slice_luts"] is not None
        and data["slice_registers"] is not None
        and wns is not None
        and wns >= 0
        and critical.exists()
        and not warnings
    )
    return data


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--simulation-dir", type=Path, default=ROOT / "build" / "vivado" / "simulation"
    )
    parser.add_argument(
        "--report-dir", type=Path, default=ROOT / "build" / "vivado" / "reports"
    )
    parser.add_argument(
        "--artifact-dir", type=Path, default=ROOT / "build" / "vivado" / "artifacts"
    )
    parser.add_argument(
        "--output", type=Path, default=ROOT / "build" / "vivado" / "reports" / "metrics.json"
    )
    args = parser.parse_args()

    records = parse_machine_records(args.simulation_dir / "simulation_vectors.txt")
    passed = sum(record.get("RESULT") == "PASS" for record in records)
    case_numbers = {int(record["CASE"]) for record in records}
    simulation_complete = len(records) == 2178 and passed == 2178 and len(case_numbers) == 1089
    metrics = {
        "schema_version": 1,
        "clock_hz": CLOCK_HZ,
        "simulation": {
            "complete": simulation_complete,
            "official_vectors": len(case_numbers),
            "directional_checks": len(records),
            "passed": passed,
            "failed": len(records) - passed,
        },
        "latency_by_payload_bytes": summarize_cycles(records),
        "vivado": vivado_metrics(args.report_dir, args.artifact_dir),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(metrics, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {args.output}")
    print(
        f"simulation_complete={simulation_complete} "
        f"vivado_complete={metrics['vivado']['complete']}"
    )


if __name__ == "__main__":
    main()
