# Folded Ascon multicore study

The 2,397,696-byte FP32 adapter was gathered into twelve 199,808-byte layer chunks. Every ciphertext beat and tag matched the independent Python reference. All decryption runs reconstructed both the original file and the original checkpoint exactly. No training, board programming, physical memory benchmark, or publication was performed.

The simulated clock is 10 ns. These cycle-derived throughputs do not establish a routed hardware clock. Routed internal timing and modeled memory service are reported separately.

## Always-ready simulation

| Boundary queues | Cores | Direction | Cycles | Time ms | Payload MB/s | First output cycles | Commit tail cycles | Chunk latency min–max |
|---|---:|---|---:|---:|---:|---:|---:|---:|
| bypass | 1 | encrypt | 450,013 | 4.50013 | 532.806 | 29 | 19 | 37,498–37,498 |
| bypass | 1 | decrypt | 450,001 | 4.50001 | 532.820 | 29 | 18 | 37,496–37,496 |
| bypass | 2 | encrypt | 225,008 | 2.25008 | 1065.605 | 29 | 19 | 37,498–37,499 |
| bypass | 2 | decrypt | 225,002 | 2.25002 | 1065.633 | 29 | 18 | 37,496–37,497 |
| bypass | 4 | encrypt | 149,968 | 1.49968 | 1598.805 | 31 | 14 | 49,985–49,988 |
| bypass | 4 | decrypt | 149,965 | 1.49965 | 1598.837 | 31 | 13 | 49,983–49,986 |
| registered ready | 1 | encrypt | 450,013 | 4.50013 | 532.806 | 30 | 24 | 37,498–37,498 |
| registered ready | 1 | decrypt | 450,001 | 4.50001 | 532.820 | 30 | 23 | 37,496–37,496 |
| registered ready | 2 | encrypt | 225,007 | 2.25007 | 1065.610 | 30 | 23 | 37,498–37,498 |
| registered ready | 2 | decrypt | 225,001 | 2.25001 | 1065.638 | 30 | 22 | 37,496–37,496 |
| registered ready | 4 | encrypt | 149,971 | 1.49971 | 1598.773 | 33 | 15 | 49,986–49,989 |
| registered ready | 4 | decrypt | 149,968 | 1.49968 | 1598.805 | 33 | 14 | 49,984–49,987 |

Commit tail starts at the last accepted input payload beat. Output writes and tags can finish later; the JSON receipts also retain the final output-write timestamp. Every chunk has 96 bytes of authenticated metadata and its own nonce/tag.

## Scaling and historical baselines

| Configuration | Encrypt cycles | Decrypt cycles | Encrypt MB/s |
|---|---:|---:|---:|
| Whole-file baseline | 1,798,305 | 1,798,305 | 133.331 |
| Whole-file u3-buffered | 899,153 | 899,153 | 266.662 |
| Whole-file u3-fold | 449,581 | 449,581 | 533.318 |
| Chunked folded ×1 | 450,013 | 450,001 | 532.806 |
| Chunked folded ×2 | 225,008 | 225,002 | 1065.605 |
| Chunked folded ×4 | 149,968 | 149,965 | 1598.805 |

Two cores achieve 1.99999× and four achieve 3.00073× versus one chunked folded core. Four cores approach the separate 128-bit buses’ 1,600 MB/s payload ceiling. Relative to whole-file buffered u3, four cores achieve 5.99563×; relative to original u1, 11.99126×. Those denominators are intentionally different.

The source and collector each move at most one beat per clock. Two folded cores demand about 1,066.7 MB/s; four demand about 2,133.3 MB/s before bus contention. Equal chunk assignments balance work counts, while bus service still determines how often absorption can occur.

## Utilization and core waits

The table below uses registered-ready boundary queues and ideal service, encryption. Per-core lists are in lane order. Busy includes all time with an active command.

| Cores | Input total / payload % | Output total / payload % | Busy % per core | Internal starvation | Internal output block | Missed fold tails |
|---:|---:|---:|---|---|---|---|
| 1 | 33.316 / 33.300 | 33.303 / 33.300 | 99.989 | 0 | 0 | 0 |
| 2 | 66.633 / 66.601 | 66.606 / 66.601 | 99.989/99.989 | 0/0 | 0/0 | 0/0 |
| 4 | 99.971 / 99.923 | 99.931 / 99.923 | 99.989/99.990/99.991/99.991 | 0/0/0/1 | 0/0/0/0 | 37455/37455/37455/37455 |

A missed fold tail is an unavailable absorb opportunity while the tail still performs rounds. The engine may absorb on the next clock without spending a clock waiting in its absorb-only state. Consequently a low starvation-state count does not imply an unlimited input bus. Do not add tail misses, busy clocks, interface waits and internal stalls together.

The receipts partition source waits into setup, input capacity, shared-memory service, and arbitration; collector waits distinguish external sink backpressure from arbitration. See [the interface and metric definitions](multicore_format.md).

## Memory-service model

These bandwidth values are assumptions, not measured DDR2 results. A shared token budget charges both reads and writes, including AD and tags. The table uses registered-ready boundaries.

