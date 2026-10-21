> Publication update October 21, 2026: current branch `ascon-weight-stream-fold-absorb`. This is a dated working note. The later AD-padding and decryption-tag-output fixes are complete. Legacy bit-for-bit preservation claims below apply only to the pre-fix snapshot. Final status is in [the report](../../reports/Ascon%20weight%20stream%20bottlenecks.md) and [the fix note](../../docs/ad_padding_fix.md). No physical fold throughput is claimed.

# Cycle-level bottlenecks of the buffered three-round Ascon-AEAD128 VHDL core (baseline study)

Scope and method. I read the core, the runners, the evidence and the paper, then reproduced the baselines in WSL GHDL 1.0.0 (mcode, VHDL-2008, 10 ns clock). The source was HEAD `8b886c0` on `codex/ascon-weight-stream-handoff-study`, with the baseline from `origin/main` `3cceb3c`. Committed RTL was not modified, and nothing was committed. For per-clock traces I used an instrumented copy, made by `build/handoff_sim/scripts/make_trace_copy.py`, which adds three passive textio processes: controller FSM state and engine handshakes, the permutation's busy flag, round counter and rounds per clock, and wrapper FIFO occupancy and external handshakes. The instrumented and plain RTL gave identical cycle counts in every run (117/117 traffic rows, plus all 1 KiB and full-adapter runs). Small evidence is in `docs/evidence/handoff_study_baseline_20261021/` (abbreviated **EV** below). Bulky traces, about 0.5 GB, stayed in WSL `~/ascon_handoff_scratch/runs`. Vivado was not run.

Labels used throughout:
- **MEASURED**: simulation output from this study.
- **REPO-CLAIM**: a statement in the repository's documents.
- **INFERRED**: my analysis or a model prediction, not measured.

---

## Q1. Exact core interface, handshake/metadata contract, controller FSM and how generics select configurations

### Takeaway
`ascon_aead128_core` is a thin wrapper around the original one-state-register controller `ascon_aead128_engine` and a separate iterative `ascon_permutation` that owns its own 320-bit state register. Every permutation call therefore costs a registered start, a registered done and two state copies:
- controller `state_reg` → permutation `state_reg` at start;
- permutation `state_o` → controller `state_reg` at completion.

`G_BUFFERING_ENABLE` adds 2-entry input and output queues. It also hard-wires `G_OVERLAP_OUTPUT=>true`, which launches p8 on the output-enqueue edge instead of in a separate `ST_MSG_PERM_START` clock.

### Cited Findings
- **Generics:**
  - `ascon_aead128_core` has `G_ROUNDS_PER_CYCLE` (1..12, default 1), `G_BUFFERING_ENABLE` (default false), `G_INPUT_FIFO_DEPTH` and `G_OUTPUT_FIFO_DEPTH` (default 2) and `G_FULL_BLOCK_FAST_PATH` (default false).
  - The engine additionally has `G_OVERLAP_OUTPUT` (default false). The bypass generate does not pass it, so it stays false; the buffered generate passes `G_OVERLAP_OUTPUT => true`.
  - Source: [rtl/ascon_aead128_core.vhd:18-23, 537-544, 588-591, 683-686](../../rtl/ascon_aead128_core.vhd)
- **Ports:**
  - Command channel: `cmd_valid_i/cmd_ready_o/cmd_decrypt_i`, with `key_i` and `nonce_i` as 128-bit little-endian byte lanes.
  - Input stream: `in_valid_i/in_ready_o`, with `in_kind_i` (0 = AD, 1 = payload), `in_data_i[127:0]`, `in_keep_i[15:0]` and `in_last_i`.
  - Tag channels: `tag_in_valid_i/ready_o/tag_in_i` and `tag_out_valid_o/ready_i/tag_out_o`.
  - Output stream: `out_valid_o/out_ready_i/out_data_o/out_keep_o/out_last_o`.
  - Status: `busy_o`, plus one-clock pulses `done_o`, `auth_valid_o`, `auth_ok_o`, `commit_o`, `discard_o` and `error_o`.
  - Source: [rtl/ascon_aead128_core.vhd:24-62](../../rtl/ascon_aead128_core.vhd)
- **Metadata rules** (an illegal beat raises `error_o`, plus `discard_o` when decrypting, then goes to `ST_ZEROIZE`):
  - The beat's kind must match the phase.
  - `keep` must be contiguous from byte 0.
  - A non-last beat must be full (`keep = FFFF`).
  - An empty beat (`keep = 0`) is legal only if `last = 1`. In the AD phase it means "no AD": the domain-separation XOR is applied with no p8. In the payload phase it means a final padded empty block.
  - Source: [rtl/ascon_aead128_core.vhd:258-303, 341-393](../../rtl/ascon_aead128_core.vhd)
- **Unbuffered handshakes:**
  - `cmd_ready_o` is high only in `ST_IDLE`.
  - `in_ready_o` is high only in `ST_AD_WAIT` or `ST_MSG_WAIT`.
  - `tag_in_ready_o` is high only in `ST_TAG_IN`.
  - `tag_out_valid_o` is high only in `ST_TAG_OUT`.
  - The output is a registered `out_valid_reg`.
  - `perm_start` is a pure decode of the START states, plus the overlap term `ST_MSG_OUTPUT and out_valid and out_ready and msg_full` when `G_OVERLAP_OUTPUT` is set.
  - Source: [rtl/ascon_aead128_core.vhd:157-189](../../rtl/ascon_aead128_core.vhd)
