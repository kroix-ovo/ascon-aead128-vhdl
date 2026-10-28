#!/usr/bin/env bash
# Compile and run the timing harness in GHDL and report how many transactions
# it completes, to confirm the harness really exercises the core.
set -euo pipefail
exp=$(cd "$(dirname "$0")/.." && pwd)
repo=$(cd "$exp/../.." && pwd)
rtl=$(realpath "${1:-$repo/rtl}")
work=$(mktemp -d)
cd "$work"
ghdl -a --std=08 "$repo/rtl/ascon_pkg.vhd" "$rtl/ascon_permutation.vhd" "$rtl/ascon_aead128_core.vhd" \
  "$exp/bench/ascon_bench_top.vhd" "$exp/bench/tb_bench_top.vhd"
ghdl --elab-run --std=08 tb_bench_top --stop-time=1000100ns 2>&1 | grep -o "harness transactions=.*"
