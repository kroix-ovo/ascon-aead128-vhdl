> Publication update October 21, 2026: current branch `ascon-weight-stream-fold-absorb`. This is a dated working note. The later AD-padding and decryption-tag-output fixes are complete. Legacy bit-for-bit preservation claims below apply only to the pre-fix snapshot. Final status is in [the report](../../reports/Ascon%20weight%20stream%20bottlenecks.md) and [the fix note](../../docs/ad_padding_fix.md). No physical fold throughput is claimed.

# Folded-absorb (reduced-handoff) Ascon-AEAD128 core: implementation and measurements

Scope. I implemented a new configuration of `ascon_aead128_core`, selected by a new generic `G_FOLDED_ABSORB` (default `false`), and compared it with the buffered three-round candidate (`G_ROUNDS_PER_CYCLE=3, G_BUFFERING_ENABLE=true`). Worktree `worktrees/ascon-weight-stream-handoff`, branch `codex/ascon-weight-stream-handoff-study`, base `8b886c0`. Nothing was committed, pushed or merged. No hardware was programmed, no bitstream was written, and no training was run.

Labels:
- **MEASURED**: produced in this study (GHDL simulation or Vivado 2023.2 routed reports).
- **PREDICTED**: closed-form model output from the baseline study (`baseline_cycle_bottlenecks.md`, Q4).
- **INFERRED**: my reasoning, not measured.
- **TIMING-STUDY**: results of the parallel timing study, from `routed_timing_unroll.md` (re-read before finalizing; file dated 2026-10-21 15:00) and its `build/handoff_vivado/` outputs. Those numbers are not mine.


**Status (2026-10-21, end of study): COMPLETE.**
- Design implemented and every planned check run on the final RTL: simulation, adapter, Vivado core-only, board-integrated.
- Pending: none from the brief.
- Suggested follow-ups (§7):
  - an Fmax/strategy sweep for the fold core;
  - removing `rst_i` from the ready/valid outputs;
  - a decision on the existing AD split-framing bug;
  - a GitHub Actions run of the edited workflow.

Evidence: `docs/evidence/handoff_study_fold_20261021/` (abbreviated **EV**). Bulky outputs, routed checkpoints, netlists and the reconstructed checkpoint are in `build/handoff_fold/` (gitignored).

## Summary

| | Buffered three-round candidate | **New `G_FOLDED_ABSORB` core** |
|---|---:|---:|
| Steady state (MEASURED) | 6 clk / 16-B block | **3 clk / block**: the R=3 floor ⌈8/3⌉ |
| Complete adapter, each direction (MEASURED, 10 ns) | 899,153 cycles (8.99 ms) | **449,581 cycles (4.50 ms), 2.000× fewer** |
| 1,641,984-B payload / 1 KiB (MEASURED) | 615,761 / 401 | **307,885 / 205** |
| Routed at 100 MHz, core only (MEASURED, Vivado 2023.2) | WNS +0.038 ns, WHS +0.144 ns | **WNS +0.139 ns, WHS +0.101 ns** |
| Area (MEASURED, post-route) | 3,708 LUT / 1,680 FF | **2,985 LUT / 1,085 FF / 320 MUXF7** |
| Throughput at 100 MHz (16 B per 3 × 10 ns) | 266.7 MB/s | **533.3 MB/s (4.27 Gb/s)** |
| Official KAT checks | 2,178/2,178 | **2,178/2,178** |

**Correctness (MEASURED):** every check passed, and the default and buffered configurations are unchanged, bit-for-bit and cycle-for-cycle:
- GHDL-synth netlists are identical apart from source-location comments;
- all 2,178 per-case KAT records are byte-identical;
- 117/117 traffic rows are identical.

**Adapter (MEASURED):** encrypt and decrypt through the repository runner chain matched the reference ciphertext and tag, authenticated and committed, and recovered the exact bytes. The checkpoint was rebuilt to SHA-256 `7c45c25b…672de6`.

**The 3 buffered `test_ascon` failures:** test-timing assumptions, not RTL bugs. The tests are fixed, and `test_ascon` now passes 10/10 on every configuration.

**New findings:**
- **Existing cores mishandle split AD framing (MEASURED).** They produce non-standard output for AD framed as full non-last beat(s) followed by an empty last beat (§1.4). The fold core follows SP 800-232 for that framing.
- **The demo depends on a tag-timing detail.** It samples `tag_out_o` one clock after the handshake; the fold core preserves that window (§7, N2).
- **Board-integrated build (MEASURED, no bitstream):** with both cores folded it closes at 83.333 MHz (+0.785 ns) and, in one run, at 100 MHz (+0.181 ns). The candidate's 100 MHz board build had failed at −0.130 ns.

---

## 1. Design

### 1.1 Rationale (cited)
- The measured bottleneck is the handoff, not the round depth. In steady state the buffered candidate spends 6 clocks per 16-byte block and only 3 of them run rounds. The other three are the absorb, the copy-in, and the copy-back caused by a registered `done`. The cause is two 320-bit state registers, one in the controller and one in `ascon_permutation`, joined by a registered start/done handshake. Source: `baseline_cycle_bottlenecks.md` Q3.
- Fused-absorb designs reach ceil(8/r) clocks per block with no absorb or handoff clock: Itschner (SP 800-232, absorb XOR combinational at the permutation boundary), CAST, Groß, Malal. The literature notes rank "fuse absorb into the cycle boundary" first and "put the absorb in the 2-round group so it is never in series with 3 rounds" second, with pre-registered padding third and a registered zero-bubble handshake fourth. Source: `ascon_hardware_literature.md` Q5 (S7–S10), Q7 ranked techniques #1–#4.
- Handshake rules: ready must not depend combinationally on valid, and ready should come from registered state. A 2-entry queue (skid-like) lets `in_ready` be registered without bubbles. Source: `ascon_hardware_literature.md` Q6 (S12–S14, LaForest/ZipCPU).
- Critical-path budget: the candidate's routed worst path is permutation state → 6 round LUTs → LUT3 D-mux → state, at 9.909 ns (+0.038 ns). Only the final mux level can absorb an extra leg at no cost. Source: `baseline_cycle_bottlenecks.md` Q1 and Q4.

