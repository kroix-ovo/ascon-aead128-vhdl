# Folded absorption in the Ascon weight stream

The folded core encrypts or decrypts the complete 2,397,696-byte adapter in 449,581 cycles, compared with 899,153 for the buffered three-round core and 1,798,305 for the original one-round baseline. Ciphertext and tag bytes match the reference model, authentication succeeds, and recovered weights reconstruct the saved checkpoint exactly. These are behavioral simulation results. Full-file physical throughput has not been measured.

The branch is `ascon-weight-stream-fold-absorb`, starting at `8b886c075241d4f599f0a299f114b5fae133291e`. The local directory and historical evidence retain `handoff` in their names because receipts record those paths.

## Why the cycle count fell

The buffered core spends six clocks per full block: absorb, enqueue and load the permutation, three round-group clocks, then copy the completed state back. Its controller and permutation each own a 320-bit state register. The folded entity uses one state register and removes those handoffs.

The steady p8 schedule is three rounds, three rounds, then two rounds with absorption of the next block. Absorption follows the shorter two-round tail instead of extending the full three-round chain. p12 still uses four groups of three. No rounds, padding or authentication work are removed. Input metadata and padding are decoded when a beat enters the queue. If input is absent or output space is unavailable, the tail completes and an absorb-only clock later resumes the stream.