- **Controller FSM:** 18 states.
  - Command and initialisation: `ST_IDLE` → `ST_INIT_START` → `ST_INIT_WAIT`, with the key XOR on completion.
  - AD phase: `ST_AD_WAIT` ⇄ `ST_AD_PERM_START` → `ST_AD_PERM_WAIT`. For a full last AD block it continues with `ST_AD_PAD_START` → `ST_AD_PAD_WAIT`; the domain-separation (DSEP) XOR is applied on exit.
  - Payload phase: `ST_MSG_WAIT` (absorb, set the output register) → `ST_MSG_OUTPUT` (wait for the sink).
  - A full payload block then goes to `ST_MSG_PERM_START` → `ST_MSG_PERM_WAIT` (unbuffered), or directly to `ST_MSG_PERM_WAIT` (overlap).
  - A partial final block applies the key XOR and goes to `ST_FINAL_START`.
  - The completion of the last full block adds padding plus the key XOR and goes to `ST_FINAL_START`.
  - Tag phase: `ST_FINAL_WAIT` → `ST_TAG_OUT` (encrypt) or `ST_TAG_IN` (decrypt; constant-cycle compare, commit or discard) → `ST_ZEROIZE` → `ST_DONE` → `ST_IDLE`.
  - Source: [rtl/ascon_aead128_core.vhd:66-77, 230-492](../../rtl/ascon_aead128_core.vhd)
- **Permutation:**
  - On `start_i` it copies `state_i` into its own `state_reg`; no round is computed in that clock.
  - Each busy clock then applies up to `G_ROUNDS_PER_CYCLE` cascaded rounds. A guard skips lanes beyond round 11, which gives 3+3+2 for p8 and 3+3+3+3 for p12.
  - `done_reg` is registered and pulses on the edge of the last group, so the controller sees it one clock later.
  - Source: [rtl/ascon_permutation.vhd:44-90](../../rtl/ascon_permutation.vhd)
- **Buffered wrapper:**
  - `in_ready_o` = active, not closed, not aborted, no error, and (`ic < depth` or a pop on the same edge).
  - There is no combinational fall-through from an empty FIFO.
  - Input closes after the final payload beat.
  - `tag_in_ready_o` and `tag_out_valid_o` are gated by `drained` (`oc = 0`).
  - `cmd_ready_o = e_cmd_ready and not e_done`.
  - An error or done clears both queues.
  - Simulation assertions check overflow, underflow and "authentication preceded output drain".
  - Source: [rtl/ascon_aead128_core.vhd:660-767](../../rtl/ascon_aead128_core.vhd)
- **Commit contract:** decrypted bytes are provisional. Consumers must quarantine them and publish only on `commit_o`, and erase them on `discard_o`, an error or reset. The wrapper delays tag acceptance until queued plaintext drains. Source: [docs/weight_stream_3rpc.md "Authentication contract"](../../docs/weight_stream_3rpc.md)
- **Zeroization:** every terminal path goes through `ST_ZEROIZE`. Simulation asserts that all state, key, phase, output and tag registers, plus the permutation state, are zero on entering `ST_DONE`. Source: [rtl/ascon_aead128_core.vhd:469-526](../../rtl/ascon_aead128_core.vhd)
- **Configurations used by the runners:**
  - `baseline` = raw `origin/main` RTL, which has no generics.
  - `u3` = R=3, unbuffered.
  - `u3-buffered` = R=3 with buffering.
  - The board self-test core and the board demo both instantiate R=3 with buffering.
  - Sources: [verification/compare_stream.py:52-60](../../verification/compare_stream.py); [rtl/ascon_weight_selftest.vhd:66](../../rtl/ascon_weight_selftest.vhd); [rtl/ascon_weight_board_top.v:38](../../rtl/ascon_weight_board_top.v)
- **Core-only routed timing (REPO-CLAIM, Vivado, xc7a100t, 10 ns):**
  - Baseline: worst path from `controller_state_reg` to `state_reg`, 7.031 ns, 2 logic levels.
  - u3: worst path from `permutation_u/round_number_reg[2]` to `permutation_u/state_reg[230]`, 9.822 ns, 7 levels, 83% routing, slack +0.125 ns.
  - u3-buffered: worst path from `permutation_u/state_reg[50]` to `state_reg[13]`, 9.909 ns, 7 levels (6 round LUTs plus a final LUT3 D-input mux), 78% routing, slack +0.038 ns.
  - Sources: [docs/evidence/weight_stream_3rpc/baseline/setup_paths.txt](../../docs/evidence/weight_stream_3rpc/baseline/setup_paths.txt); [u3/setup_paths.txt](../../docs/evidence/weight_stream_3rpc/u3/setup_paths.txt); [u3-buffered/setup_paths.txt](../../docs/evidence/weight_stream_3rpc/u3-buffered/setup_paths.txt)

### Inferences
- The structural cause of the per-block overhead is the split between the controller state and the permutation state, joined by a registered start/done handshake. Each p8 pays one load clock (copy in, no rounds) and one completion clock (copy back), plus the separate absorb clock. Overlap mode merely hides the load clock inside the output-enqueue clock.
- The buffered candidate's critical path ends in a single LUT3 that is the permutation state register's D-input mux (round result vs load vs hold). Any proposal that widens this mux (for example an absorb input) costs at most a wider LUT at that level, provided its select signals are registered. Anything placed in series with the 3-round chain adds a level, and the candidate has only 38 ps of slack.

### Gaps
- I did not run Vivado (by instruction), so all critical-path statements about proposals are INFERRED from the existing routed reports.

---

