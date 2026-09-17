#!/usr/bin/env python3
"""Build and run the shared cocotb suite with a selected simulator."""

import argparse
import os
import sys
from pathlib import Path

from cocotb_tools.runner import get_runner

ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sim", choices=("ghdl", "icarus", "verilator"), default="ghdl")
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

    runner.test(
        hdl_toplevel="ascon_aead128_core",
        hdl_toplevel_library=library,
        hdl_toplevel_lang=language,
        test_module="test_ascon",
        build_dir=build_dir,
        test_dir=build_dir,
        extra_env={"PYTHONPATH": verification_path},
        waves=args.waves,
    )


if __name__ == "__main__":
    main()
