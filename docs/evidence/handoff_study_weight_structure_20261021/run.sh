#!/bin/bash
set -eu
S=~/ascon_weight_structure_scratch
R=/home/kroix/projects/SAGE_Adapter_Experiment/llmc-gpt2/runs/adapter_fp32_200
D=/mnt/c/Users/Symok/Downloads/ascon-aead128-vhdl-main/worktrees/ascon-weight-stream-handoff/build/weight_structure
cp "$D/analyze.py" "$S/analyze.py"
cd "$S"
OUT=$S/results_${1:-full}_$(date +%H%M%S)
venv/bin/python -I "$S/analyze.py" "$R/export/adapter_weights.bin" "$R/export/manifest.json" "$R/adapter_params_00000200.bin" --initial "$R/adapter_initial.bin" --out "$OUT" ${2:-}
sha256sum "$R/export/adapter_weights.bin" "$R/adapter_params_00000200.bin"
echo "$OUT"
