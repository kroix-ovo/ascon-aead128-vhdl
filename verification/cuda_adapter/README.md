# Commented native CUDA adapter experiment

`test_adapter_copy.cu` is the teaching copy of SAGE's native GPT-2 adapter trainer.
Its opening comment explains the parallel adapter architecture, dimensions,
initialization, loss and training flow. Local comments explain operations in
plain language. Console reports include completed step numbers, raw loss and
loss as a percentage of the first measured loss of the same type.

The native 200-step run completed, but validation loss worsened from **5.325532**
to **12.772885**, or **239.84%** of its starting value. This is an execution record,
not a validated adapter-training result. The inherited optimizer-state and
backward-gradient defects are marked in the source and described in
[the teaching-copy notes](TEST_ADAPTER_COPY.md).

## Full terminal session

- [Complete 718-line session, with the exact WSL launch command](evidence/2026-11-05/terminal-transcript.md)
- [Unedited plain-text capture](evidence/2026-11-05/terminal-transcript.txt)
- [Actual script used for that run](evidence/2026-11-05/run_test_adapter_copy_training.sh)
- [Run summary and checkpoint hashes](evidence/2026-11-05/run-summary.json)

The run used CUDA 12.8, FP32, an RTX 3080 Laptop GPU, batch size 1, sequence
length 64, adapter rank 32, frozen base weights and 200 steps. The FP32 master
copy was disabled with `-w 0`. Validation measured 20 batches every 20 steps.
All 599,424 saved adapter values were finite. The saved base checkpoint was
byte-for-byte identical to the original base checkpoint. Existing validated
PyTorch results were left untouched.

## Build

The local `llmc/` headers are included, with their original MIT license in
[LICENSE.llmc](LICENSE.llmc). The matrix-multiply header includes the two
`std::bool_constant` compatibility fixes needed by this build.

On WSL with CUDA 12.8 and the required development headers installed:

```bash
cd verification/cuda_adapter
bash build_test_adapter_copy.sh
```

The output is `build/test_adapter_copy/test_adapter_copy`. The build targets
FP32 and `sm_86`, matching the measured RTX 3080 Laptop environment. Its library
paths assume `/usr/local/cuda-12.8` and `/usr/lib/wsl/lib`.

The forward-check helper expects the existing SAGE data checkout at
`/home/kroix/projects/SAGE_Accelerator/llmc-gpt2`; edit that data path for another
machine. The archived training script preserves the original absolute paths
so the transcript remains reproducible as recorded. Its first source/binary
hash check relies on the original local `build.sha256`, preserved in evidence.
Checkpoint binaries, datasets, executables and optimizer state are not bundled.

## Source and evidence provenance

The source derives from
[SPIRE-GMU/SAGE_Accelerator](https://github.com/SPIRE-GMU/SAGE_Accelerator/tree/b61ecf7ac8a1b4582abc4d0d8f3d5247e6b55262/llmc-gpt2)
at commit `b61ecf7ac8a1b4582abc4d0d8f3d5247e6b55262`. It was copied and annotated
locally, with reporting changes. This publication snapshots the exact source
used for the recorded run, the dependency headers, build/check helpers and
terminal evidence. It does not include unrelated Ascon RTL changes.

Additional evidence includes the successful adapter-enabled forward check,
two-step base-only reporting check, reporting edge-case checks and build output.
The base-only check exercises reporting; it does not validate adapter gradients.
See [manifest.json](manifest.json) for SHA-256 hashes of the published files.
