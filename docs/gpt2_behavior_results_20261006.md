# Ascon and GPT-2 behavior results

Test date: October 6, 2026. Both the Ascon RTL behavior tests and the GPT-2 inference comparison passed.

## Scope and method

The input was the same 1,024-byte trained GPT-2 weight sample used in the earlier experiment. It contains 256 FP32 values from token embedding row 0, starting immediately after the checkpoint's 1,024-byte header. The original trained checkpoint contains 497,904,640 bytes. Only this 1 KiB sample passed through the Ascon RTL; the entire checkpoint was not encrypted in RTL.

The Python Ascon oracle passed all 1,089 pinned official known-answer vectors before supplying expected results. Vivado 2023.2 XSim then exercised the existing RTL in an isolated project, at a simulated 100 MHz clock. Assertions checked all 64 payload blocks, valid encryption tags, authentication/commit/discard events, stalled output stability, and completion cleanup. The original RTL and earlier experiment files were left intact.

For the model comparison, the complete trained FP32 checkpoint was loaded twice using its actual serialized tensor order and padded vocabulary format. The second instance replaced the first 256 FP32 values with the newly recovered RTL bytes. Reserializing each loaded model reproduced the original checkpoint's SHA-256 exactly, and every model parameter matched. Inference ran in evaluation mode on the RTX 3080 Laptop GPU with deterministic PyTorch operations and TF32 disabled.

## Ascon behavior

All **17 checks across 12 scenarios passed**: five valid scenarios each tested encryption and decryption; seven tamper scenarios tested rejection during decryption.

| Scenario | Result | Command-to-done cycles |
|---|---|---:|
| Original sample, empty associated data | Exact ciphertext/tag and recovered weight bytes | 801 for encryption and decryption |
| Ciphertext bit flipped at byte 0, 512, or 1023 | All three rejected; auth=0, commit=0, discard=1 | 801 each |
| Tag bit flipped | Rejected; auth=0, commit=0, discard=1 | 801 |
| Wrong key or wrong nonce | Both rejected; auth=0, commit=0, discard=1 | 801 each |
| Valid transaction immediately after failed transactions | Correct encryption, recovery, and authentication | 801 each |
| Valid 16-byte associated data | Correct encryption, recovery, and authentication | 821 each |
| Associated-data bit flipped | Rejected; auth=0, commit=0, discard=1 | 821 |
| Three-cycle input gaps and output stalls, seven-cycle tag delay | Correct data, stable held outputs/tag, no early authentication | 1,003 each |
| Valid new nonce | Different ciphertext/tag, correct recovery and authentication | 801 each |

At the chosen 100 MHz simulation clock, 801 cycles is 8.01 microseconds, 821 cycles is 8.21 microseconds, and 1,003 cycles is 10.03 microseconds. The baseline payload throughput calculated from the command-to-done interval is 1,022.72 Mb/s. These values include the testbench handshakes; they are not measured physical FPGA or host-transfer performance. Similar valid/invalid-case latency in these tests does not establish resistance to timing or power side channels.

The core outputs provisional plaintext before tag verification. Every failed case asserted discard and withheld commit. A downstream model loader must quarantine the entire transaction until authentication succeeds; discard signals do not themselves undo writes to external memory. The testbench observed the signals but did not implement a production checkpoint loader.

## GPT-2 behavior

| Measurement | Original versus recovered slice |
|---|---|
| All loaded parameters and reconstructed full-checkpoint SHA-256 | Identical |
| Prompt logits: five text prompts plus an explicit token-0 sequence | 1,306,682 FP32 logits compared; all exactly identical |
| Maximum absolute difference in those prompt logits | 0.0 |
| Greedy text generation | Five prompts, 24 new tokens each; all token sequences identical |
| Seeded top-40 sampling, temperature 0.8 | Five prompts, 24 new tokens each; all token sequences identical, seed 20261006 |
| Validation | First 20 non-overlapping 64-token input batches of the held-out Tiny Shakespeare file; 1,280 predicted tokens |
| Mean validation cross-entropy, original | 4.010428404808044 |
| Mean validation cross-entropy, recovered | 4.010428404808044 |
| Per-batch validation logits and losses | Exactly identical in all 20 batches |

The explicit token-0 test exercises the embedding row containing the recovered sample. Generated texts and full token sequences are preserved in `model_report.json`. Matching generations establish preservation of behavior for the evaluated cases, rather than model quality. This validation mean uses 20 batches and must not be compared directly with the earlier training report's five-batch mean of 3.810759 as though they were the same evaluation.

## Advisor summary

We tested the Ascon-AEAD128 VHDL implementation using a 1 KiB sample of trained GPT-2 weights and evaluated the full GPT-2 model after restoring the decrypted sample. All 17 RTL checks passed. Modified ciphertext, tag, key, nonce, and associated data were rejected, while valid transactions recovered the weight bytes exactly, including after authentication failures and during stalled transfers. Restoring the recovered sample preserved all model parameters, prompt logits, generated token sequences, and validation losses exactly. This demonstrates functional integrity and preservation of inference behavior for the tested weight slice. Full-checkpoint RTL encryption, physical-board performance, side-channel resistance, and a production authenticated model loader remain untested.

## Evidence and reproduction

- RTL runner: `verification/gpt2_behavior.py`
- Model runner: `verification/gpt2_model_behavior.py`
- Public evidence receipts and runner/testbench snapshots: `paper/evidence/gpt2_behavior_20261006/`
- Trained binaries, full block dumps and generated projects remain local.
- Working XSim project: `build/gpt2_behavior_20261006/`
- Weight sample SHA-256: `fa00e0b873c026e9c25298fc1428872a09680e11e0ec5ac74af29fcab3e34541`
- Original/restored full-checkpoint SHA-256: `c5acb338337d9f14b814a21e1d18415ce72c34bf18650c9ead5299b4f3ad2733`

From PowerShell in the Ascon project:

```powershell
python verification/gpt2_behavior.py
wsl -d Ubuntu-22.04 -- bash -lc 'cd ~/projects/SAGE_Accelerator/llmc-gpt2 && .venv/bin/python /mnt/c/Users/Symok/Downloads/ascon-aead128-vhdl-main/verification/gpt2_model_behavior.py --training-root /home/kroix/projects/SAGE_Accelerator/llmc-gpt2 --evidence /mnt/c/Users/Symok/Downloads/ascon-aead128-vhdl-main/build/gpt2_behavior_20261006'
```

The existing WSL environment uses PyTorch 2.11.0+cu128. The test fixtures use public, fixed demonstration keys/nonces to reproduce results. These fixtures are not a deployed key-management or nonce-allocation scheme.
