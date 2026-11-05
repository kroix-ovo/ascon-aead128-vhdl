#!/usr/bin/env bash
set -euo pipefail
cd /home/kroix/projects/SAGE_Adapter_Experiment/llmc-gpt2
run=$(mktemp -d "$PWD/runs/test_adapter_copy_20261105_XXXXXX")
exec > >(tee "$run/terminal-transcript.txt") 2>&1
printf 'Windows command invoked:\nwsl -d Ubuntu-22.04 -- bash /home/kroix/projects/SAGE_Adapter_Experiment/llmc-gpt2/run_test_adapter_copy_training.sh\n\n'
printf 'Run directory: %s\n' "$run"
printf 'FP32 run: rank-32 adapters enabled, base weights frozen, 200 steps.\n'
printf 'FP32 master copy disabled (-w 0); native adapter defects remain.\n'
sha256sum -c build/test_adapter_copy/build.sha256
cp test_adapter_copy.cu "$run/test_adapter_copy.cu"
cp build/test_adapter_copy/test_adapter_copy "$run/test_adapter_copy"
base=/home/kroix/projects/SAGE_Accelerator/llmc-gpt2
command=(stdbuf -oL -eL "$run/test_adapter_copy"
  -e "$base/gpt2_124M.bin"
  -i "$base/dev/data/tinyshakespeare/tiny_shakespeare_train.bin"
  -j "$base/dev/data/tinyshakespeare/tiny_shakespeare_val.bin"
  -o "$run/checkpoints" -n 200
  -Ar 1 -Ad 32 -Af 1 -b 1 -t 64 -x 200 -v 20 -m 20 -s 0 -r 0 -f 0 -w 0)
printf '\nExecuted training command:\n'
printf '%q ' "${command[@]}"
printf '\n\n'
if "${command[@]}"; then
    status=0
else
    status=$?
fi
printf '\nTrainer exit status: %d\n' "$status"
printf 'Run directory: %s\n' "$run"
printf '%s\n' "$status" > "$run/exit-status.txt"
exit "$status"
