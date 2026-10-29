# Multicore physical FPGA self-test, October 27 2026

All three core counts were programmed into the connected Nexys A7-100T
(XC7A100T, Digilent serial `210292ABF1AAA`). Two independent programming
and JTAG ILA capture runs passed for each configuration. Each run passed
all ten cases and matched the simulated case cycle counts exactly.

The fixture contains **3,072 bytes from the trained adapter**, with 256
bytes per layer: the first 64 bytes of each down_w, down_b, up_w and up_b
slice. Every encryption payload beat/tag and every valid decryption beat
is compared against the independent Python oracle on the FPGA. The
complete 2,397,696-byte adapter was validated previously in simulation;
**it was not transferred through the FPGA or DDR2 in this test**.

| Cores | Board clock MHz | Setup / hold ns | Encrypt cycles / us | Decrypt cycles / us | Physical results |
|---:|---:|---:|---:|---:|---|
| 1 | 90.000 | +0.963 / +0.038 | 1021 / 11.344 | 1009 / 11.211 | 10/10, twice |
| 2 | 90.000 | +0.776 / +0.032 | 511 / 5.678 | 505 / 5.611 | 10/10, twice |
| 4 | 75.000 | +0.306 / +0.028 | 307 / 4.093 | 304 / 4.053 | 10/10, twice |

| Physical case | 1 core cycles | 2 cores cycles | 4 cores cycles |
|---|---:|---:|---:|
| encrypt_ideal | 1021 | 511 | 307 |
| decrypt_ideal | 1009 | 505 | 304 |
| encrypt_bus_gaps_and_sink_stalls | 1071 | 559 | 434 |
| decrypt_bus_gaps_and_sink_stalls | 1042 | 530 | 391 |
| reject_last_layer_tag | 1006 | 502 | 301 |
| reject_ciphertext_tamper | 82 | 82 | 98 |
| reject_chunk_identity | 14 | 15 | 27 |
| abort | 81 | 81 | 81 |
| reset_during_traffic | 84 | 84 | 84 |
| decrypt_after_reset | 1009 | 505 | 304 |

| Final-harness route attempt | Clock MHz | Setup ns | Hold ns | Timing |
|---|---:|---:|---:|---|
| 1 cores | 100.000 | -0.026 | +0.030 | FAIL, not programmed |
| 1 cores | 90.000 | +0.963 | +0.038 | PASS |
| 2 cores | 100.000 | -0.238 | +0.030 | FAIL, not programmed |
| 2 cores | 90.000 | +0.776 | +0.032 | PASS |
| 4 cores | 90.000 | -1.391 | +0.028 | FAIL, not programmed |
| 4 cores | 75.000 | +0.306 | +0.028 | PASS |

Times use the FPGA cycle counters and the nominal MMCM clock derived
from the board oscillator; no external frequency calibration was performed.
Short authenticated messages have more overhead per byte than the full
adapter. These fixture results do not establish 1.5 ms physical file latency.
The ROM source and checker are part of this board harness and its timing
paths; area and timing differ from the configurable integration harness.

All preserved physical attempts have zero routing errors, missing clocks,
unconstrained internal endpoints, multiple-clock pins and combinational
loops. The asynchronous button entry and visual LED outputs are explicitly
excluded from external I/O timing. These are individual passing routes;
margins near zero do not establish a robust maximum frequency. Raw DRC
warnings are retained.

The selected routes also pass all four debug-IP bus-skew constraints.
The four-core board harness missed 90 MHz by 1.391 ns on a path from
the fixture source counter into the wrapper payload counter; it passed
at 75 MHz. This source is additional board-test logic, so its limit is
separate from the earlier registered integration harness at 90 MHz.

The ten cases are ideal encryption/decryption, encryption/decryption with
periodic shared-input gaps and output backpressure, corrupted final-layer
tag, corrupted ciphertext, wrong chunk identity, abort, reset during
traffic, and successful decryption after reset. Provisional plaintext
terminates at the trusted internal checker. Status is the only externally
observable test result. Commit is checked against exact beat/chunk counts;
any failure must discard and must never commit. The source deliberately
reuses public fixture nonces across repeat tests; they are not production
encryption nonces. An injected comparator fault was detected in GHDL for
each core count before building the bitstream.

Raw captures, device receipts, source/bitstream hashes, oracle fixture
metadata, simulated reference counts, timing coverage, routing and area
reports are in the accompanying evidence directory. Actual adapter slices
and generated ROM source stay in local build directories. No flash was
written, no board memory controller was added, and nothing was published.

In the initial vectors.json schema, generated_sha256 hashes the generated
source text with LF newlines. The exact Windows file-byte hash is recorded
in source_hashes.json; the generator now names these two forms explicitly.

Reproduction from this worktree (Windows, Vivado 2023.2, WSL system GHDL):

```powershell
python verification/generate_multicore_board.py <adapter-export-directory> <fresh-vector-directory>
python verification/run_multicore_board.py --vectors <vector-directory> --output <fresh-run-directory> --cores 1 --divider 9 --fallback-dividers 10 12 --program
# Repeat with --cores 2 --runtime-synthesis.
# For --cores 4 use --divider 10 --fallback-dividers 12 15 --runtime-synthesis.
# Then run Vivado on vivado/assess_multicore_board.tcl with the selected route directories as -tclargs.
```

The runner freezes source, requires a successful self-test simulation and
checker-injection test, then routes. It never generates a bitstream for a
failed timing attempt. Lower-clock attempts retain the prior reports and
change only the MMCM divider in the saved routed checkpoint. `--program`
explicitly enables volatile configuration and two physical capture runs.
`--simulate-only` runs the controller checks without starting Vivado.
The one-core build used default synthesis; the larger builds used
RuntimeOptimized synthesis. Earlier unfinished default-synthesis attempts
were stopped during lengthy area optimization and remain in local scratch
directories. This did not change RTL, fixtures or reference cycle counts.

An initial two-core board harness missed 100 MHz by 4.427 ns on a path
from the test counter through reset/collector selection and the large
reference comparator to the test status register. A registered monitor
now observes accepted output beats one clock later; the engine handshake
and completion timestamps are unchanged. Narrow index types also avoid
unnecessary integer arithmetic in the checker. All three configurations
were resimulated, rebuilt and captured with this same final monitor.
The development directory retains the earlier harness reports separately
from the selected final physical comparison.
