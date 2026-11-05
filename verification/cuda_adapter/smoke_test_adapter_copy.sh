#!/usr/bin/env bash
# Run a forward-only check with the existing checkpoint; this does not train.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
base=/home/kroix/projects/SAGE_Accelerator/llmc-gpt2
out=build/test_adapter_copy
"$out/test_adapter_copy" \
  -e "$base/gpt2_124M.bin" \
  -i "$base/dev/data/tinyshakespeare/tiny_shakespeare_train.bin" \
  -j "$base/dev/data/tinyshakespeare/tiny_shakespeare_val.bin" \
  -Ar 1 -Ad 32 -Af 1 -b 1 -t 64 -x 0 -m 1 -s 0 -r 0 -f 0 \
  2>&1 | tee "$out/adapter-forward.log"
