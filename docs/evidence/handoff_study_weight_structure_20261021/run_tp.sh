#!/bin/bash
# Third-party codec checks (read-only on the artifact). venv: numpy zstandard lz4 brotli blosc2 fpzip zipnn==0.1.1;
# venv054: zipnn 0.5.4 built from sdist with --no-deps (torch/safetensors stubbed in third_party.py; byte mode only).
S=~/ascon_weight_structure_scratch
E=/home/kroix/projects/SAGE_Adapter_Experiment/llmc-gpt2/runs/adapter_fp32_200/export
mkdir -p $S/third_party
$S/venv054/bin/python -I $S/third_party.py $E/adapter_weights.bin $E/manifest.json $S/third_party/zipnn054b.json zipnn
$S/venv/bin/python -I $S/third_party.py $E/adapter_weights.bin $E/manifest.json $S/third_party/zipnn011b.json zipnn
$S/venv/bin/python -I $S/third_party.py $E/adapter_weights.bin $E/manifest.json $S/third_party/fpzip.json fpzip
$S/venv/bin/python -I $S/third_party.py $E/adapter_weights.bin $E/manifest.json $S/third_party/blosc2.json blosc2
sha256sum $E/adapter_weights.bin
