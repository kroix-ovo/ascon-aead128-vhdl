#!/usr/bin/env bash
# Board self-test and demo in GHDL with the committed board generics (no fold).
set -euo pipefail
WT=/mnt/c/Users/Symok/Downloads/ascon-aead128-vhdl-main/worktrees/ascon-weight-stream-handoff
S=$HOME/ascon_fold_scratch/board_tagfix; rm -rf "$S"; mkdir -p "$S/rtl"
for f in "$WT"/rtl/*.vhd; do sed 's/\r$//' "$f" > "$S/rtl/$(basename "$f")"; done
cd "$S"
ghdl -a --std=08 rtl/ascon_pkg.vhd rtl/ascon_permutation.vhd rtl/ascon_aead128_core.vhd rtl/ascon_selftest_vectors.vhd rtl/ascon_weight_selftest.vhd rtl/ascon_demo_top.vhd rtl/ascon_demo_autotest.vhd \
  $HOME/ascon_fold_scratch/wt/verification/vhdl/tb_weight_selftest.vhd $HOME/ascon_fold_scratch/wt/verification/vhdl/tb_weight_demo.vhd
echo "--- tb_weight_selftest"; ghdl --elab-run --std=08 tb_weight_selftest --assert-level=error 2>&1 | tail -3; echo "rc=${PIPESTATUS[0]}"
echo "--- tb_weight_demo"; ghdl --elab-run --std=08 tb_weight_demo --assert-level=error 2>&1 | tail -3; echo "rc=${PIPESTATUS[0]}"
