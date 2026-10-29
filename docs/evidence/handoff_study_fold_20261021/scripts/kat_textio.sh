#!/usr/bin/env bash
# Official KAT TextIO bench (1,089 vectors, 2,178 checks) per configuration.
# usage: kat_textio.sh <name> <rpc> <buffered> <folded> [in_depth out_depth]
set -uo pipefail
S=$HOME/ascon_fold_scratch
name=$1; rpc=$2; buf=$3; fold=$4
d=$S/runs/kat_textio/$name
rm -rf "$d"; mkdir -p "$d/work"
cd "$S/wt"
ghdl -a --std=08 --workdir="$d/work" rtl/ascon_pkg.vhd rtl/ascon_permutation.vhd rtl/ascon_aead128_core.vhd verification/vhdl/tb_ascon_aead128.vhd
cd "$d"
ghdl --elab-run --std=08 --workdir=work tb_ascon_aead128 -gG_VECTOR_FILE="$S/wt/verification/vectors/xsim_vectors.txt" \
  -gG_ROUNDS_PER_CYCLE=$rpc -gG_BUFFERING_ENABLE=$buf -gG_FOLDED_ABSORB=$fold --assert-level=error > ghdl.log 2>&1
echo "$name exit=$?"
tail -1 simulation_results.txt