| Cores | Budget GB/s | Encrypt ms | Decrypt ms | Encrypt payload MB/s |
|---:|---:|---:|---:|---:|
| 1 | 1 | 4.79929 | 4.79928 | 499.594 |
| 1 | 1.3 | 4.50013 | 4.50001 | 532.806 |
| 2 | 1 | 4.79717 | 4.79715 | 499.815 |
| 2 | 1.3 | 3.74861 | 3.74847 | 639.623 |
| 4 | 1 | 4.79709 | 4.79713 | 499.823 |
| 4 | 1.3 | 3.74849 | 3.74831 | 639.643 |

A read plus a write of the payload alone is 4,795,392 bytes: the bandwidth-only lower bound is 4.795392 ms at 1 GB/s or 3.688763 ms at 1.3 GB/s. Actual modeled times also include service scheduling and chunk overhead. A later release copy would add traffic; it is excluded here. No physical file-time result is available.

Two and four cores have almost the same file time under these aggregate memory budgets. Two folded cores already exceed the 0.5–0.65 GB/s payload ceiling imposed by a read plus a write at 1–1.3 GB/s aggregate service. Actual controller traffic measurements should therefore guide the eventual core-count choice.

## Routed timing and area

Target: xc7a100tcsg324-1, Vivado 2023.2, registered integration harness. Setup/hold below are register-to-register results, including shared control, dispatcher and collector paths. External OOC ports have no package placement; their nominal zero-delay I/O checks are retained in reports but cannot establish physical I/O timing.

| Cores | Attempt | MHz | Internal setup ns | Internal hold ns | LUTs | Registers | BRAM primitives | Pass |
|---:|---|---:|---:|---:|---:|---:|---:|---|
| 1 | base | 100.000 | -0.071 | +0.101 | 6,329 | 3,209 | 0 | no |
| 1 | boundary | 100.000 | +0.004 | +0.098 | 6,980 | 3,873 | 0 | yes |
| 2 | base | 100.000 | -1.410 | +0.100 | 11,204 | 4,566 | 0 | no |
| 2 | boundary | 100.000 | +0.012 | +0.098 | 12,776 | 5,908 | 0 | yes |
| 4 | base | 100.000 | -4.829 | +0.098 | 23,037 | 7,260 | 0 | no |
| 4 | boundary | 100.000 | -0.814 | +0.098 | 25,916 | 9,933 | 0 | no |
| 4 | local_control | 100.000 | -1.094 | +0.098 | 25,916 | 10,966 | 0 | no |
| 4 | pblocks | 100.000 | -0.896 | +0.096 | 25,916 | 10,966 | 0 | no |
| 4 | 90MHz | 90.000 | +0.060 | +0.098 | 25,916 | 10,966 | 0 | yes |

| Cores | Passing configuration | Routed MHz | Kernel encrypt ms | Kernel payload MB/s |
|---:|---|---:|---:|---:|
| 1 | boundary | 100.000 | 4.50013 | 532.806 |
| 2 | boundary | 100.000 | 2.25007 | 1065.610 |
| 4 | 90MHz | 90.000 | 1.66634 | 1438.896 |

Selected internal setup margins range from 0.004 to 0.060 ns. These are single-route results.

| Cores | Selected critical-path class | Logic levels |
|---:|---|---:|
| 1 | Folded state-register feedback | 7 |
| 2 | Folded state-register feedback | 7 |
| 4 | Framing/control to core input boundary | 12 |

Detailed endpoints and cell/net delays are in the saved internal setup reports.


Mitigations are attempted in order: boundary queues, local control registers, separate core Pblocks, 90 MHz, then 83.333 MHz. Each attempt retains a source snapshot and reports. The table lists executed attempts; the runner stops at the first passing route. One passing route establishes feasibility for that run, not repeatable timing margin or physical board throughput. No bitstream was written or programmed.

The first prototype exposed a ready/selection combinational loop when an unselected tag candidate was zeroed. Candidate data is now independent of arbitration. Early timing then identified a long select/subtract/framing-check path. Final-beat geometry is now registered once and candidate checks run in parallel. Earlier prototype routes are superseded and must not be quoted as final-design timing.

## Reproduction and evidence

Run `verification/run_multicore.py --help` for the GHDL and compiled Verilator paths, `verification/route_multicore.py --help` for routing, and `verification/summarize_multicore.py --help` to regenerate this comparison. The full study uses the existing export; it performs no training or downloads. Output directories must be new; route resume uses its frozen source snapshot.

A shorter WSL/Linux entry point is `bash verification/benchmark_multicore.sh EXPORT_DIR NONCE_BASE FRESH_OUTPUT --registers`. It uses the existing export and checkpoint, and selects the compiled path when Verilator and the local OSS CAD Suite GHDL are available. `ASCON_SYNTH_GHDL` can override the synthesis tool path.

The full reports retain source/tool hashes, nonce ranges, commands, per-chunk timestamps, bus counts, and per-core waits. Fresh encryption ranges are required for new runs. All performance numbers are decimal MB/s. Reference artifacts remain in ignored build directories or WSL scratch; the compact evidence bundle excludes weight binaries.

## Later physical fixture and report

The earlier simulation and integration-route results above are retained as their own measurement scope. The [October 27 physical test](evidence/multicore_board_20261027/report.md) validates only a 3,072-byte fixture at 90/90/75 MHz for 1/2/4 cores. See the [combined research report](../paper/VHDL_Implementation_of_NIST_Ascon_AEAD128_on_a_Nexys_A7_FPGA.pdf) and [multicore architecture diagram](../paper/assets/v2/fig_xvi_multicore.png).