## Q2. Reproduction of the baselines at 10 ns (1 KiB, complete adapter both directions, 1,641,984-byte workload)

### Takeaway
Every claimed cycle count reproduced exactly (MEASURED, GHDL), and both directions of every run passed:
- reference ciphertext and tag comparison;
- RTL authentication and commit;
- exact byte recovery with matching SHA-256.

New measurement: three rounds alone on the complete adapter takes **1,049,009 cycles** (7 clocks/block). This was not previously measured.

### Cited Findings
MEASURED in this study. Every row is a pass, and encrypt equals decrypt in all of them:

| Workload | baseline (origin/main, R=1) | HEAD R=1 | R=3 only | R=3 + FIFO + overlap |
|---|---:|---:|---:|---:|
| 1 KiB prefix of the adapter | 801 | 801 | 465 | 401 |
| Complete adapter, 2,397,696 B (149,856 blocks) | **1,798,305** | 1,798,305 | **1,049,009** (new) | **899,153** |
| Small-llama, 1,641,984 B (102,624 blocks) | 1,231,521 | 1,231,521 | 718,385 | 615,761 |

- Recovered SHA-256 for all adapter runs is `c184175f…98fff8eb` (equal to the export). The small-llama runs recovered `d1c38f9b…0b594`. Source: [EV/weight_file_runs.json](../../docs/evidence/handoff_study_baseline_20261021/weight_file_runs.json)
- The read-only checkpoint `adapter_params_00000200.bin` (SHA-256 `7c45c25b…672de6`) equals a 20-byte header `0200…40000000` followed by a body equal to the export. The repository's `simulate_adapter.validate()` also passed on the real export, manifest and checkpoint. It confirmed four groups: `down_w` [12,32,768] at offset 0, `down_b` [12,32] at 1,179,648, `up_w` [12,768,32] at 1,181,184 and `up_b` [12,768] at 2,360,832. Sources: [EV/regressions_log.txt](../../docs/evidence/handoff_study_baseline_20261021/regressions_log.txt); [EV/source_and_artifact_sha256.txt](../../docs/evidence/handoff_study_baseline_20261021/source_and_artifact_sha256.txt)
- These claims match the repository exactly: 1,798,305 and 899,153 for the adapter; 801/465/401 for 1 KiB; 1,231,521/718,385/615,761 for the 1,641,984-byte payload. Sources: [docs/weight_stream_3rpc.md](../../docs/weight_stream_3rpc.md); [paper/evidence/adapter_100mhz_20261021/README.md](../../paper/evidence/adapter_100mhz_20261021/README.md); paper Section XIII Tables VII–VIII.
- The official TextIO KAT bench (1,089 vectors, 2,178 checks per configuration) passed for all three configurations (MEASURED):

  | Config | Cycle range | Mean | 32-byte payload, encrypt mean |
  |---|---|---:|---:|
  | u1 | 34–88 | 57.030 | 72.636 (matches the paper's 72.636) |
  | u3 | 18–47 | 30.727 | 39.061 |
  | u3-buffered | 18–45 | 30.182 | 37.061 |

  Source: [EV/kat_textio_cycle_stats.txt](../../docs/evidence/handoff_study_baseline_20261021/kat_textio_cycle_stats.txt)
- With the existing controller on 1 KiB, sweeping `G_ROUNDS_PER_CYCLE` gave (unbuffered/buffered) (MEASURED, all pass):

  | R | Unbuffered | Buffered |
  |---|---:|---:|
  | 1 | 801 | 737 |
  | 2 | 533 | 469 |
  | 3 | 465 | 401 |
  | 4 | 399 | 335 |
  | 6 | 397 | 333 |
  | 8 | 333 | 269 |
  | 12 | 331 | 267 |

  The paper's earlier conditional estimates of 533 (2 rounds) and 399 (4 rounds) are exactly the measured unbuffered values. Sources: [EV/rpc_sweep_1KiB.json](../../docs/evidence/handoff_study_baseline_20261021/rpc_sweep_1KiB.json); paper Section XII-A.
- How cycles are counted: `tb_weight_file` counts from the clock in which `cmd_valid` is driven to the clock in which `done_o` is visible. Empty AD (one `keep=0, last=1` AD beat), always-ready output, a serial source and one AEAD message per direction. Source: [verification/vhdl/tb_weight_file.vhd:150-188](../../verification/vhdl/tb_weight_file.vhd)

### Inferences
- Discrepancies with the claims:
  - None in the cycle counts.
  - Two documentation nuances:
    1. "Queues add two clocks to first-output latency" holds only for the cocotb metric (see Q3: +1 FIFO stage plus 1 dead command clock in buffered mode).
    2. The prior receipts' source hashes mix CRLF and LF variants of identical content. For example, the permutation is `8ca72f49…` as LF (git blob) and `26ed449b…` as the CRLF working copy. I verified that the content is unchanged.
- For the adapter, the step from 1,049,009 (R=3 only) to 899,153 (with FIFO and overlap) is exactly 149,856 cycles, one per block. All of the buffering gain on this always-ready workload comes from overlapping the p8 launch with output enqueue. The queues themselves add nothing, because source and sink are never limiting.

### Gaps
- I reproduced the adapter comparison with my own driver, which mirrors `compare_stream.py` (`build/handoff_sim/scripts/run_weight_case.py`): the same bench, generic stripping for the baseline, oracle checks and SHA-256. I did not invoke `verification/simulate_adapter.py` end to end, which would run GHDL on `/mnt/c` through Windows `wsl`.
- I did not physically rebuild the checkpoint from the recovered dump, because the dumps were deleted after verification. Byte-exact reconstruction follows from recovered SHA-256 = export SHA-256 together with `checkpoint[20:] == export`.

---

## Q3. Cycle-level bottleneck breakdown from trace data

### Takeaway
In steady state the candidate spends **6 clocks per 16-byte block, and only 3 of them run rounds**. The other three are:
- the absorb clock;
- the output-enqueue clock, which also loads the permutation without computing a round;
- the completion clock, which copies the state back.

The 2-round tail group also leaves one of the three unrolled lanes idle. Over the complete adapter, **449,577 of 899,153 clocks (50.0%) are non-permutation**: 449,576 run round groups, 1,198,872 rounds in total. Unrolling from 1 to 3 rounds removed only round clocks: non-round clocks are 599,433 in both u1 and u3. Buffering with overlap removed exactly one non-round clock per block.

### Cited Findings
**Steady-state full block, u3-buffered** (MEASURED; identical in encrypt and decrypt; offsets 14–19 of the 1 KiB trace). Source: [EV/trace_tables/adapter_1KiB_trace-u3-buffered.txt](../../docs/evidence/handoff_study_baseline_20261021/trace_tables/adapter_1KiB_trace-u3-buffered.txt)

| Clock | FSM state | What happens | Permutation | FIFOs |
|---|---|---|---|---|
| c0 | `ST_MSG_WAIT` | Absorb. Encrypt: the rate becomes rate XOR (data AND mask). Decrypt: the rate's masked bytes are replaced by the ciphertext. Plaintext/ciphertext and padding go to `out_data_reg`. | idle (holding the last p8 output) | ipop + ipush (ic stays 2) |
| c1 | `ST_MSG_OUTPUT` | Engine output register enqueued (opush). The **p8 launch** happens on the same edge (`perm_start`); the permutation copies `state_reg` and computes no round. | load | oc 0→1 |
| c2 | `ST_MSG_PERM_WAIT` | Rounds 4–6 (constants B4, A5, 96) | 3 rounds | **opop: external output handshake** |
| c3 | `ST_MSG_PERM_WAIT` | Rounds 7–9 | 3 rounds | – |
| c4 | `ST_MSG_PERM_WAIT` | Rounds 10–11 (one lane idle) | 2 rounds | – |
| c5 | `ST_MSG_PERM_WAIT` | `perm_done` (registered) seen; `state_reg` ← `perm_state_out` (**completion copy-back**) | idle, done | – |

- **u3 unbuffered**, 7 clocks: absorb, output handshake, `ST_MSG_PERM_START` load, 3 round groups, completion.
- **u1**, 12 clocks: absorb, output, load, 8×1 round, completion.
- **Non-round share per block** (MEASURED from traces, INFERRED lane utilisation):

  | Config | Non-round clocks | Lane utilisation |
  |---|---|---|
  | u1 | 4/12 (33%) | 67% |
  | u3 | 4/7 (57%) | 8/21 = 38% |
  | u3-buffered | 3/6 (50%) | 8/18 = 44% |

  Sources: [EV/trace_summaries/adapter_1KiB_trace-*.json](../../docs/evidence/handoff_study_baseline_20261021/trace_summaries/)
- **Whole-adapter accounting** (MEASURED from the full traces, each direction). Source: [EV/trace_summaries/adapter_full_trace-*.json](../../docs/evidence/handoff_study_baseline_20261021/trace_summaries/)
  - **u3-buffered, 899,153 clocks:**
    - payload 899,136 = 6×149,856;
    - round-group clocks 449,576 = 3×149,856 + 8 (p12);
    - absorb 149,856;
    - enqueue+launch 149,856;
    - completion 149,855 + 1 final completion that also does pad + key XOR;
    - fixed 9 = command, init load, init completion/key XOR, empty AD, final load, final completion/tag, tag handshake, zeroize, done.
  - **u3, 1,049,009:** non-round 599,433 = 4N + 9.
  - **u1, 1,798,305:** round 1,198,872, non-round 599,433.
- **FSM transitions that create the overhead:**
  1. `ST_MSG_WAIT`→`ST_MSG_OUTPUT`. The absorb result must first land in the registered `state_reg`, because `perm_state_in <= state_reg`.
  2. The permutation's start clock only copies `state_i`. Unbuffered mode adds a whole `ST_MSG_PERM_START` state for it.
  3. The registered `done_reg` is seen one clock after the last group, so `ST_MSG_PERM_WAIT`→`ST_MSG_WAIT` spends a clock copying `perm_state_out` back.

  Sources: [rtl/ascon_aead128_core.vhd:179-189, 341-432](../../rtl/ascon_aead128_core.vhd); [rtl/ascon_permutation.vhd:52-89](../../rtl/ascon_permutation.vhd)
- **Fixed per-message costs** (MEASURED, R=3, both buffered and unbuffered unless stated). Source: [EV/traffic_phase_summary.txt](../../docs/evidence/handoff_study_baseline_20261021/traffic_phase_summary.txt)
  - **Command accept:** 1.
  - **Initialisation:** 6 = load 1 + 4 groups (3+3+3+3) + completion with key XOR 1. u1: 14.
  - **Empty AD:** 1 (marker beat plus DSEP).
  - **AD blocks:** 6 per AD block, in buffered mode too. The AD path never uses overlap: absorb, `ST_AD_PERM_START` load, 3 groups, completion. A length that is a multiple of 16 adds a padded-block p8 of 5 (load, 3 groups, completion). Measured AD totals, u3/buffered: AD16 = 11, AD27 = 12, AD32 = 17. u1: 21/22/32.
  - **Partial final payload block:** 2 (absorb, then output handshake with key XOR); no p8. pt1000 = 62×6 + 2 = 374 payload clocks in buffered mode.
  - **Full final block:** the padding block and key XOR are fused into the last completion clock, so it costs 0 extra.
  - **Finalisation:** 6 = load + 4 groups + completion/tag. u1: 14.
  - **Tag handshake:** 1. **Zeroize:** 1. **Done:** 1.
  - **Minimum transaction** (empty AD, empty payload): 18 (u3, buffered) and 34 (u1).
- **Closed-form model:** `1 + (2+G12) + AD + N·(G8+3 buffered | G8+4 unbuffered) + tail + (2+G12) + 3`, with `G8=⌈8/R⌉` and `G12=⌈12/R⌉`. It reproduces all 93 measured always-ready rows exactly: traffic scenarios plus weight-file runs. Source: [EV/cycle_model_predictions.txt](../../docs/evidence/handoff_study_baseline_20261021/cycle_model_predictions.txt)
- **First-output latency** (MEASURED; offset of the first external output handshake from the command clock):

  | | u1 | u3 | buffered |
  |---|---:|---:|---:|
  | Empty AD | 17 | 9 | 10 |
  | 27-byte AD | 38 | 20 | 21 |

  - The FIFO register stage adds 1 clock.
  - The repository's "+2" comes from the cocotb metrics (20→22), which also count a command wait. The buffered wrapper masks `cmd_ready_o` during the `done_o` pulse (`e_cmd_ready and not e_done`), so back-to-back transactions lose 1 clock per boundary. The trace confirms this: the unbuffered core accepts the next command in the done-visible clock; the buffered core accepts it one clock later.
  - The cocotb numbers line up once that is accounted for: bytes=0 gives 18 vs 19 and AD27 gives 412 vs 413, matching my 18 and 412.
  - Sources: [EV/traffic_results.json](../../docs/evidence/handoff_study_baseline_20261021/traffic_results.json); [docs/evidence/weight_stream_3rpc/traffic_metrics.json](../../docs/evidence/weight_stream_3rpc/traffic_metrics.json); [rtl/ascon_aead128_core.vhd:661](../../rtl/ascon_aead128_core.vhd)
- **Tag/commit tail** (MEASURED, 1 KiB):
  - Encrypt: done becomes visible 13 (buffered), 15 (u3) or 28 (u1) clocks after the last ciphertext handshake.
  - Decrypt, measured from the last provisional-plaintext handshake: tag accepted +10, commit visible +11, done +13 (buffered); u3 +12/+13/+15; u1 +25/+26/+28.
  - A bad tag has the same timing: `discard_o` appears where `commit_o` would.
  - In buffered mode the last output handshake happens during the first round group of the final p8, so the tail is 2 groups + completion + final p12 (6) + tag + zeroize + done.
  - Source: [EV/decrypt_commit_tail_offsets.txt](../../docs/evidence/handoff_study_baseline_20261021/decrypt_commit_tail_offsets.txt)
- **Source gaps** (MEASURED, 1 KiB, empty AD; source offers a new beat 1 clock in k; decrypt cycles):

  | Source rate | u1 | u3 | buffered |
  |---|---:|---:|---:|
  | Always ready | 801 | 465 | 401 |
  | 1/2 | 802 | 466 | 401 |
  | 1/4 | 804 | 468 | 401 |
  | 1/6 | 802 | 468 | 405 |
  | 1/8 | 808 | 535 | 535 |

  - At 1/8 all three-round configurations become source-bound at 8 clocks/block.
  - When the source is always ready, the input FIFO stays full (ic = 2) and the source is stalled 309 of 401 clocks.
- **Sink backpressure** (MEASURED, decrypt; sink ready 1 clock in k):

  | Sink rate | u1 | u3 | buffered |
  |---|---:|---:|---:|
  | 1/2 | 801 | 528 | 401 |
  | 1/4 | 803 | 530 | 401 |
  | 1/8 | 1,059 | 534 | 523 |
  | Bursty, 32 of 64 | 1,404 | 836 | 524 |

  - u3 degrades to 8 clocks/block under 1/2 because a stalled `ST_MSG_OUTPUT` blocks the p8 launch. The 2-entry output FIFO removes that coupling.
  - u1 at 1/2 is unaffected only because its 12-clock period aligns with the ready pattern.
  - The repository's mixed pattern (gaps 2/5, stalls 31/53, AD 27, decrypt) reproduced u3 = 862 and buffered = 581, matching the documented 862 and 581. u1 measured 1,714.
- **Fusions that already exist:**
  - The absorb clock already computes XOR, masking, padding and the output register together.
  - The repository's controlled full-block-mask experiment found no cycle saving: +125 LUTs, setup slack +0.204 → +0.030 ns. That fits a model in which masking costs logic, not clocks.
  - Source: [docs/evidence/weight_stream_3rpc/fast_path_experiment.json](../../docs/evidence/weight_stream_3rpc/fast_path_experiment.json)

### Inferences
- The candidate's bottleneck is the controller/permutation handoff, not round depth. With the existing controller, even R=8 (p8 in one clock) still needs 4 clocks/block: absorb, launch, round group, completion. That measured 269 clocks on 1 KiB, and R=12 measured 267.
- In this always-ready adapter case the FIFOs are neither the bottleneck nor the benefit. Their value is decoupling under sink stalls and source jitter, which held 401 clocks up to 1/4 sink duty.
- AD-heavy traffic (not this adapter) would see no benefit from overlap: 6 clocks per AD block at R=3.

### Gaps
- The per-clock data comes from textio trace processes in an instrumented RTL copy, because these record the FSM enum by name and avoid multi-GB waveforms for 1.8 M-cycle runs. I did not produce a VCD/FST.
- Traces are kept only in WSL scratch, not in the repository.

---

## Q4. Feasibility of handoff reductions and the theoretical minimum clocks/block

### Takeaway
The validated cycle model predicts the following (INFERRED):

| Proposal | Adapter cycles | Change | 1 KiB |
|---|---:|---:|---:|
| Measured candidate | 899,153 | – | 401 |
| Absorbing the next buffered block on permutation completion | ≈749,298 | −16.7% | 338 |
| …combined with launching p8 from that same clock | ≈599,442 | −33% | 274 |
| Folding the absorb/output into the 2-round tail group of p8 (3 clocks/block, the floor for R=3) | ≈449,587 | −50% | ≈211 |

The tail fold likely adds no level to the 3-round critical path, because the XOR follows only 2 rounds. A 4+4 schedule, or any absorb placed in series with a full 3-round group, lengthens the path that has only 38 ps of slack.

### Cited Findings
- The model reproduced all 93 measured always-ready rows exactly before I used it for predictions. Measured R=4 and R=8 buffered (335 and 269 for 1 KiB) also matched the model. Sources: [EV/cycle_model_predictions.txt](../../docs/evidence/handoff_study_baseline_20261021/cycle_model_predictions.txt); [EV/rpc_sweep_1KiB.json](../../docs/evidence/handoff_study_baseline_20261021/rpc_sweep_1KiB.json)
- The candidate's routed critical path is 9.909 ns (u3-buffered): permutation `state_reg` → 6 round LUTs (about 2 LUT levels and about 3.0–3.3 ns per round, roughly 80% routing) → LUT3 D-input mux → `state_reg`, with slack +0.038 ns. u3's path starts at `round_number_reg[2]`, which feeds the round-constant/guard select. Sources: [docs/evidence/weight_stream_3rpc/u3-buffered/setup_paths.txt](../../docs/evidence/weight_stream_3rpc/u3-buffered/setup_paths.txt); [u3/setup_paths.txt](../../docs/evidence/weight_stream_3rpc/u3/setup_paths.txt)
- The paper and the docs list "absorption directly on permutation completion" as the next experiment, conditional on the critical-path cost. Sources: paper Section XIII-E; [docs/weight_stream_3rpc.md "Remaining experiments"](../../docs/weight_stream_3rpc.md)

### Inferences
Predictions use R=3, empty AD and full-block payloads; all cycle counts are INFERRED from the validated model.

| Scheme | Clocks/block | 1 KiB | Small-llama | Adapter | Where the added logic sits; critical-path risk |
|---|---:|---:|---:|---:|---|
| Measured candidate | 6 | 401 | 615,761 | 899,153 | – |
| P1: absorb on completion (the completion clock XORs the FIFO head into `perm_state_out`'s rate and loads `out_data_reg`) | 5 | 338 | 513,138 | 749,298 | A new leg into the controller `state_reg`/`out_data_reg` D-mux: perm `state_reg` Q → mask/XOR → D, 2–3 LUT levels, off the round chain. **Low.** |
| P2: launch p8 on the absorb edge (`perm_state_in` = absorbed state computed combinationally; output register enqueues during round 1) | 5 | 337 | 513,137 | 749,297 | XOR/mask on the permutation's load leg, in parallel with the round chain, merging at the existing D-mux. **Low to moderate**: keep the selects registered so the final LUT3 does not grow a level. Needs output-register space at absorb time; `ST_MSG_OUTPUT` remains as the stall state. |
| P1+P2: completion + absorb + launch in one clock (in effect, absorb inside the permutation register) | 4 | 274 | 410,514 | 599,442 | Path perm Q → XOR → perm D on the load leg. **Low to moderate.** The controller's 320-bit `state_reg` could become redundant (area saving, unquantified). |
| P3: tail fold (the 2-round tail clock also XORs the next FIFO block into the rate, emits ciphertext or plaintext, and starts the next p8 in the following clock) | 3 | 211 | 307,891 | 449,587 | 2 rounds (about 6.5 ns) + XOR/mux (about 0.5–1.3 ns) < the 3-round path (9.9 ns). The "lane 3 bypass" mux that already exists for the 2-round group can take (2-round output XOR data) as its input. Tail flag, FIFO-head valid, keep mask and decrypt select must be registered. A fallback is needed when the source or sink is not ready (finish without absorbing, then use the P1+P2 path). **Moderate**: control complexity; the timing effect is likely neutral. |
| P3 + fixed fusions (launch p12 on the command edge; fold key-XOR/DSEP into the first absorb; launch final p12 from the last tail; present the tag on p12 completion; −4 fixed clocks) | 3 | 207 | 307,887 | 449,583 | Mostly control. Presenting the tag combinationally from the perm state adds output-path logic. |
| Floor for R=3 (round-group clocks + command + tag only) | 3 | 202 | 307,882 | 449,578 | – |

- **Merging start/wait/completion states:**
  - In buffered mode the MSG START state is already merged; that is the whole 7→6 gain.
  - The remaining INIT/AD/AD_PAD/FINAL START clocks are per message or per AD block. Merging them saves 1 clock each (AD would go from 6 to 5 clocks per block).
  - Removing the completion clock requires either a predictive done or a single state register; the group count is static (3 for p8, 4 for p12). Writing round-chain output straight into the controller's `state_reg` through the key-XOR/padding/absorb mux would put that mux in series with 3 rounds, so it is **not recommended**.
- **Fusing XOR/masking/output alone:** 0 clocks, because they are already fused into one clock. They help only once that fused clock is moved into an otherwise idle clock (P1) or into the tail (P3).
- **4+4 schedule:** this means R=4. A 4-round chain is an estimated ≈12.5–13.5 ns from scaling the routed 3-round path, so it would not close at 10 ns. At about 75–80 MHz it gives 2 clocks/block with a folded absorb (≈27 ns/block) or 3 without (≈40 ns/block).
- **Theoretical minimum clocks/block** under the data dependency (p8 must finish before the next absorb): ⌈8/R⌉ if the absorb XOR rides in a round-group clock, ⌈8/R⌉+1 if it needs its own clock.
  - **R=3:** 3. The slack in the 2-round group absorbs the XOR at no added depth. 4 without folding.
  - **R=4:** 2, with the XOR in series with 4 rounds; 3 otherwise.
  - **R=8:** 1, with the XOR in series with 8 rounds (≈26–28 ns, ≈37 MHz); 2 otherwise.
  - Model totals (adapter / 1 KiB): R=4 fold 299,729 / 145; R=8 fold 149,871 / 79. The existing controller at R=4 and R=8 measured 335 and 269 for 1 KiB, extrapolated to 749,295 and 599,437 for the adapter.
- **Wall time per block** (INFERRED): about 8 round delays ≈ 26 ns sets a single-message floor regardless of R.

  | Design | Wall time per block |
  |---|---|
  | Candidate | 60 ns |
  | P1+P2 | 40 ns |
  | P3 at 100 MHz | 30 ns, about 90% of the floor, with half the round logic of R=8 |
  | R=4 or R=8 with folding | ≈27 ns at a much lower Fmax and more area |

  P3 at R=3 is therefore the most attractive point for a single stream.
- **Implications for source and sink:**
  - At 3 clocks/block the core consumes and produces 16 B per 30 ns (533 MB/s at 100 MHz).
  - The traffic results show that a sink at ≤1/4 duty or a source at ≤1/4 rate would then become the limit.
  - A depth-2 FIFO should suffice at 1 beat/clock; deeper FIFOs only absorb burstiness.

### Gaps
- None of P1–P3 was implemented or routed, so every saving and critical-path statement here is INFERRED.
- I did not quantify the LUT/FF change. Removing the duplicate controller `state_reg` could save up to about 320 FFs, which is unverified.
- Decrypt in P3 needs a ciphertext-insertion mux after 2 rounds. This looks symmetric to encrypt but has not been checked.

---

## Q5. Existing test coverage and gaps

### Takeaway
Coverage of the following is strong:
- functional KAT and protocol behaviour;
- grouped-permutation intermediate states;
- concurrent buffered traffic, gaps, stalls and FIFO depths 1–3;
- tampering and malformed beats;
- reset with buffered data.

There are four gaps:
1. Performance (cycles/block, first-output latency, tail) is not locked by any assertion.
2. The handshake-level `test_ascon` suite fails 3 of 10 tests on the buffered configuration and CI never runs it there.
3. The full-file bench covers only always-ready, empty-AD, full-block traffic.
4. There are no formal or coverage metrics.

### Cited Findings
- **Official KATs:**
  - All 1,089 vectors (AD and payload 0..32 bytes) in both directions.
  - Used by the TextIO bench `tb_ascon_aead128`, by cocotb `test_ascon` (a boundary subset by default; `FULL_KAT=1` runs everything) and by `test_stream` (`FULL_KAT` defaults to 1).
  - CI runs `test_stream` FULL_KAT=1 for u3 and u3-buffered.
  - In this study, TextIO passed 2,178/2,178 for u1, u3 and u3-buffered.
  - Sources: [verification/cocotb/test_ascon.py:193-230](../../verification/cocotb/test_ascon.py); [verification/cocotb/test_stream.py:124-133](../../verification/cocotb/test_stream.py); [.github/workflows/verify.yml](../../.github/workflows/verify.yml); [EV/kat_textio_cycle_stats.txt](../../docs/evidence/handoff_study_baseline_20261021/kat_textio_cycle_stats.txt)
- **Intermediate permutation states:** `test_permutation` checks the state after every registered group, for p1..p12, on 33 states (396 cases per factor). CI runs it for u1 and u3, and it passed here for u3. Sources: [verification/cocotb/test_permutation.py](../../verification/cocotb/test_permutation.py); [EV/regressions_log.txt](../../docs/evidence/handoff_study_baseline_20261021/regressions_log.txt)
- **Backpressure, gaps and stability:**
  - `test_stream` applies input gaps (t%5 ∈ {0,1}), output stalls (ready when t%53 ≥ 31) and tag-out stalls (t%7). It also checks that a stalled output never changes.
  - `test_ascon.outputs_remain_stable_during_backpressure` covers the same for unbuffered.
  - Source: [verification/cocotb/test_stream.py:21-44, 76-83](../../verification/cocotb/test_stream.py)
- **FIFO boundaries:**
  - CI covers depth 2 (FULL) and depth 1/1 (FULL_KAT=0). The evidence also records depth 3 with the fast path.
  - RTL simulation assertions check overflow, underflow, auth-before-drain and queued beats at done.
  - Depth 1/1 passed here.
  - Sources: [.github/workflows/verify.yml](../../.github/workflows/verify.yml); [docs/evidence/weight_stream_3rpc/verification_summary.json](../../docs/evidence/weight_stream_3rpc/verification_summary.json); [rtl/ascon_aead128_core.vhd:754-767](../../rtl/ascon_aead128_core.vhd)
- **Reset:**
  - `test_ascon.reset_aborts_an_active_transaction` and `reset_clears_each_major_controller_phase` (init p12, AD p8, held output, final p12, tag wait) cover unbuffered.
  - `test_stream` resets with full queues under backpressure, then runs a clean transaction.
  - The board self-test starts with a reset-aborted transaction.
  - Sources: [verification/cocotb/test_ascon.py:352-430](../../verification/cocotb/test_ascon.py); [verification/cocotb/test_stream.py:165-182](../../verification/cocotb/test_stream.py); [rtl/ascon_weight_selftest.vhd](../../rtl/ascon_weight_selftest.vhd)
- **Malformed streams:**
  - `test_ascon.malformed_streams_report_error` and `wrong_phase_and_held_extra_beats_are_rejected` cover unbuffered.
  - `test_stream` has 6 raw malformed patterns: wrong kind, non-contiguous keep, short non-final, empty non-final.
  - Source: [verification/cocotb/test_stream.py:158-163](../../verification/cocotb/test_stream.py)
- **Partial final blocks:**
  - The KAT grid covers 0..32 bytes.
  - `test_stream` sizes are 0, 1, 15, 16, 17, 31, 32, 33, 127, 1024 and 4096, with AD = 3i bytes.
  - `deterministic_randomized_differential_cases` covers longer messages.
  - This study also checked AD of 16, 27 and 32 bytes, pt1000 and pt1, all passing.
- **Authentication failures:**
  - `test_stream` tampers each of ct, AD, nonce and tag.
  - Also covered: `corrupted_tag_discards_plaintext`, `changed_authenticated_inputs_are_rejected` and `delayed_tag_and_authentication_timing`.
  - The board fixtures include tampered tag, nonce, AD and ciphertext.
  - The zeroization assertions at `ST_DONE` are simulation-only.
  - This study's bad-tag runs gave auth=1, auth_ok=0, commit=0, discard=1 in all three configurations.
  - Sources: [verification/cocotb/test_stream.py:142-157](../../verification/cocotb/test_stream.py); [verification/generate_selftest.py](../../verification/generate_selftest.py); [EV/traffic_results.json](../../docs/evidence/handoff_study_baseline_20261021/traffic_results.json)
- **Reproduced here** (MEASURED): `test_ascon` passes 10/10 at R=1 and R=3 unbuffered. Run on R=3 buffered it fails 3/10:
  - `malformed_streams_report_error`;
  - `wrong_phase_and_held_extra_beats_are_rejected`, where it expects `in_ready_o` low and the buffered queue accepts instead;
  - `reset_clears_each_major_controller_phase`.

  CI never runs that combination. `test_stream` passed for u3 unbuffered, u3 buffered and buffered depth 1/1 (FULL_KAT=0). Sources: [EV/regressions_log.txt](../../docs/evidence/handoff_study_baseline_20261021/regressions_log.txt); [EV/regressions2_log.txt](../../docs/evidence/handoff_study_baseline_20261021/regressions2_log.txt)
- **Full-file bench limits:** empty AD only, full blocks only (length must be a multiple of 16), always-ready sink and a serial source. Source: [verification/simulate_weight_file.py:44-45](../../verification/simulate_weight_file.py); [verification/vhdl/tb_weight_file.vhd](../../verification/vhdl/tb_weight_file.vhd)
- **Hardware:** 18 self-test cases and 8 demo pairs, with fixtures of at most 64 payload bytes. Source: [docs/weight_stream_3rpc.md](../../docs/weight_stream_3rpc.md)

### Inferences
Gaps that matter for a handoff-reduction redesign:
1. **Performance regression is unguarded.** No assertion pins 6 clocks/block, first-output latency, the 13-clock tail or the 18-clock minimum. `stream_metrics.json` is written but not checked. A redesign could silently regress, or "improve" through a protocol violation.
2. **Buffered mode lacks the per-phase reset sweep and the phase-error tests of `test_ascon`.** A redesign that absorbs from the FIFO on completion or in the tail moves error detection (kind/keep/last checks) into new clocks. It needs a buffered-aware port of those tests.
3. **Error with queued ciphertext/plaintext mid-message** (a malformed beat behind valid queued output) is not explicitly checked for which outputs escape before `discard`.
4. **Back-to-back command cadence is untested**, including the 1-clock `cmd_ready` mask in buffered mode and a command offered during the done pulse.
5. **Full-length runs with backpressure, AD or partial tails** are absent, and generated-Verilog runs are smoke only (`KAT_LIMIT=8` / `FULL_KAT=0`).
6. **R values other than 1 and 3** (2, 4, 6, 8, 12) are not in CI. My 1 KiB sweep passed for all of them.
7. **No formal or coverage metrics:** no FSM state/transition coverage, no property checks for ready/valid stability or commit-after-drain, no equivalence check of the instrumented vs plain RTL beyond cycle equality.

### Gaps
- I did not run `FULL_KAT=1` `test_stream` (CI runs it), the Icarus/Verilator generated-netlist tests, or the board self-test or demo simulations in this study. Their pass status here is a REPO-CLAIM.
- I did not trace the 3 buffered `test_ascon` failures beyond the assertion text. They look like test-harness assumptions (unbuffered `in_ready` and error timing), not RTL bugs, but that is unverified.
