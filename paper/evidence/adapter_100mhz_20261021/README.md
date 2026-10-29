# Complete adapter weight simulation evidence

The October 20, 2026 comparison uses the exact existing export
`runs/adapter_fp32_200/export/adapter_weights.bin`: 2,397,696 bytes,
599,424 FP32 values, four contiguous row-major little-endian tensor groups.
`export_manifest.json` records shapes, byte offsets, lengths and source hashes.
No training was run for these tests. The 20-byte original checkpoint header is
outside this export; preserving that header and replacing its body with recovered
weights reconstructed the checkpoint byte for byte.

| Configuration | Encrypt cycles | Decrypt cycles | Latency each at 100 MHz | MB/s |
|---|---:|---:|---:|---:|
| Unchanged origin/main one-round RTL | 1,798,305 | 1,798,305 | 17.98305 ms | 133.331 |
| Three rounds with buffering and launch overlap | 899,153 | 899,153 | 8.99153 ms | 266.662 |

`candidate_report.json` is the complete XSim result and source receipt.
`baseline_report.json` is the fresh GHDL baseline result for the same file and a
1 KiB prefix. The baseline reproduced the earlier XSim result exactly.
The `.txt` logs and terminal result files preserve the corresponding runs.
`comparison.json` binds the old baseline, rerun and candidate. Its absolute paths
identify the original local artifacts; public evidence uses the adjacent files.

The simulated clock is 10 ns. Counts include command through done, streaming,
mandatory final padding and tags, with empty AD and always-ready output; host I/O
and simulator wall time are excluded. Both directions pass all block and tag
checks against the independent Python oracle (first checked on all 1,089 official
KATs), authenticated commit, and zero mismatched recovered bytes. Independent
encryption messages use different nonces, so ciphertext hashes differ.

Payload original and recovered SHA-256:
`c184175fc18d24373f009875c03698e630e8c36a5341146aab2bd13a98fff8eb`.
Reconstructed checkpoint SHA-256:
`7c45c25b28ae54943c1fd4ee160001dcd9a68ee1f8430aee229f933545672de6`.

Reproduce from the repository root using existing artifacts:

```text
python verification/simulate_adapter.py <adapter_weights.bin> --manifest <export/manifest.json> --checkpoint <adapter_params_00000200.bin> --output build/adapter-new --nonce-base <unused-integer-range>
```

The new runner compares 1 KiB and full-file baseline/candidate configurations and
uses four unused public-test nonces. It requires GHDL, or Ubuntu-22.04 WSL on
Windows. It does not download weights or run training. Binary weights, recovered
binaries, full block dumps and generated simulation projects remain untracked.
The original XSim runner remains available as `verification/simulate_weight_file.py`.

`publication_rerun.json` records the October 21 end-to-end run of the new adapter
runner. Both configurations and both payload lengths passed; the complete-file
cycle counts and hashes match the October 20 comparison. Both checkpoints were
reconstructed exactly. `publication_*_ghdl.txt` preserve its full-file logs.
Six synthetic metadata tests in `verification/test_adapter_export.py` also check
valid exports and rejection of changed bytes, offsets, tensor identity, checkpoint
headers and checkpoint bodies. CI runs those without needing trained weights.

Architecture sources, checked October 21, 2026:

- [NIST SP 800-232](https://csrc.nist.gov/pubs/sp/800/232/final): algorithm and required rounds.
- [Primas Ascon hardware](https://github.com/rprimas/ascon-verilog): configurable unrolling variants informing the earlier study.
- [OpenTitan Ascon design](https://opentitan.org/book/hw/ip/ascon/doc/theory_of_operation.html): dependencies, latency/area tradeoffs, and masking limits.
- [LaForest handshake rules](https://fpgacpu.ca/fpga/handshake.html): supporting rationale for stable, lossless ready/valid buffering.

These support general design choices; this repository's three-round grouping,
queues and overlap are local implementation work. No third-party speedup is
attributed to this design. Section XIII of the Word/PDF research report separates
these simulated results from 100 MHz core-only timing and the 83.333 MHz board.
