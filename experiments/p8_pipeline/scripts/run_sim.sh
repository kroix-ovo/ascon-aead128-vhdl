#!/usr/bin/env bash
# Functional verification of one variant with GHDL (run inside WSL/Linux).
#   scripts/run_sim.sh NAME RTL_DIR CLOCKS_PER_ROUND
# Runs: official 2,178-check KAT bench, per-round permutation bench, and the
# streaming-protocol bench unstalled and stalled.  Logs go to
# results/sim/NAME/; any failure exits non-zero and the logs are kept.
set -euo pipefail
name=$1; rtl=$(realpath "$2"); cpr=$3
exp=$(cd "$(dirname "$0")/.." && pwd)
repo=$(cd "$exp/../.." && pwd)
out="$exp/results/sim/$name"
vec="$exp/build_vectors"
rm -rf "$out"; mkdir -p "$out"; cd "$out"
python3 "$exp/scripts/gen_vectors.py" --out "$vec" > /dev/null
ghdl -a --std=08 "$repo/rtl/ascon_pkg.vhd" "$rtl/ascon_permutation.vhd" "$rtl/ascon_aead128_core.vhd" \
  "$repo/verification/vhdl/tb_ascon_aead128.vhd" "$exp/tb/tb_perm_rounds.vhd" "$exp/tb/tb_core_pipeline.vhd"
status=0
ghdl --elab-run --std=08 tb_ascon_aead128 -gG_VECTOR_FILE="$repo/verification/vectors/xsim_vectors.txt" \
  --assert-level=error > kat.log 2>&1 || status=1
ghdl --elab-run --std=08 tb_perm_rounds -gG_VECTOR_FILE="$vec/perm_vectors.txt" \
  -gG_RESULT_FILE=perm_results.txt -gG_CLOCKS_PER_ROUND="$cpr" --assert-level=error > perm.log 2>&1 || status=1
ghdl --elab-run --std=08 tb_core_pipeline -gG_VECTOR_FILE="$vec/core_vectors.txt" \
  -gG_RESULT_FILE=core_unstalled.txt -gG_STALL=false --assert-level=error > core_unstalled.log 2>&1 || status=1
ghdl --elab-run --std=08 tb_core_pipeline -gG_VECTOR_FILE="$vec/core_vectors.txt" \
  -gG_RESULT_FILE=core_stalled.txt -gG_STALL=true --assert-level=error > core_stalled.log 2>&1 || status=1
echo "== $name"
tail -n1 simulation_results.txt perm_results.txt core_unstalled.txt core_stalled.txt 2>/dev/null | grep TOTAL || true
exit $status
