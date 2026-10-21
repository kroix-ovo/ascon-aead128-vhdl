#!/usr/bin/env python3
"""Build and run the shared cocotb suite with a selected simulator."""

import argparse
import os
import sys
from pathlib import Path

from cocotb_tools.runner import get_runner
from check_sim_results import require_passing_results

ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sim", choices=("ghdl", "icarus", "verilator"), default="ghdl")
    parser.add_argument("--rounds-per-cycle", type=int, default=1)
    parser.add_argument("--buffering", action="store_true")
    parser.add_argument("--input-depth", type=int, default=2)
    parser.add_argument("--output-depth", type=int, default=2)
    parser.add_argument("--fast-path", action="store_true")
    parser.add_argument("--folded", action="store_true",
                        help="G_FOLDED_ABSORB (requires --rounds-per-cycle 3 --buffering)")
    parser.add_argument("--module", default="test_ascon")
    parser.add_argument("--netlist", type=Path)
    parser.add_argument("--waves", action="store_true")
    args = parser.parse_args()

    verification_path = os.pathsep.join(
        [
            str(ROOT / "verification" / "cocotb"),
            str(ROOT / "verification" / "model"),
            os.environ.get("PYTHONPATH", ""),
        ]
    )
    os.environ["PYTHONPATH"] = verification_path
    sys.path.insert(0, str(ROOT / "verification" / "model"))
    sys.path.insert(0, str(ROOT / "verification" / "cocotb"))

    runner = get_runner(args.sim)
    build_dir = ROOT / "build" / f"cocotb-{args.sim}"

    if args.sim == "ghdl":
        sources = [
            ROOT / "rtl" / "ascon_pkg.vhd",
            ROOT / "rtl" / "ascon_permutation.vhd",
            ROOT / "rtl" / "ascon_aead128_core.vhd",
        ]
        runner.build(
            sources=sources,
            hdl_library="work",
            hdl_toplevel="ascon_aead128_core",
            build_args=["--std=08"],
            build_dir=build_dir,
            clean=True,
            waves=args.waves,
        )
        library = "work"
        language = "vhdl"
        test_args = ["--std=08"]
    else:
        if args.netlist is None:
            parser.error("--netlist is required for Icarus and Verilator")
        build_args = ["-CFLAGS", "-std=c++17"] if args.sim == "verilator" else []
        runner.build(
            sources=[args.netlist.resolve()],
            hdl_toplevel="ascon_aead128_core",
            build_dir=build_dir,
            clean=True,
            build_args=build_args,
            timescale=("1ns", "1ps"),
            waves=args.waves,
        )
        library = "top"
        language = "verilog"
        test_args = []

    results = runner.test(
        hdl_toplevel="ascon_aead128_core",
        hdl_toplevel_library=library,
        hdl_toplevel_lang=language,
        test_module=args.module,
        parameters={"G_ROUNDS_PER_CYCLE": args.rounds_per_cycle, "G_BUFFERING_ENABLE": args.buffering, "G_INPUT_FIFO_DEPTH": args.input_depth, "G_OUTPUT_FIFO_DEPTH": args.output_depth, "G_FULL_BLOCK_FAST_PATH": args.fast_path, "G_FOLDED_ABSORB": args.folded} if args.sim == "ghdl" else {},
        test_args=test_args,
        build_dir=build_dir,
        test_dir=build_dir,
        extra_env={"PYTHONPATH": verification_path, "BUFFERING": str(int(args.buffering)), "ROUNDS_PER_CYCLE": str(args.rounds_per_cycle), "FOLDED": str(int(args.folded))},
        waves=args.waves,
    )
    require_passing_results(results)


if __name__ == "__main__":
    main()
