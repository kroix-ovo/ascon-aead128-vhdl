#!/usr/bin/env python3
"""Run the cocotb permutation test directly against VHDL."""

import os
import argparse
import sys
from pathlib import Path

from cocotb_tools.runner import get_runner
from check_sim_results import require_passing_results

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rounds-per-cycle", type=int, choices=range(1, 13), default=1)
    args = parser.parse_args()
    verification_path = os.pathsep.join(
        [str(ROOT / "verification" / "cocotb"), str(ROOT / "verification" / "model")]
    )
    os.environ["PYTHONPATH"] = verification_path
    sys.path[:0] = [str(ROOT / "verification" / "cocotb"), str(ROOT / "verification" / "model")]
    runner = get_runner("ghdl")
    build_dir = ROOT / "build" / f"cocotb-permutation-u{args.rounds_per_cycle}"
    runner.build(
        sources=[ROOT / "rtl" / "ascon_pkg.vhd", ROOT / "rtl" / "ascon_permutation.vhd"],
        hdl_library="work",
        hdl_toplevel="ascon_permutation",
        build_args=["--std=08"],
        build_dir=build_dir,
        clean=True,
    )
    results = runner.test(
        hdl_toplevel="ascon_permutation",
        hdl_toplevel_library="work",
        hdl_toplevel_lang="vhdl",
        test_module="test_permutation",
        parameters={"G_ROUNDS_PER_CYCLE": args.rounds_per_cycle},
        test_args=["--std=08"],
        build_dir=build_dir,
        test_dir=build_dir,
        extra_env={"PYTHONPATH": verification_path, "ROUNDS_PER_CYCLE": str(args.rounds_per_cycle)},
    )

    require_passing_results(results)


if __name__ == "__main__":
    main()
