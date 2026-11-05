#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
cuda=/usr/local/cuda-12.8
out=build/test_adapter_copy
mkdir -p "$out"
"$cuda/bin/nvcc" --threads=2 --use_fast_math -std=c++17 -O3 \
  -gencode arch=compute_86,code=sm_86 -DENABLE_FP32 \
  test_adapter_copy.cu -L"$cuda/lib64" -L/usr/lib/wsl/lib \
  -Xlinker -rpath -Xlinker "$cuda/lib64" \
  -lcublas -lcublasLt -lnvidia-ml \
  -o "$out/test_adapter_copy" 2>&1 | tee "$out/build.log"
sha256sum test_adapter_copy.cu "$out/test_adapter_copy" > "$out/build.sha256"
printf '\nBuilt: %s/%s/test_adapter_copy\n' "$PWD" "$out"
