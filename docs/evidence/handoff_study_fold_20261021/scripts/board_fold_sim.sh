#!/usr/bin/env bash
# Board self-test and demo in GHDL with G_FOLDED_ABSORB forced on in COPIES of the board RTL
# (build/handoff_fold/board/rtl); the committed board RTL is not modified.
set -euo pipefail
WT=/mnt/c/Users/Symok/Downloads/ascon-aead128-vhdl-main/worktrees/ascon-weight-stream-handoff
B=$WT/build/handoff_fold/board
rm -rf "$B/rtl"; mkdir -p "$B/rtl"
for f in "$WT"/rtl/*; do sed 's/\r$//' "$f" > "$B/rtl/$(basename "$f")"; done
sed -i 's/    generic map (G_ROUNDS_PER_CYCLE => 3, G_BUFFERING_ENABLE => true)/    generic map (G_ROUNDS_PER_CYCLE => 3, G_BUFFERING_ENABLE => true, G_FOLDED_ABSORB => true)/' "$B/rtl/ascon_weight_selftest.vhd"
sed -i 's/                 G_BUFFERING_ENABLE => G_BUFFERING_ENABLE)/                 G_BUFFERING_ENABLE => G_BUFFERING_ENABLE, G_FOLDED_ABSORB => true)/' "$B/rtl/ascon_demo_top.vhd"
grep -n "G_FOLDED_ABSORB => true" "$B/rtl/ascon_weight_selftest.vhd" "$B/rtl/ascon_demo_top.vhd"
S=$HOME/ascon_fold_scratch/board_fold; rm -rf "$S"; mkdir -p "$S"; cd "$S"
ghdl -a --std=08 "$B"/rtl/ascon_pkg.vhd "$B"/rtl/ascon_permutation.vhd "$B"/rtl/ascon_aead128_core.vhd "$B"/rtl/ascon_selftest_vectors.vhd "$B"/rtl/ascon_weight_selftest.vhd "$B"/rtl/ascon_demo_top.vhd "$B"/rtl/ascon_demo_autotest.vhd \
  /home/kroix/ascon_fold_scratch/wt/verification/vhdl/tb_weight_selftest.vhd /home/kroix/ascon_fold_scratch/wt/verification/vhdl/tb_weight_demo.vhd
ghdl --elab-run --std=08 tb_weight_selftest --assert-level=error 2>&1 | tail -2
ghdl --elab-run --std=08 tb_weight_demo --assert-level=error 2>&1 | tail -2
(cd "$B/rtl" && sha256sum *.vhd *.v) > "$B/rtl_sha256.txt"
