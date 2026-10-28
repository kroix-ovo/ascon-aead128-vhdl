#!/usr/bin/env bash
# Run inside WSL/Linux. Never train or download weights. Every encryption range
# and output directory must be fresh; the Python runner validates both inputs.
set -euo pipefail
if (( $# < 3 )); then
  echo "Usage: bash verification/benchmark_multicore.sh EXPORT_DIR NONCE_BASE FRESH_OUTPUT [runner options]" >&2
  exit 2
fi
export_dir="$1"
nonce_base="$2"
output_dir="$3"
shift 3
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
backend=()
synth_ghdl="${ASCON_SYNTH_GHDL:-$HOME/tools/oss-cad-suite/bin/ghdl}"
if command -v verilator >/dev/null && [[ -x "$synth_ghdl" ]]; then
  backend=(--sim verilator --synth-ghdl "$synth_ghdl")
fi
checkpoint=()
candidate="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["checkpoint"])' "$export_dir/manifest.json")"
if [[ ! -f "$candidate" ]]; then candidate="$export_dir/../$(basename "$candidate")"; fi
if [[ -f "$candidate" ]]; then checkpoint=(--checkpoint "$candidate"); fi
exec python3 "$root/verification/run_multicore.py" \
  --weights "$export_dir/adapter_weights.bin" --manifest "$export_dir/manifest.json" \
  --nonce-base "$nonce_base" --output "$output_dir" \
  "${checkpoint[@]}" "${backend[@]}" "$@"
