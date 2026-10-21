#!/usr/bin/env bash
# usage: run_batch.sh <sample:1KiB|full> <payload:adapter|llama> <nonce_base> <variant>...
# Runs variants in parallel; nonce = nonce_base + index (distinct per message). Public fixed test key.
set -uo pipefail
S=$HOME/ascon_fold_scratch
sample=$1; payload=$2; base=$3; shift 3
case $payload in
  adapter) W=/home/kroix/projects/SAGE_Adapter_Experiment/llmc-gpt2/runs/adapter_fp32_200/export/adapter_weights.bin ;;
  llama) W=$HOME/ascon_handoff_scratch/data/trained_weights_fp32.bin ;;
esac
export PYTHONDONTWRITEBYTECODE=1
i=0; pids=()
for v in "$@"; do
  out=$S/runs/${payload}_${sample}/$v
  rm -rf "$out"; mkdir -p "$(dirname "$out")"
  ( python3 "$S/wt/scripts/run_weight_case.py" "$v" "$W" "$sample" $((base+i)) "$out" ${KEEP:-} > "$out.stdout" 2>&1; echo "exit=$?" >> "$out.stdout" ) &
  pids+=($!); i=$((i+1))
done
for p in "${pids[@]}"; do wait $p; done
for v in "$@"; do echo "== $v"; tail -2 "$S/runs/${payload}_${sample}/$v.stdout"; done