### 1.2 What was built (`rtl/ascon_aead128_core.vhd`, new entity `ascon_aead128_fold`)

1. **Single state register; direct round datapath.** The new entity owns one 320-bit `s_reg` and three cascaded rounds: `lane0 → lane1 → lane2`. There is no separate permutation register and no start/done handshake, so p8 has no copy-in or copy-back clock. Round constants come from three 8-bit registers `rc0..rc2`, loaded one clock ahead from the next FSM state and group (`rc_for`). The constant XOR on x2's low byte then sees one registered input instead of a round-number decode.

2. **Schedules (all standard round counts).**
   - p12 = 3+3+3+3 (constants F0..4B).
   - p8 = 3+3+2 (constants B4..4B).
   - Both are checked group by group against the Python reference in `test_fold`.

3. **Folded absorb in the 2-round tail (≈ technique #2, "absorb fused with the 3+3+2 tail").**
   - The tail clock takes `lane1` (rounds 10 and 11). One more LUT level then applies the queued next block:
     - rate ← `(rate & ~replace_mask) ^ X`, where `X = (data & byte-mask) ^ pad`;
     - `replace_mask` is the byte mask on decryption, so ciphertext replaces the rate;
     - optional capacity terms: the finalization key in words 2–3 and the DSEP bit 319.
   - The same clock writes the output beat `(rate(lane1) ^ X) & mask` (ciphertext or provisional plaintext) into the output queue.
   - The next clock starts the next p8 directly.
   - A full 3-round group goes `lane2 → D-mux` with nothing added in series. The tail leg (`lane1 → absorb LUT → D-mux`) and the output tap both share lanes 0 and 1. No second round datapath was added, which is why the area went down (§5).

4. **Pre-decoded queue entries (technique #3).** When the input queue accepts a beat, it stores:
   - `X`, with masking and the pad bit already applied;
   - `keep`;
   - `rep` (decrypt AND payload);
   - `kind`, `last`, `full`, `empty`;
   - `err` (non-contiguous keep, or a short or empty non-last beat).

   The queue is a shift register, so its head is always entry 0 and is read without a pointer mux. In the candidate the routed FIFO-head → keep decode → absorb path was 8.98 ns with 7 levels (TIMING-STUDY, `routed_timing_unroll.md` §5, `fifo_to_eng.txt`). It now starts at plain register bits: 4 levels and 8.5 ns in the routed fold design (§5).

5. **XOR-only leg (fallback and per-message terms).** `s_reg ← (s_reg & ~replace_mask) ^ F` is used for:
   - the command load (IV‖K‖N);
   - the first absorb of a message;
   - a block that was **not** queued, or had no output space, when its tail clock arrived (fallback: the tail finishes p8 unmodified, and the block is absorbed by this leg later, so the state is never corrupted);
   - the pending init-key XOR (words 3–4) and DSEP, applied together with that absorb.

   Partial or empty final payload beats also add padding and the finalization key here or in a tail. The empty "no AD" beat is consumed while p12 runs, because it needs no state.

6. **Tag.** The tag is `s_reg[319:192] ^ key`, computed combinationally from registers; there is no tag-register clock. `tag_out_o` is gated by a registered `tag_gate`:
   - In encryption it is non-zero exactly while the tag is offered and in the following erase clock. This matches the existing configurations, where `tag_reg` holds the tag during `ST_ZEROIZE`. The demo wrapper samples `tag_out_o` one clock after its handshake; see §7, negative result N2.
   - In decryption `tag_out_o` stays zero. The existing engine drives the expected tag onto `tag_out_o` during `ST_TAG_IN`. That is a pre-existing exposure in the default and buffered configurations, which I left unchanged there.

7. **Handshakes (LaForest).**
   - `in_ready_o = accepting(fsm) & !closed & !rst & !error_now & (ic<D | pop)`. Here `pop` and `error_now` are functions of registered state and the queue head only. There is no path from `in_valid_i` or `out_ready_i` to `in_ready_o`.
   - Output space for a fold is the registered `oc < D`, with no same-clock pop credit. This costs no throughput at 3 clocks per block, even with 1-entry queues (measured: depth 1/1 is still 205 clocks per KiB).
   - `tag_in_ready_o` and `tag_out_valid_o` also require `oc = 0`, so authentication waits for queued plaintext to drain.
   - `cmd_ready_o` is high in `F_IDLE`, including the clock in which `done_o` is shown. The buffered wrapper masks that clock, so the fold core accepts back-to-back commands one clock earlier.

8. **Provisional-plaintext contract.** It is the same as the buffered wrapper's:
   - plaintext is provisional until `commit_o`;
   - on a protocol error, both queues are cleared on the error edge, so `out_valid_o` is low from the `error_o` clock on, and `discard_o` pulses with `error_o` on decryption;
   - a bad tag gives `discard_o`;
   - reset clears everything;
   - every terminal path passes through `F_ZEROIZE`, which clears the state, key, flags and both queues. Simulation assertions check that at `F_DONE`, and also check that the state is zero while idle.

9. **Generic plumbing.** `ascon_aead128_core` has a new generic, `G_FOLDED_ABSORB` (default `false`).
   - `fold_g` is generated only when it is true. The existing `bypass_g` and `buffered_g` keep their labels and contents; only their conditions gained `and not G_FOLDED_ABSORB`.
   - An elaboration-time function asserts `G_BUFFERING_ENABLE and G_ROUNDS_PER_CYCLE = 3` when the fold is selected. Other R values are not supported: the 3+3+2 tail sharing is specific to R=3 (INFERRED: R=4 would need the absorb in series with 4 rounds).
   - `G_FULL_BLOCK_FAST_PATH` is ignored in fold mode, because masking is pre-decoded.

### 1.3 Did I get the full 3-clock fold, or did I fall back to the 4-clock variant?
The full fold, at **3 clocks per block (MEASURED)**. 4 clocks occur only when the source or sink is the bottleneck (fallback path). The 4-clock variant was not needed.

### 1.4 Standard conformance and one deliberate behavioural difference
SP 800-232 Ascon-AEAD128 throughout: IV `00001000808C0001`, 12/8/12 rounds, little-endian lanes, `0x01` padding, DSEP in bit 319, key XORs, and tag = S3‖S4 ⊕ K. Evidence: all 2,178 official KAT checks plus differential tests.

The difference: **AD framed as a full non-last beat followed by an empty last beat** (16·k AD bytes plus an explicit empty terminator).
- **MEASURED:** the existing u1, u3 and u3-buffered cores apply DSEP **without** the mandatory padded AD block. Their output does not match the SP 800-232 reference for that framing, in either direction.
- The same split framing on the **payload** is correct in all configurations.
- The fold core treats that empty AD beat as the padded empty block, which is standard, and matches the reference.
- The standard framing (last AD beat carries the last bytes) is unaffected; it is what the KATs and every runner use.
- Source: `run_traffic.py` scenarios `framing_*`; EV `traffic_results.json`, `framing_probe.txt`.
- I did not change the existing configurations, because the brief required bit-for-bit preservation. **Suggest a follow-up decision**: either reject that framing with `error_o`, or fix it in the engine.

---

## 2. Diff summary (uncommitted)

`git diff --stat` (tracked files) at the end of the study:
```
 .github/workflows/verify.yml           |  21 +
 Makefile                               |   7 +
 rtl/ascon_aead128_core.vhd             | 741 ++++++++++++++++++++++++++++++++-
 verification/cocotb/test_ascon.py      |  59 ++-
 verification/compare_stream.py         |  10 +-
 verification/run.py                    |   6 +-
 verification/simulate_adapter.py       |  10 +-
 verification/simulate_weight_file.py   |   8 +-
 verification/vhdl/tb_ascon_aead128.vhd |   4 +-
 verification/vhdl/tb_weight_file.vhd   |   6 +-
 vivado/route_stream.tcl                |   5 +-
 11 files changed, 850 insertions(+), 27 deletions(-)
```

New untracked files:
- `verification/cocotb/test_fold.py` (270 lines);
- `verification/cocotb/test_cycles.py` (139 lines);
- `docs/evidence/handoff_study_fold_20261021/`;
- this note.

`verification/vectors/LWC_AEAD_KAT_128_128.txt` was copied from the 3rpc worktree; it is gitignored and needed by `simulate_weight_file.py`.

- `rtl/ascon_aead128_core.vhd`:
  - new entity and architecture `ascon_aead128_fold` (lines ≈532–1211);
  - generic `G_FOLDED_ABSORB` and a configuration check (≈1230, 1275–1284);
  - `fold_g` generate (≈1286–1321);
  - two generate conditions extended (`bypass_g`, `buffered_g`).
  - `ascon_pkg.vhd` and `ascon_permutation.vhd` are unchanged.
- `verification/vhdl/tb_ascon_aead128.vhd`, `tb_weight_file.vhd`: pass-through generic `G_FOLDED_ABSORB` (default false).
- `verification/run.py`: `--folded`, which sets the generic and env `FOLDED`.
- `verification/cocotb/test_ascon.py`: buffered-aware fixes for the 3 tests (§3.3); the unbuffered behaviour and checks are unchanged.
- `verification/cocotb/test_fold.py` (new):
  - per-group intermediate-state checks of the fold core;
  - mid-stream error with queued plaintext;
  - back-to-back command acceptance in the done clock.
- `verification/cocotb/test_cycles.py` (new): cycle-count regression table for u1, u3, u3-buffered and u3-fold.
- `verification/compare_stream.py`, `simulate_weight_file.py`, `simulate_adapter.py`: `u3-fold` variant / `--folded` / `--candidate u3-fold`. The defaults are unchanged.
- `vivado/route_stream.tcl`: optional 7th argument `FOLDED`; omitted, the generics are exactly as before.
- `Makefile`: `vhdl-textio-fold-test`.
- `.github/workflows/verify.yml`: new or extended steps:
  - buffered `test_ascon` (the matrix entry that was missing);
  - fold KAT TextIO, `test_ascon`, `test_fold`, `test_stream` FULL_KAT=1 and depth 1/1;
  - cycle-regression step for 4 configurations;
  - fold GHDL-synth netlist with Icarus/Verilator `test_stream` and Verilator `test_cycles`.
- **Not run in GitHub Actions** (no push); every CI command was executed locally (§3).

---

## 3. Correctness (all MEASURED, final RTL)

All simulations used WSL system GHDL 1.0.0 (mcode, VHDL-2008) at a 10 ns clock. Tool versions are in §8.

### 3.1 Default-configuration preservation (bit-for-bit, cycle-for-cycle)
- **Netlist identity:** GHDL-synth Verilog netlists of u1, u3, u3-buffered and u3-buffered depth 1/1, from HEAD vs the modified sources, differ **only** in `/*# file:line:col */` source-location comments. There are 0 non-comment differing lines. Source: EV `netlist_identity.txt`.
- **Official KAT TextIO:** the per-case machine-readable records (outputs, tag, auth, **cycles** for all 2,178 checks) of u1, u3 and u3-buffered are **byte-identical** to the baseline study's runs. Source: EV `kat_textio_cycle_stats.txt`.
- **Traffic:** 117/117 rows for u1, u3 and u3-buffered (all scenarios of the baseline study) are identical in cycles, first in/out, last out, n_out, in/out stalls, auth, commit, discard and error. Source: EV `traffic_summary.txt`.
- **Weight runs:** 1 KiB 801/465/401 and full adapter (u1 1,798,305; u3-buffered 899,153) reproduce exactly.

### 3.2 Test matrix

| Check | u1 (default) | u3 | u3-buffered | **u3-fold** |
|---|---|---|---|---|
| Official KAT TextIO (1,089 vectors, 2,178 checks) | PASS 2178/2178 | PASS | PASS | **PASS 2178/2178** |
| `make vhdl-textio-fold-test` | – | – | – | **PASS 2178/2178** |
| cocotb `test_ascon` (10 tests; default subset) | 10/10 | 10/10 | **10/10** (was 7/10) | **10/10** |
| `test_ascon` FULL_KAT=1 (all 1,089 KATs, enc+dec) | – | – | – | **10/10** |
| `test_ascon`, FIFO depth 1/1 | – | – | 10/10 | **10/10** |
| `test_stream` FULL_KAT=1 (all KATs + 11 sizes × gaps/stalls + 4 tamper types + 6 malformed + reset with full queues) | – | PASS | PASS | **PASS** |
| `test_stream` depth 1/1 (FULL_KAT=0) | – | – | PASS | **PASS** |
| `test_stream` depth 3/3 (FULL_KAT=0) | – | – | – | **PASS** |
| `test_fold` (2 tests: per-group intermediate states over 56 AD×PT cases × enc/dec/bad-tag, random stalls; mid-stream error with queued plaintext) | – | – | – | **2/2** |
| `test_cycles` cycle-regression table | PASS | PASS | PASS | **PASS** |
| `run_permutation` (p1..p12 every group, 33 states) | PASS (R=1) | PASS (R=3) | (same entity) | n/a (no separate permutation; `test_fold` covers groups) |
| GHDL-synth netlist, Icarus: `test_stream` FULL_KAT=0 / `test_ascon` KAT_LIMIT=8 / `test_cycles` | `test_ascon` PASS | – | `test_stream` PASS | **all PASS** |
| GHDL-synth netlist, Verilator 5.053: `test_stream` / `test_cycles` | – | – | `test_stream` PASS | **both PASS** |
| `make` model-test, `test_adapter_export`, weight-file-test, board-selftest, board-demo-test (u3-buffered and u1) | PASS | | PASS | (board RTL copies with fold: self-test PASS 995 cycles vs 1,161; demo PASS 8/8, 198 vs 274 cycles) |

Sources: EV `cocotb_matrix.txt`, `netlist_tests.txt`, `make_targets.txt`, `kat_textio_cycle_stats.txt`, `board_fold_sim.txt`.

The `test_fold` monitor checked 2,340 three-round groups, 498 two-round tails, 336 p12 and 498 p8 permutations:
- every 3-round group was equal to three reference rounds with the expected constants;
- every 2-round tail was equal to two reference rounds plus changes confined to the rate, words 2–3 and bit 319;
- groups appeared in order;
- permutation counts were exact (p12 = 2 per transaction; p8 = padded AD blocks + full payload blocks);
- the initial state load was IV‖K‖N.

### 3.3 The three buffered `test_ascon` failures were test-timing assumptions, not RTL bugs
Reproduced before the fix: u3-buffered and u3-fold both fail the same three tests (EV `test_ascon_buffered_prefix_failures.txt`).

1. **`malformed_streams_report_error`.** `send_raw_beat` samples `error_o` exactly one clock after the handshake. That holds for the unbuffered engine, which only takes beats in `AD_WAIT`/`MSG_WAIT`. A queued core accepts the beat into the queue during p12 and reports the error when the beat reaches the head.
2. **`wrong_phase_and_held_extra_beats_are_rejected`.** Same cause: the held beat is accepted by the queue immediately, and the error follows later.
3. **`reset_clears_each_major_controller_phase`.** It asserts `in_ready_o` is low during AD p8. A queue legitimately keeps ready high.

Fix, applied only when env `BUFFERING=1` (set by `run.py --buffering`):
- wait up to 32 clocks for `error_o`, asserting no `commit_o` meanwhile, and check `discard_o` as before;
- in the AD-p8 reset probe, reset at every offset 0..15 clocks after the AD beat is queued. That is stronger than the original single point: it covers p12, the absorb clock and every AD group of both queued controllers.

The unbuffered path keeps the exact one-clock checks; u1 and u3 still pass 10/10. Measured error latencies are logged by the test (EV `test_ascon_error_latency.txt`).

### 3.4 Protocol and traffic scenarios
Bench `build/handoff_fold/scripts/tb_fold_traffic.vhd`: the baseline study's traffic bench plus `G_FOLDED_ABSORB`, FIFO-depth generics and event timestamps. All runs are checked against `ascon_ref`.

- **Coverage:** 31 scenarios × configurations, 248 directional rows. All 242 non-probe rows PASS. The 6 non-PASS rows are the existing configurations in the AD split-framing probe (§1.4).
- **Scenarios include:**
  - AD lengths 0/15/16/17/27/32;
  - partial final blocks (1, 17, 33, 40, 1000 B), empty payload;
  - source gaps 1/2, 1/4, 1/6, 1/8;
  - sink stalls 1/2, 1/4, 1/8, bursty 32/64, cocotb-style gaps+stalls;
  - FIFO depth 1/1 and 3/3;
  - late tag;
  - bad tag, ciphertext first-bit flip, ciphertext last-byte flip with stalls.
- **Tampering:** in every bad-tag or ciphertext-flip case, auth=1, auth_ok=0, **commit=0, discard=1**. The provisional plaintext equals the reference decryption of the tampered input.
- **Reset mid-stream:** `test_stream` (reset with both queues full under backpressure, then a clean transaction) and the 16-offset AD reset sweep plus per-phase resets in `test_ascon`. All pass.
- **Malformed streams:**
  - the 6 raw patterns in `test_stream`;
  - the `test_ascon` malformed and wrong-phase tests;
  - `test_fold` mid-stream error behind two queued plaintext beats with the sink stalled: `error_o` and `discard_o` in the same clock, `out_valid_o` low from that clock, no beat escapes, no commit, and the next command is clean.

### 3.5 Complete adapter, small-llama and 1 KiB (MEASURED)
Payload: `adapter_weights.bin`, SHA-256 `c184175f…98fff8eb`, 2,397,696 B, read-only. One AEAD message per direction, empty AD, public test key `bytes(range(16))`, a distinct nonce per independent encryption message.

| Workload | Config | Encrypt cycles | Decrypt cycles | Recovered SHA-256 | Ciphertext and tag vs reference / auth+commit | Nonce id |
|---|---|---:|---:|---|---|---|
| 1 KiB adapter prefix | u1 / u3 / u3-buffered / **u3-fold** | 801 / 465 / 401 / **205** | same | `322bbe55…` (all) | PASS | 5207435946358663000..003 |
| Adapter 2,397,696 B (149,856 blocks) | u1 | 1,798,305 | 1,798,305 | `c184175f…` | PASS | …660100 (earlier run on the v1 core file; default path unchanged) |
| | u3-buffered | 899,153 | 899,153 | `c184175f…` | PASS | …663100 |
| | **u3-fold** | **449,581** | **449,581** | `c184175f…` | PASS | …663101 |
| | baseline (origin/main) via `simulate_adapter.py` | 1,798,305 | 1,798,305 | `c184175f…` | PASS | …665001 |
| | **u3-fold via `simulate_adapter.py`** | **449,581** | **449,581** | `c184175f…` | PASS; report: speedup vs baseline 4.000×, −75.0 % | …665003 |
| Small-llama 1,641,984 B (102,624 blocks) | u1 | 1,231,521 | 1,231,521 | `d1c38f9b…` | PASS | …660200 (earlier run, v1 core file) |
| | u3-buffered | 615,761 | 615,761 | `d1c38f9b…` | PASS | …663200 |
| | **u3-fold** | **307,885** | **307,885** | `d1c38f9b…` | PASS | …663201 |

Source: EV `weight_file_runs.json` (per-row LF source SHA-256s), `adapter_sim_report.json`. The superseded first `simulate_adapter.py` run on the v1 core (`adapter_sim_report_v1_superseded.json`) gave the same cycles and SHA-256s.

- **Via the repository runner chain** `simulate_adapter.py --candidate u3-fold` (→ `compare_stream.py` → `simulate_weight_file.py --prepare-only` → WSL GHDL):
  - the RTL ciphertext and tag equal the Python reference;
  - the bench asserted authentication and commit;
  - recovered bytes equal the export;
  - **the checkpoint was reconstructed** (20-byte header of `adapter_params_00000200.bin` + recovered body) to SHA-256 `7c45c25b28ae54943c1fd4ee160001dcd9a68ee1f8430aee229f933545672de6`, equal to the target. The target is `7c45c25b…672de6`. Written only to `build/handoff_fold/adapter_sim_final/`.
  - Source: EV `adapter_sim_report.json`, `checkpoint_reconstruction.txt`.
- **1,641,984-byte small-llama payload:** recovered SHA-256 `d1c38f9b…0b594`.

---

## 4. Cycle measurements at a 10 ns simulated clock (MEASURED unless labelled)

Convention: offset 0 is the command clock; cycles is the offset at which `done_o` is visible (tb_weight_file / traffic-bench convention). Encrypt equals decrypt unless stated.

| Metric | u3-buffered (candidate) | **u3-fold** | Ratio |
|---|---:|---:|---:|
| Complete adapter, each direction | 899,153 | **449,581** | 2.000× |
| 1,641,984-B small-llama | 615,761 | **307,885** | 2.000× |
| 1 KiB adapter prefix | 401 | **205** | 1.956× |
| Steady-state interval (clocks per 16-B block; output handshakes) | 6 | **3** | 2× |
| Fixed per-message overhead (empty AD, full blocks) | 17 | **13** | |
| Minimum transaction (empty AD, empty PT) | 18 | **13** | |
| First-output latency (offset of first output handshake), empty AD / AD 27 B | 10 / 21 | **6 / 12** | |
| Tail, last output → tag (enc) / tag-in, commit (dec) / done, full final block | +10 / +10, +11 / +13 | **+7 / +7, +8 / +10** | |
| Tail, partial final block (pt1000) | +6 / +7 / +9 | **+4 / +5 / +7** | |
| Back-to-back command acceptance after `done_o` | 1 clock after | **same clock** | |
| Official KAT TextIO cycles (2,178 checks): min / max / mean | 18 / 45 / 30.182 | **13 / 28 / 19.182** | |

Source gaps and sink backpressure, 1 KiB, empty AD, existing pattern definitions:

| Pattern | u3-buffered cycles (in-stall / out-stall) | **u3-fold** cycles (in-stall / out-stall) | Note |
|---|---:|---:|---|
| Always ready | 401 (309 / 0) | **205 (123 / 0)** | fold is round-bound |
| Source 1/2 | 401 | **205** | still 3 clk/block |
| Source 1/4 | 401 | **271** | source-bound: 4 clk/block (fallback XOR-leg absorb exercised) |
| Source 1/6 | 405 | **401** | source-bound |
| Source 1/8 | 535 | **531** | source-bound |
| Sink 1/2 (dec) | 401 (– / 64) | **205 (– / 32)** | median interval 2, mean 3 |
| Sink 1/4 (dec) | 401 | **263** | sink-bound: 4 clk/block |
| Sink 1/8 (dec) | 523 | **515** | sink-bound |
| Bursty sink 32/64 | 547 enc / 524 dec | **367 / 367** | |
| cocotb gaps 2/5 + stalls 31/53, AD 27 | 581 | **406** | |
| Depth 1/1, always ready | 401 | **205** | 1-entry queues suffice |
| Depth 1/1, gaps+stalls, AD 27 | 723 enc / 693 dec | **458 / 432** | |
| Depth 3/3, bursty sink | 484 | **355 enc / 324 dec** | |

Full table: EV `traffic_summary.txt`.

**Model check.**
- Fold closed form, **MEASURED-validated**: `cycles = 13 + 3·(n_AD + ⌊PT/16⌋)` with `n_AD = ⌊AD/16⌋+1` for AD > 0 (0 otherwise), always-ready traffic. It reproduces every always-ready measured row exactly (EV `cycle_model_check.txt`: 132 rows, 0 mismatches, covering the existing-controller model as well).
- Against the baseline study's predictions for the adapter / 1 KiB:

| Scheme | Adapter | 1 KiB | Status |
|---|---:|---:|---|
| Measured candidate | 899,153 | 401 | MEASURED |
| P1+P2 (4 clk/block) | 599,442 | 274 | PREDICTED (not built) |
| P3 tail fold | 449,587 | 211 | PREDICTED |
| P3 + fixed fusions | 449,583 | 207 | PREDICTED |
| **u3-fold** | **449,581** | **205** | **MEASURED** (3N+13) |
| Floor (round clocks + command + tag) | 449,578 | 202 | PREDICTED |

The measured design is 2 clocks below the best prediction and 3 above the floor. The 3 extra clocks are the first absorb-only clock, `F_ZEROIZE` and `F_DONE`. The extra saving over the prediction comes from consuming the empty-AD beat during p12, applying the key XORs and DSEP with the first absorb, and dropping the tag-register clock.

---

## 5. Vivado 2023.2 core-only routed results (MEASURED)

Method: identical to the prior candidate runs (`vivado/route_stream.tcl`):
- in-memory project, xc7a100tcsg324-1;
- `synth_design -mode out_of_context` with maxThreads 1;
- `create_clock 10 ns` on `clk_i`;
- default `opt_design`, `place_design`, `route_design` with maxThreads 4;
- the only difference is generic `G_FOLDED_ABSORB=true` (7th argument).

Sources were snapshotted to `build/handoff_fold/vivado/src_v2/` (SHA-256 in §8); outputs are in `build/handoff_fold/vivado/fold_v2_p10/`. The path-class analysis was run on the routed DCP (`analyze_fold.tcl`). Another Vivado job (the timing study) ran on the machine at the same time; that only affects runtime, not results.

| | u3-buffered candidate (repo evidence `weight_stream_3rpc/u3-buffered`; reproduced by the timing study as `r3b1_p10_deep`) | **u3-fold (final RTL, `fold_v2_p10`)** | u3-fold v1 (superseded, `fold_p10`) |
|---|---:|---:|---:|
| Setup WNS / TNS at 10 ns | +0.038 / 0 | **+0.139 / 0** | +0.024 / 0 |
| Hold WHS | +0.144 | **+0.101** | +0.096 |
| Timing endpoints | 4,249 | 3,047 | 3,050 |
| Slice LUTs | 3,708 | **2,985 (−19.5 %)** | 3,125 |
| Registers (FF) | 1,680 | **1,085 (−35.4 %)** | 1,086 |
| F7 muxes | 0 | 320 (one per state bit: the final D-mux) | 319 |
| Worst setup path | `permutation_u/state_reg[50]` → `state_reg[13]`, 9.909 ns, 7 levels (6 round LUTs + LUT3 mux), 78 % route | **`s_reg[8]` → `s_reg[59]`, 9.841 ns, 7 levels (LUT5×4, LUT3×2, MUXF7), logic 1.881 / route 7.960 ns (80.9 %)** | `s_reg[58]` → `s_reg[236]`, 9.956 ns, 7 levels, 78 % route |
| Estimated Fmax, 1/(T − WNS) (INFERRED, not swept) | ≈100.4 MHz | ≈101.4 MHz | ≈100.2 MHz |

**Interpretation.**
- **The critical path is still the 3-round chain, with nothing new in series.**
  - All 320 state endpoints have their worst path through it: 319 at 7 levels, 1 at 6 (EV `vivado_fold_v2_p10/ana_state_endpoint_hist.txt`).
  - The 3-leg D-mux (3 rounds / tail+absorb / XOR leg) packs into one LUT plus a MUXF7 with no routed hop. In the candidate the corresponding mux was a separately routed LUT3.
  - Endpoint slack: 1 endpoint in [0, 0.25) ns, 21 in [0.25, 0.5), 67 in [0.5, 0.75), and 231 at ≥ 0.75 ns.
- **Path classes (MEASURED, EV `vivado_fold_v2_p10/ana_path_classes.txt`):**

  | Path class | Slack | Levels | Datapath |
  |---|---:|---:|---:|
  | state → state, rate bits | +0.139 ns | 7 | |
  | state → state, capacity bits | +0.279 ns | 7 | |
  | round-constant registers → state | +0.634 ns | 7 | |
  | control/flags → state (leg select / CE) | +0.955 ns | 5 | |
  | queue head → state (pre-decoded absorb operand) | +1.113 ns | 5 | |
  | queue counts → state | +1.113 ns | 5 | |
  | **state → output queue (2-round tail + ciphertext/plaintext tap)** | **+1.373 ns** | **6** | **8.574 ns** |
  | queue head → output queue | +2.360 ns | | |
  | state/key → status (tag compare) | +3.193 ns | 13 | |
  | key → state | +5.598 ns | | |

  The ≤6-level state → state paths are worst at +1.367 ns / 8.630 ns (`ana_leg_split.txt`).
- **The 2-round tail plus absorb and output tap has about 1.3–1.4 ns of slack.** The output-tap path is the same depth as the tail absorb leg (lanes 0–1, then one XOR/mask LUT, then the queue/D mux). The absorb therefore sits in the short group, as intended.
- **Compared with the candidate:**
  - its FIFO-head → keep-decode → absorb path was 8.98 ns, 7 levels (TIMING-STUDY, `routed_timing_unroll.md` §5);
  - its round-number → state path had +0.166 ns.
- **Timing-study harness agrees (TIMING-STUDY, `routed_timing_unroll.md` §5):** a stand-alone register with a separate tail datapath at 9 ns gives "through 2-round tail+absorb +0.589 ns (8.36 ns), through 3-round chain −0.560 ns".
- **Hold:** worst hold is the output-queue shift `oq[1]` → `oq[0]` (+0.101 ns, 1 LUT6).
- **Checks:** `check_timing` reports no unclocked registers and no unconstrained internal endpoints. Input and output ports are unconstrained, as in the prior out-of-context method.
- **Run-to-run variation:** v1 and v2 differ only in the registered `tag_gate` (output-port logic), yet WNS moved from +0.024 to +0.139 ns. Treat about ±0.1 ns as placement noise. Both meet 100 MHz.
- **Real throughput:** 100 MHz is met, so 16 B / (3 × 10 ns) = **533.3 MB/s (4.27 Gb/s)**, against 266.7 MB/s for the candidate at the same clock. The adapter takes **4.496 ms** per direction against 8.992 ms (candidate) and 17.983 ms (origin/main baseline).

---

## 6. Board-integrated implication (optional; no bitstream, no programming)

Method (MEASURED): `vivado/route_weight_board.tcl` copied to `build/handoff_fold/board/route_weight_board_nobit.tcl`, with only the `write_bitstream` step removed.
- **Same parts as before:** MMCM, two cores (self-test and demo), the demo controller and the ILA debug core.
- **RTL copies** (`build/handoff_fold/board/src_snapshot`): `ascon_weight_selftest.vhd` and `ascon_demo_top.vhd` with `G_FOLDED_ABSORB => true` added. Committed board RTL is untouched.
- **Simulation first:** both copies pass in GHDL. The self-test passes 18 cases in 995 cycles (candidate: 1,161); the demo passes 8 pairs in 198 cycles (candidate: 274).
- **No bitstream** was written and nothing was programmed.
- **First attempt failed for a tool reason.** Vivado's debug-hub generation refused a temporary path longer than 146 characters. Rerunning with `build/` as the working directory fixed it (EV `board_fold_route_div12/first_attempt_failed_pathlen.txt`).

| Board-integrated, both cores folded | Setup WNS | Hold WHS | LUT / FF | Worst path |
|---|---:|---:|---|---|
| **83.333 MHz** (CLOCK_DIVIDE 12) | **+0.785 ns** | +0.024 ns | 9,664 / 5,362 | self-test core `s_reg[37]` → `s_reg[275]`, 11.156 ns, 7 levels (6 LUT + MUXF7), 80 % route |
| **100 MHz** (CLOCK_DIVIDE 10) | **+0.181 ns** | +0.049 ns | 9,690 / 5,362 | self-test core `s_reg[192]` → `s_reg[20]`, 9.743 ns, 6 levels, 83 % route |
| Prior candidate board, 83.333 MHz (repo evidence `weight_stream_3rpc/board`) | +1.110 ns | +0.024 ns | 9,503 / 6,510 | – |
| Prior candidate board, 100 MHz (`weight_stream_3rpc/board-100-failed`) | **−0.130 ns (failed)** | +0.039 ns | – | – |

**Implication.**
- At the deployed 83.333 MHz the fold core closes with margin. At 3 clocks per block that is 16 B / 36 ns = **444 MB/s**, against 222 MB/s for the candidate at the same board clock.
- The adapter would take ≈5.40 ms per direction: 449,581 cycles × 12 ns (INFERRED from the simulated cycles).
- In this single run the folded board build also closed at 100 MHz, where the candidate's board build had failed. Given the ±0.1–0.5 ns placement noise the timing study measured, treat that as "possible", not "robust".
- Board timing is not hardware proof; nothing was programmed.

---

## 7. Negative results, limitations and open points

- **N1. Fold not generalized.** Only R=3 is supported. The elaboration check rejects other R values. R=4 "2 clk/block" would put the absorb in series with 4 rounds; not attempted.
- **N2. First version failed the board demo (found and fixed).** v1 gated `tag_out_o` with the combinational `fsm = F_TAG_OUT`. `ascon_demo_top` samples `tag_out_o` one clock **after** the tag handshake (state `UI_TAG_OUT`), relying on the engine's `tag_reg` surviving through `ST_ZEROIZE`. That is a consumer-side protocol dependence. The final RTL keeps an encryption tag visible for exactly that window (registered `tag_gate`). The first Vivado run (v1, `fold_p10`) used the old gating:
  - setup +0.024 ns, hold +0.096 ns;
  - 3,125 LUT / 1,086 FF;
  - same 7-level `s_reg → s_reg` worst path.
- **N3. Existing AD split-framing bug** (§1.4). Only reported; existing configurations unchanged.
- **N4. Timing margin.** The worst path is still the 3-round chain, essentially unchanged from the candidate. The slack is thin (tens of ps) and placement-sensitive, as it was for the candidate. Fmax gains need the timing study's chain-level work (retiming, Pblocks, different LUT mapping); the fold neither helps nor hurts that path.
- **N5. Pre-decode on the input-port side.** Keep/pad decoding now sits between `in_*` ports and queue registers. In the out-of-context run, input-port paths are unconstrained. A board integration drives these from registers; the board run (§6) closed at 83.333 and 100 MHz, so these paths were not limiting there. `rst_i` still feeds `in_ready_o`/`out_valid_o` combinationally, kept for parity with the buffered wrapper. The timing study identified that `rst_i` path as the 50 % I/O-budget failure (`routed_timing_unroll.md` §3). Removing it is a cheap follow-up.
- **N6. Fixed-cost floor.** 3 clocks above the round floor remain: the first absorb (could ride the last p12 group only by putting an XOR in series with 3 rounds, rejected), ZEROIZE and DONE (kept for the zeroization contract).
- **N7. GitHub Actions not executed.** The CI YAML was edited but not run on GitHub. Every command in it was run locally with equivalent tools, except two substitutions:
  - Verilator 5.053 (oss-cad-suite) instead of 5.036;
  - `ghdl synth` from oss-cad-suite GHDL 7.0.0-dev, used only for Verilog translation, because the system GHDL 1.0 mcode has no `--out=verilog`. All simulations used system GHDL.
- **N8. `simulate_weight_file.py` XSim path not run.** I did not run its Vivado XSim simulation path. All weight-file simulations are GHDL, via `compare_stream.py`/`run_weight_case.py`. Its `--prepare-only` path, which generates and checks the vectors, was exercised.
- **N9. Cross-check with the timing study (`routed_timing_unroll.md`, re-read before finalizing).**
  - Its §5 recommendations are what this core implements:
    - recommendation 1: absorb on the shared chain's short-group leg rather than a separate tail datapath, estimated to add no level to the 3-round path;
    - recommendation 3: pre-computed keep/error flags and a fixed (shift-register) queue head;
    - partly recommendation 4: `out_data_o` driven directly from the head register.
  - Its harness warned that a separate tail datapath costs about +0.7 ns on the 3-round path and about 1,090 LUTs. The shared-chain form measured here avoids both: the critical path is unchanged at 7 levels, and LUTs fell by 723.
  - Its `estimate` for the shared-chain form is now MEASURED.
  - Its §4 caveat applies to my numbers: WNS swings by ±0.25 ns across strategies and ±0.5 ns near the limit. Its Fmax sweep confirms the candidate at 9.25 ns. I did not run an Fmax sweep or strategy runs for the fold core; a 9.25–9.5 ns sweep is the obvious next Vivado step (≈533 MB/s at 10 ns, ≈577 MB/s if 9.25 ns closes).
  - Its source-integrity note records that eight of its runs elaborated my in-progress `ascon_aead128_core.vhd`. It reran them from pristine HEAD copies with identical results, which independently confirms that the default-off fold code does not change the existing configurations.
  - Not yet adopted: its recommendation 2, the static-lane-guard permutation (+0.36 ns for the candidate). That variant changes `ascon_permutation`, which the fold core does not use. The analogous change in the fold core would be registered one-hot lane enables, which it effectively already has: the `rc0..2` registers and a fixed-structure chain with no guards.

---

## 8. Reproduction

### Tool versions (EV `tool_versions.txt`)
- **Simulation:** GHDL 1.0.0 (Ubuntu 1.0.0+dfsg-6, mcode) for every simulation; cocotb 2.0.1 on WSL Python 3.10.12, from the read-only venv `worktrees/ascon-weight-stream-3rpc/build/linux-venv`. Ubuntu 22.04.5, WSL kernel 6.18.54.1.
- **Netlist simulations:** Icarus Verilog 11.0 and Verilator 5.053 (oss-cad-suite). GHDL 7.0.0-dev (oss-cad-suite) was used **only** for `ghdl synth --out=verilog`.
- **Implementation:** Vivado v2023.2 (win64) Build 4029153.
- **Driver:** Windows Python 3.11.9 for `simulate_adapter.py`/`compare_stream.py`, which call WSL GHDL.

### Key commands
Full list with nonces: EV `commands.txt`; scripts are copied in EV `scripts/`.

```text
# WSL (launched from PowerShell: wsl -d Ubuntu-22.04 -u kroix -- bash <script>)
build/handoff_fold/scripts/sync.sh                 # mirror RTL/verification to ~/ascon_fold_scratch, pinned KAT check
build/handoff_fold/scripts/final_regression.sh     # KAT TextIO x4, weight runs, traffic, cocotb matrix, netlists,
                                                   # make targets, netlist identity, board copies, full workloads
build/handoff_fold/scripts/framing_probe.sh        # AD-only vs payload-only split framing
build/handoff_fold/scripts/ascon_latency.sh        # test_ascon with error-latency logging

# In-repo equivalents (Linux/CI)
make vhdl-textio-fold-test
python verification/run.py --rounds-per-cycle 3 --buffering --folded --module test_ascon|test_fold|test_stream|test_cycles
python verification/run.py --rounds-per-cycle 3 --buffering --module test_ascon        # now passes
ghdl synth --std=08 --out=verilog -gG_ROUNDS_PER_CYCLE=3 -gG_BUFFERING_ENABLE=true -gG_FOLDED_ABSORB=true \
     rtl/ascon_pkg.vhd rtl/ascon_permutation.vhd rtl/ascon_aead128_core.vhd -e ascon_aead128_core > build/generated/folded.v

# Windows PowerShell, worktree as cwd (adapter via the repository runner chain)
python -I verification/simulate_adapter.py <adapter_weights.bin> --manifest <manifest.json> \
       --checkpoint <adapter_params_00000200.bin> --output build\handoff_fold\adapter_sim_final \
       --nonce-base 5207435946358665000 --candidate u3-fold

# Vivado core-only (cwd build\handoff_fold\vivado)
vivado.bat -mode batch -nojournal -source src_v2\route_stream.tcl -tclargs <abs>\fold_v2_p10 <abs>\src_v2 3 1 0 10 1
vivado.bat -mode batch -nojournal -source analyze_fold.tcl -tclargs <abs>\fold_v2_p10\routed.dcp <abs>\fold_v2_p10\ana
vivado.bat -mode batch -nojournal -source leg_split.tcl  -tclargs <abs>\fold_v2_p10\routed.dcp <abs>\fold_v2_p10\ana\leg_split.txt
```

### Source SHA-256
Working copy (CRLF) / LF-normalised; full list including scripts, payloads and snapshots in EV `source_and_artifact_sha256.txt`.

| File | Working copy | LF | HEAD 8b886c0 (LF) |
|---|---|---|---|
| `rtl/ascon_aead128_core.vhd` (final) | `f0a082b41b679c3a0022ec73c57605d9c36d94d6fbce3951bbf6559eba552d9f` | `1462e7f968567f83671bc95c892d8610803811366629245fbdce8308cc7da231` | `bd6480c31e1cc1235ade15801ace357e3f60872f6c0c0b9177dbb1abb19b811f` |
| `rtl/ascon_permutation.vhd` (unchanged) | `26ed449b…6227` | `8ca72f49…5e51` | same |
| `rtl/ascon_pkg.vhd` (unchanged) | `2de1555f…6630` | `b0b4c858…b47f` | same |

- **Vivado v2 snapshot** `build/handoff_fold/vivado/src_v2`: the core equals the final working copy (`f0a082b4…`), and `route_stream.tcl` is `f15c5547…1d99`.
- **v1 (superseded) core:** `8c2fa019…5bfc`.
- **Payloads and vectors:**
  - adapter `c184175f…8eb`;
  - checkpoint `7c45c25b…de6`;
  - small-llama `d1c38f9b…0b594`;
  - pinned KAT `bbbc3469…bd33`.

### Leftovers outside git
- `build/handoff_fold/` (gitignored) holds:
  - routed DCPs;
  - netlists (in WSL scratch);
  - the reconstructed checkpoint `build/handoff_fold/adapter_sim_final/u3-fold_reconstructed_checkpoint.bin`;
  - recovered weights;
  - board snapshots.
- The WSL scratch tree is `~/ascon_fold_scratch` (about 1–2 GB of run directories); delete it when no longer needed.
- `.Xil/` temporary directories may remain under `build/` from the board runs.
