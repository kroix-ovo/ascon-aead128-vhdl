#!/usr/bin/env bash
# Run every variant through scripts/run_sim.sh (inside WSL/Linux with GHDL).
set -u
cd "$(dirname "$0")/.."
status=0
scripts/run_sim.sh A ../../rtl 1 || status=1
scripts/run_sim.sh A_ctrl1 rtl/A_ctrl1 1 || status=1
scripts/run_sim.sh A_ctrl2 rtl/A_ctrl2 1 || status=1
scripts/run_sim.sh B_2stage rtl/B_2stage 2 || status=1
scripts/run_sim.sh D rtl/D 2 || status=1
scripts/run_sim.sh D_alt_3stage rtl/D_alt_3stage 3 || status=1
scripts/run_sim.sh C_3stage rtl/C_3stage 3 || status=1
exit $status
