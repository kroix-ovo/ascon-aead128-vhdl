# Simulate encryption and decryption of the trained small LLaMA weights

`simulate_weight_file.py` runs both directions through the existing Ascon-AEAD128
RTL in Vivado XSim. `vhdl/tb_weight_file.vhd` is its streaming testbench. It reads
one block per line so the entire weight file can be tested without allocating a
large VHDL array or parsing a multi-megabyte text line.

The trained payload is `build/small_llama_20261013_01/trained_weights_fp32.bin`:
1,641,984 bytes containing all 410,496 FP32 parameters, with no checkpoint header.
Tensor names, shapes and byte offsets are in the training run's
`tensor_manifest.json`. Encryption preserves these bytes exactly; it does not
convert, quantize, or retrain weights.

## Run the simulation from Windows PowerShell

```powershell
Set-Location -LiteralPath 'C:\Users\Symok\Downloads\ascon-aead128-vhdl-main'
python .\verification\simulate_weight_file.py .\build\small_llama_20261013_01\trained_weights_fp32.bin --output .\build\small_llama_encryption_02
```

Choose a fresh output directory for each run. The runner refuses to overwrite
existing evidence. Vivado defaults to
`C:\Xilinx\Vivado\2023.2\bin\vivado.bat`; use `--vivado` to select another
installed path. Python uses the standard library and the repository's reference
model; no additional Python packages are required for this runner.

The runner first validates the Python oracle against 1,089 official vectors,
then calculates the expected ciphertext and tag. XSim checks every output block,
the encryption tag, and successful decryption authentication/commit. The runner
compares the complete dumped outputs again before saving final binary files.

## Verify that recovered weights reproduce the model

Run this after simulation, using the existing WSL training environment:

```powershell
wsl -d Ubuntu-22.04 -- bash -lc 'cd /home/kroix/projects/SAGE_Accelerator/llmc-gpt2 && .venv/bin/python /mnt/c/Users/Symok/Downloads/ascon-aead128-vhdl-main/verification/verify_small_llama_files.py --training-root /home/kroix/projects/SAGE_Accelerator/llmc-gpt2 --run /mnt/c/Users/Symok/Downloads/ascon-aead128-vhdl-main/build/small_llama_20261013_01 --weights /mnt/c/Users/Symok/Downloads/ascon-aead128-vhdl-main/build/small_llama_encryption_02/recovered_weights.bin'
```

This checks the recovered file's hash, every tensor against the trained
checkpoint, and prediction scores/loss from two freshly loaded CPU models on
128 validation characters. It writes `recovered_model_verification.json` beside
the recovered weights. This is a fixed-input model check, in addition to the
complete byte/parameter comparison.

## Outputs and timing interpretation

- `report.md` and `report.json`: verified timing and correctness results.
- `ciphertext.bin` and `tag.bin`: RTL encryption output.
- `recovered_weights.bin`: RTL decryption output, accepted after authentication.
- `simulation_results.txt`: raw cycle counts from the testbench.
- `vivado_console.log`: compiler/simulator logs and block progress.
- `inputs.json`: source hashes, input hash, demo key/nonce and oracle timings.

Both directions process the entire file as one AEAD message, with empty
associated data, one round per clock, and a 10 ns clock period (100 MHz).
The timer starts when the command is offered and ends when `done` is observed.
It includes empty AD handling, input/output handshakes, final padding and tag
processing. It excludes host file transfers and Vivado runtime.

For each direction:

```text
simulated seconds = cycles / 100,000,000
simulated milliseconds = cycles / 100,000
payload Mb/s = payload_bytes * 8 / simulated_seconds / 1,000,000
```

These are behavioral RTL simulation timings. The assumed clock is not an
achieved FPGA clock or physical-board measurement. Python-reference execution
time and total Vivado wall time are recorded separately and should not be used
as RTL latency. The Python timing is a single execution of a readable reference,
not an optimized software benchmark.

The fixed public key and nonce are simulation inputs. Real encrypted storage
requires a protected key and a unique nonce for each message under that key.
Decryption outputs must not be consumed until authentication succeeds.

The testbench currently accepts full 16-byte blocks and the runner requires a
payload of at least 32 bytes. The complete trained weight file meets this rule.

## Recorded results and portable CI

The completed October 13, 2026 run is preserved in
`paper/evidence/small_llama_encryption_01/`. Both directions took 1,231,521
cycles for the 1,641,984-byte payload. That is 12.31521 ms and approximately
1,066.638 Mb/s at the assumed 100 MHz clock. All bytes recovered exactly,
and the saved CPU model check matched the trained checkpoint's tensors,
logits and loss. The example output directory `_02` above is for a fresh run;
the completed historical receipt is `_01`.

`paper/evidence/small_llama_20261013_01/` contains training metrics and the
tensor manifest, without trained binary files. To reproduce training, use
`verification/train_small_llama.py --training-root <llmc-gpt2> --output <fresh-directory>`
in the external training environment. This runs the small configuration for
500 steps by default; it requires CUDA. It does not encrypt the result.

CI runs `make weight-file-test` with synthetic 32-byte and 1,024-byte FP32
fixtures through the same streaming file bench. It checks the interface and
byte recovery without a checkpoint or Vivado license. This is distinct from
the historical full-model run and does not validate model training.
