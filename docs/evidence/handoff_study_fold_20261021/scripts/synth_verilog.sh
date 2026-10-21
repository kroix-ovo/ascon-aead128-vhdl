#!/usr/bin/env bash
# Translate the core to Verilog with GHDL synth (default, buffered, fold), as CI does.
# usage: synth_verilog.sh <ghdl-binary>
set -uo pipefail
G=${1:-ghdl}
S=$HOME/ascon_fold_scratch
O=$S/generated; rm -rf "$O"; mkdir -p "$O"
cd "$S/wt"
$G --version | head -1
SRC="rtl/ascon_pkg.vhd rtl/ascon_permutation.vhd rtl/ascon_aead128_core.vhd"
$G synth --std=08 --out=verilog $SRC -e ascon_aead128_core > "$O/default.v" 2> "$O/default.err"; echo "default rc=$? lines=$(wc -l < $O/default.v)"
$G synth --std=08 --out=verilog -gG_ROUNDS_PER_CYCLE=3 -gG_BUFFERING_ENABLE=true $SRC -e ascon_aead128_core > "$O/buffered.v" 2> "$O/buffered.err"; echo "buffered rc=$? lines=$(wc -l < $O/buffered.v)"
$G synth --std=08 --out=verilog -gG_ROUNDS_PER_CYCLE=3 -gG_BUFFERING_ENABLE=true -gG_FOLDED_ABSORB=true $SRC -e ascon_aead128_core > "$O/fold.v" 2> "$O/fold.err"; echo "fold rc=$? lines=$(wc -l < $O/fold.v)"
head -5 "$O"/*.err
