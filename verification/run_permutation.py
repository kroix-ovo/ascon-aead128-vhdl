#!/usr/bin/env python3
"""Run the cocotb permutation test directly against VHDL."""

import os
import sys
from pathlib import Path

from cocotb_tools.runner import get_runner

ROOT = Path(__file__).resolve().parents[1]


def main():
    verification_path = os.pathsep.join(
        [str(ROOT / "verification" / "cocotb"), str(ROOT / "verification" / "model")]
    )
    os.environ["PYTHONPATH"] = verification_path
    sys.path[:0] = [str(ROOT / "verification" / "cocotb"), str(ROOT / "verification" / "model")]
    runner = get_runner("ghdl")
    build_dir = ROOT / "build" / "cocotb-permutation"
    runner.build(
        sources=[ROOT / "rtl" / "ascon_pkg.vhd", ROOT / "rtl" / "ascon_permutation.vhd"],
        hdl_library="work",
        hdl_toplevel="ascon_permutation",
        build_args=["--std=08"],
        build_dir=build_dir,
        clean=True,
    )
    runner.test(
        hdl_toplevel="ascon_permutation",
        hdl_toplevel_library="work",
        hdl_toplevel_lang="vhdl",
        test_module="test_permutation",
        build_dir=build_dir,
        test_dir=build_dir,
        extra_env={"PYTHONPATH": verification_path},
    )


if __name__ == "__main__":
    main()
