#!/usr/bin/env bash
# Structural identity check: GHDL-synth netlists of the default (R=1), u3 and u3-buffered
# configurations from HEAD 8b886c0 sources vs the modified worktree sources.
set -uo pipefail
S=$HOME/ascon_fold_scratch
G=/home/kroix/tools/oss-cad-suite/bin/ghdl
H=$S/head_src; rm -rf "$H"; mkdir -p "$H"
# HEAD sources (LF) were exported by the baseline study into build/handoff_sim/src_head.
for n in ascon_pkg.vhd ascon_permutation.vhd ascon_aead128_core.vhd; do
  sed 's/\r$//' /mnt/c/Users/Symok/Downloads/ascon-aead128-vhdl-main/worktrees/ascon-weight-stream-handoff/build/handoff_sim/src_head/$n > "$H/$n"
done
O=$S/netlist_identity; rm -rf "$O"; mkdir -p "$O"
for cfg in "u1 1 false" "u3 3 false" "u3-buffered 3 true" "u3-buffered-d11 3 true 1"; do
  set -- $cfg
  extra=""; [ "${4:-}" = "1" ] && extra="-gG_INPUT_FIFO_DEPTH=1 -gG_OUTPUT_FIFO_DEPTH=1"
  (cd "$H" && $G synth --std=08 --out=verilog -gG_ROUNDS_PER_CYCLE=$2 -gG_BUFFERING_ENABLE=$3 $extra ascon_pkg.vhd ascon_permutation.vhd ascon_aead128_core.vhd -e ascon_aead128_core > "$O/head_$1.v" 2>/dev/null)
  (cd "$S/wt/rtl" && $G synth --std=08 --out=verilog -gG_ROUNDS_PER_CYCLE=$2 -gG_BUFFERING_ENABLE=$3 $extra ascon_pkg.vhd ascon_permutation.vhd ascon_aead128_core.vhd -e ascon_aead128_core > "$O/new_$1.v" 2>/dev/null)
  if cmp -s "$O/head_$1.v" "$O/new_$1.v"; then r=IDENTICAL; else r="DIFFERENT ($(diff "$O/head_$1.v" "$O/new_$1.v" | grep -c '^[<>]') differing lines)"; fi
  echo "$1: HEAD vs modified GHDL-synth Verilog netlist: $r ($(wc -l < "$O/new_$1.v") lines, sha256 $(sha256sum < "$O/new_$1.v" | cut -c1-16))"
done
