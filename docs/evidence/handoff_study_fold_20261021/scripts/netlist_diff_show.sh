#!/usr/bin/env bash
# Compare HEAD vs modified GHDL-synth netlists ignoring only the "/*# file:line:col */" source-location comments.
O=$HOME/ascon_fold_scratch/netlist_identity
strip() { sed -E 's#/\*\# [^*]*\*/##g' "$1"; }
for c in u1 u3 u3-buffered u3-buffered-d11; do
  n=$(diff <(strip "$O/head_$c.v") <(strip "$O/new_$c.v") | grep -c '^[<>]')
  echo "$c: differing lines after removing source-location comments: $n; raw differing lines are all of the form /*# ascon_aead128_core.vhd:LINE:COL */ : $(diff "$O/head_$c.v" "$O/new_$c.v" | grep '^[<>]' | grep -vc '/\*# ascon_aead128_core.vhd:[0-9]*:[0-9]* \*/$') non-comment lines"
done