`G_FOLDED_ABSORB=true` selects the entity and requires `G_ROUNDS_PER_CYCLE=3` and `G_BUFFERING_ENABLE=true`. It is disabled by default. Public ports are unchanged. [NIST SP 800-232](https://csrc.nist.gov/pubs/sp/800/232/final), [Primas](https://github.com/rprimas/ascon-verilog), [Itschner](https://github.com/tristanitschner/ascon_cipher_verilog) and [LaForest](https://fpgacpu.ca/fpga/handshake.html) provide the algorithm and relevant architecture/interface references. These are established techniques; this report makes no cryptographic or exhaustive hardware novelty claim.

## Complete adapter results

| Configuration | Cycles each direction | Latency at simulated 100 MHz | Payload MB/s |
|---|---:|---:|---:|
| Original one-round baseline | 1,798,305 | 17.98305 ms | 133.331 |
| Buffered three-round core | 899,153 | 8.99153 ms | 266.662 |
| Folded three-round core | 449,581 | 4.49581 ms | 533.318 |

Counts include command through done, empty AD, final padding and tags, with always-ready output. Host transfers and simulator wall time are excluded. The 1 KiB counts are 801, 401 and 205. The folded full-block interval is three clocks. Its closed-form cycle model matches the saved always-ready traffic cases; this does not predict arbitrary stalled traffic without its service schedule.

The [adapter receipt](../docs/evidence/handoff_study_fold_20261021/adapter_sim_report.json) and [checkpoint hashes](../docs/evidence/handoff_study_fold_20261021/checkpoint_reconstruction.txt) identify the outputs. Payload SHA-256 is `c184175fc18d24373f009875c03698e630e8c36a5341146aab2bd13a98fff8eb`; checkpoint SHA-256 is `7c45c25b28ae54943c1fd4ee160001dcd9a68ee1f8430aee229f933545672de6`. No training was performed.

The folded entity used for those runs is unchanged by the later legacy-engine fixes. Whole-file hashes differ, so receipts must be read with their source snapshots. Pre-fix netlist identity is historical evidence, not a statement about the final patched default configuration.

## Timing and area

| Core-only snapshot at 100 MHz | Setup / hold slack ns | LUTs | Registers |
|---|---:|---:|---:|
| Buffered three-round before fixes | +0.038 / +0.144 | 3,708 | 1,680 |
| Buffered after AD fix, before tag gate | +0.287 / +0.110 | 3,871 | 1,688 |
| Folded core | +0.139 / +0.101 | 2,985 | 1,085 |

These are Vivado 2023.2 routes for xc7a100tcsg324-1 with unconstrained external I/O. Final legacy tag gating has not been rerouted. The folded entity already gated its output. Relative to the older buffered snapshot, the fold saves 723 LUTs and 595 registers. Small slack differences do not establish a higher maximum frequency.

The fold's setup path has seven LUT levels and 9.841 ns data delay. About 81% is reported as net delay; AMD explains that 7-series LUT delay is included in that figure, so it is not all removable wiring. See [UG906](https://docs.amd.com/r/en-US/ug906-vivado-design-analysis/Category-1-Timing) and [the core route](../docs/evidence/handoff_study_fold_20261021/vivado_fold_v2_p10/timing.txt).

Board copies with both cores folded routed at 83.333 MHz (+0.785 ns setup, +0.024 ns hold) and at 100 MHz in one run (+0.181 ns setup, +0.049 ns hold). The 100 MHz copy used 9,690 LUTs and 5,362 registers. Board LUT usage did not fall with core-only LUT usage; that difference remains unexplained. See [100 MHz](../docs/evidence/handoff_study_fold_20261021/board_fold_route_div10/implementation.json) and [83.333 MHz](../docs/evidence/handoff_study_fold_20261021/board_fold_route_div12/implementation.json) receipts.

No folded bitstream was written or programmed. Board simulations passed 18 self-test cases in 995 cycles and eight demo pairs in 198 cycles. Earlier physical captures belong to the buffered design. At 83.333 MHz, three clocks imply a 444.4 MB/s kernel ceiling, not measured physical transport. One passing 100 MHz route establishes feasibility for that run, not repeatable timing margin.

## Controller fixes and verification

The legacy engine had two defects, both fixed in this branch.

An empty last AD beat after full non-last beats skipped the mandatory padded block. `ad_seen_reg` now distinguishes that framing from genuinely empty AD and takes the existing padded-block p8 path. The earlier behavior was non-standard and allowed distinct AD strings to share an authentication state. Standard last-full-beat framing, official KATs and the empty-AD adapter workload were unaffected.

The legacy engine also drove its expected tag onto `tag_out_o` while awaiting a decryption tag. Exposing those bits to an untrusted observer could undermine authentication. The output is now zero during decryption. Encryption retains the extra tag-visible clock used by the demo. The folded entity already handled both cases. See [the fix note](../docs/ad_padding_fix.md).

The fold passed 2,178 official directional checks, stream tests, partial endings, stalls, reset and error tests, intermediate round-group checks and generated-Verilog smoke tests. Final tag-gate evidence records twelve handshake test groups passing for u1, u3, buffered u3 and fold; full KAT runs for u1/buffered/fold; stream regressions for buffered/fold; and cycle regressions for all four. Restoring the ungated assignment makes the tag-output test fail. The [regression log](../docs/evidence/tag_output_gate_20261021/regression_log.txt) and [board simulation log](../docs/evidence/tag_output_gate_20261021/board_sim_log.txt) preserve these results. Publication validation is recorded separately in `docs/evidence/fold_absorb_publication_20261021/`.

The default configurations intentionally differ from `8b886c0` for corrected framing and tag output. A default-off generic limits activation; it does not establish absence of regression risk. Physical programming, local validation and remote CI are separate evidence scopes.

## Weight storage and loading

The manifest describes four contiguous FP32 tensor groups. Their offsets, lengths and per-layer slices are 16-byte aligned. That supports burst planning and independent messages but removes no cryptographic work. A layer consumer may need scatter/gather reads because the file groups tensors rather than interleaving every layer's parameters.

Provisional plaintext must remain inside the trust boundary. A trusted quarantine accepts bytes while the transaction runs and releases them only on commit. Waiting for commit before accepting those bytes deadlocks this interface. A small FIFO cannot quarantine a whole model. If external DDR is untrusted, plaintext cannot be spilled there in the clear.

Independent authenticated chunks can bound quarantine and overlap prior-chunk compute with next-chunk loading. They require a new format and trusted policy: unique encryption nonces across resets and lanes, authenticated model/tensor identity, offsets, lengths and chunk count, plus a version anchor for rollback rejection. A valid tag does not prove a model is the currently authorized version. AEAD does not hide weights from a compromised authorized plaintext endpoint. [GuardNN](https://arxiv.org/html/2008.11632v2) motivates workload-aware protection, but its AES confidentiality-only FPGA prototype is not an Ascon authenticated-loader performance measurement.

The byte study measured about 17% lossless savings with exponent-oriented coding and exact recovery. Raw-byte LZ4 saved essentially nothing, Gorilla expanded the file, and fpzip saved about 8%. These are software codec results. An FPGA decoder must sustain the faster core and remain behind authenticated release. The [compression note](../research_notes/Ascon%20weight%20stream%20bottlenecks/weight_structure_compression.md) records schemes, failures and assumptions.

## Next measurements

Run a folded-core frequency and implementation-strategy sweep. A two-round fold is a separate untested candidate: four clocks at a sufficiently higher frequency could beat three clocks at 100 MHz. Pipeline registers alone do not improve one dependent stream's throughput; independent contexts change the tradeoff.

Measure memory service gaps and authenticated release before adding lanes. Larger FIFOs hide bursts but cannot improve a saturated three-clock schedule. Multiple cores need a dispatcher, independent contexts, arbitration and a written chunk format. Key provisioning, configuration integrity, rollback and side-channel protection remain system work; this unmasked functional core does not supply them.

The [source ledger](Ascon%20source%20ledger.md) separates final SP 800-232 sources, legacy variants, ASIC/FPGA results and simulation-only studies. [Working notes](../research_notes/Ascon%20weight%20stream%20bottlenecks/fold_implementation_results.md) preserve the history; later fixes and publication evidence take precedence over their earlier snapshot claims.

## Reproducing the adapter check

Use the existing export and manifest, without training:

```text
python verification/simulate_adapter.py <adapter_weights.bin> --manifest <manifest.json> --checkpoint <adapter_params_00000200.bin> --candidate u3-fold --output build/fold-new --nonce-base <unused-public-test-range>
```

The output directory must be new. Allocate fresh encryption nonces under the public test key. The runner validates tensor identity and optional checkpoint bytes, compares with its baseline and checks ciphertext, tags, commit and exact recovery. Historical runs record the baseline SHA; do not assume a moving `origin/main` is the same snapshot. See [publication validation](../docs/evidence/fold_absorb_publication_20261021/README.md) for final-source test scope.
