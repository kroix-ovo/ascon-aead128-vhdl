#!/usr/bin/env python3
"""Record source commit, file hashes, and tool versions for the experiment."""

import hashlib
import json
import platform
import subprocess
from pathlib import Path

EXP = Path(__file__).resolve().parents[1]
REPO = EXP.parents[1]


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(cmd, **kw):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, check=False, **kw).stdout.strip()
    except OSError as exc:
        return f"unavailable: {exc}"


def main():
    files = sorted(
        [REPO / "rtl" / n for n in ("ascon_pkg.vhd", "ascon_permutation.vhd", "ascon_aead128_core.vhd")]
        + [REPO / "verification" / "vhdl" / "tb_ascon_aead128.vhd", REPO / "verification" / "model" / "ascon_ref.py"]
        + list((EXP / "rtl").rglob("*.vhd")) + list((EXP / "tb").glob("*.vhd"))
        + list((EXP / "bench").glob("*")) + list((EXP / "scripts").glob("*"))
    )
    # Every run log starts with the exact Vivado version and build.
    vivado_version = "unknown"
    for log in sorted((EXP / "results" / "runs").rglob("vivado.log")):
        header = [l.strip("# \n") for l in log.read_text(errors="replace").splitlines()[:6]]
        vivado_version = " | ".join(l for l in header if l.startswith(("Vivado v", "SW Build", "IP Build")))
        break
    record = {
        "base_commit": run(["git", "-C", str(REPO), "rev-parse", "HEAD"]),
        "branch": run(["git", "-C", str(REPO), "rev-parse", "--abbrev-ref", "HEAD"]),
        "baseline_rtl_unmodified": run(["git", "-C", str(REPO), "status", "--porcelain", "rtl"]) == "",
        "kat_source": "ascon-c 446347f21b209f3921c65ece70027c366cbe1693 LWC_AEAD_KAT_128_128.txt "
                      "sha256 bbbc34692fe05e5fda0a3b025585622ab3e3747495e5e3655b29aae8c2a4bd33",
        "files": {str(p.relative_to(REPO)).replace("\\", "/"): sha256(p) for p in files if p.is_file()},
        "tools": {
            "vivado": vivado_version,
            "ghdl": run(["wsl", "-d", "Ubuntu-22.04", "--", "ghdl", "--version"]).splitlines()[0],
            "python": platform.python_version(),
            "host": platform.platform(),
        },
        "fpga_part": "xc7a100tcsg324-1",
        "constraints": "bench/ascon_bench_pins.xdc + per-run create_clock on CLK100MHZ (E3); no timing exceptions",
        "implementation": {
            "flow": "non-project: synth_design, opt_design, place_design, [phys_opt_design], route_design, [phys_opt_design]",
            "strategies": {
                "default": "synth default; place/route Default; no phys_opt",
                "retime": "synth -retiming; otherwise default",
                "explore": "synth -directive PerformanceOptimized; place ExtraTimingOpt; phys_opt AggressiveExplore (post-place and post-route); route AggressiveExplore",
                "explore_retime": "explore plus synth -retiming",
            },
            "pass_rule": "WNS>=0, WHS>=0, WPWS>=0, zero routing errors, zero DRC errors",
            "search": "0.5 ns bracket, then 0.1 ns, then 0.05 ns (declared resolution)",
        },
    }
    out = EXP / "results" / "provenance.json"
    out.write_text(json.dumps(record, indent=2))
    print(json.dumps(record["tools"], indent=2), record["base_commit"], record["baseline_rtl_unmodified"])


if __name__ == "__main__":
    main()
