# p8 pipelining experiment (one-round-per-clock Ascon-AEAD128)

Question: can additional or repositioned registers shorten the critical
paths enough that the diagram's 12-clock dependent p8 block interval
(A → O → L → r×8 → C) takes less **elapsed time** at a higher supported clock?

One message context, unchanged nonce semantics, no chunking, no extra cores,
no interleaving, no round unrolling.

## Isolation and provenance

* Worktree `worktrees/ascon-p8-pipeline`, branch `codex/ascon-p8-pipeline`,
  created from `main` at `3cceb3c5d3e610728a0876c18e5ebd8bd6af4aa0`
  (`origin/main` was rechecked and had not advanced). Every other checkout,
  including the dirty `codex/ascon-unroll-testing` checkout, was left as is.
  No unrolled, buffered-stream, folded-absorb or multicore code was used.
* The repository's `rtl/` is untouched and is candidate A. Candidates live
  in `rtl/<variant>/` here and replace only the files they change.
* `results/provenance.json`: base commit, SHA-256 of every RTL/bench/script
  file, Vivado `v2023.2 (SW Build 4029153)`, GHDL 1.0.0 (WSL Ubuntu 22.04),
  Python 3.11.9, part, constraints and implementation settings.
* KAT source: ascon-c `446347f2…` `LWC_AEAD_KAT_128_128.txt`
  (SHA-256 `bbbc3469…bd33`), copied from the main checkout and hash-checked.
* No repository AGENTS.md exists.

## Result

**Neither round pipelining variant improves latency. The improvement comes
from controller optimization, not from round pipelining.**

All latencies are routed timing × simulated cycles. None are board
measurements.

| Variant | What changes | Block interval | p8 cycles | Best passing period (strategy) | Next fail | Block latency | vs A best (70.8 ns) | Core LUT / FF |
|---|---|---|---|---|---|---|---|---|
| **A** | original one-round baseline | 12 | 8 | 5.90 ns, 169.5 MHz (explore) | 5.85 ns | 70.8 ns | 1.000× | 2369 / 1080 |
| **B** | two-stage round (+1 × 320-bit bank) | 20 | 16 | 6.20 ns, 161.3 MHz (default) | 6.15 ns | 124.0 ns | **0.571×** | 2381 / 1395 |
| **C** | three-stage round (+2 × 320-bit banks) | 28 | 24 | 6.35 ns, 157.5 MHz (default) | 6.30 ns | 177.8 ns | **0.398×** | 2562 / 1718 |
| **D** | B + A_ctrl2 control/locality changes | 20 | 16 | 4.30 ns, 232.6 MHz (explore) | 4.25 ns | 86.0 ns | **0.823×** | 2266 / 1407 |
| A_ctrl1 (control experiment) | A + per-lane keep decode | 12 | 8 | 4.70 ns, 212.8 MHz (default) | 4.65 ns | 56.4 ns | 1.255× | 2128 / 1075 |
| **A_ctrl2** (control experiment) | A_ctrl1 + one-hot controller + tree tag compare | 12 | 8 | **4.15 ns, 241.0 MHz** (explore) | 4.10 ns | **49.8 ns** | **1.422×** | 2271 / 1090 |

Break-even ratios: B and D needed more than 20/12 = 1.667× A's frequency
and C more than 28/12 = 2.333×. B achieved 0.97×, C 0.94×, and D 1.37×.

* **B and C are slower in elapsed time and in frequency.** Splitting the
  round shortened a path that was not limiting. In A the one-clock round has
  1.9 ns of slack at 5.9 ns. B's stages are one LUT level each (3.3 and
  2.7 ns), and C's are 2.4–2.5 ns each, so C's boundaries are already
  balanced and rebalancing would not help. The clock is set by the same
  6-level `in_keep` → `state_reg` enable path as A (≈1.2 ns logic, ≈4.7 ns
  routing, fanout 129). The intermediate banks add +315 and +638 FF.
* **D** was built on B because B had the lower measured block latency
  (124.0 vs 177.8 ns). With the control changes it reaches 232.6 MHz, but
  that is 1.37× A against the 1.667× it needed: 86.0 ns versus 70.8 ns. It
  is not a latency winner. D is also slightly slower than A_ctrl2, because
  the extra pipeline control adds load to the same fanout nets.
* **The control experiment on A is the actual win.** At unchanged cycle
  counts, A_ctrl2 runs 1.42× faster in elapsed time on every workload.
  A_ctrl1 provides most of the gain: 166.7 → 212.8 MHz at the default
  strategy. It removes the keep-count/validation logic from the 320-bit
  state and 128-bit output enables. A_ctrl2 adds the one-hot controller and
  a 5-level tag compare in place of the 13-level carry chain.
* **Implementation-setting sensitivity is small:**

  | Variant | default | explore | retime |
  |---|---|---|---|
  | A | 6.00 ns | 5.90 ns | 6.00 ns |
  | A_ctrl2 | 4.30 ns | 4.15 ns | 4.45 ns |
  | D | 4.50 ns | 4.30 ns | 4.55 ns |

  Retiming never helped, and on A it more than doubled the FF count.
  Architecture, not effort, explains the differences.
* **Remaining limits in A_ctrl2** are spread within about 0.5 ns:
  - tag compare → `auth_ok`/`discard` (5 levels)
  - one-hot state and `done` fanout (~130 pins) into the `state_reg` enable
  - the round itself, now only 0.48 ns from critical

  This is the point where a round split could start to matter. For a
  20-cycle D to beat A_ctrl2, every path would have to close below
  4.15 × 12/20 = 2.49 ns.
* Routing is 73–80% of every worst path. Clock skew is under 0.12 ns, and
  clock uncertainty is 0.035 ns in every run.

### Whole-message and first-output latency (unstalled, at each variant's best period)

| Workload (encrypt; decrypt identical) | A (5.90) | A_ctrl2 (4.15) | B (6.20) | C (6.35) | D (4.30) |
|---|---|---|---|---|---|
| AD 0, msg 0 B | 34 cyc / 200.6 ns | 34 / 141.1 | 58 / 359.6 | 82 / 520.7 | 58 / 249.4 |
| AD 0, msg 16 B | 45 / 265.5 | 45 / 186.8 | 77 / 477.4 | 109 / 692.15 | 77 / 331.1 |
| AD 0, msg 32 B | 57 / 336.3 | 57 / 236.6 | 97 / 601.4 | 137 / 869.95 | 97 / 417.1 |
| AD 0, msg 1 KiB | 801 / 4725.9 | 801 / 3324.2 | 1337 / 8289.4 | 1873 / 11893.55 | 1337 / 5749.1 |
| AD 0, msg 4 KiB | 3105 / 18319.5 | 3105 / 12885.8 | 5177 / 32097.4 | 7249 / 46031.15 | 5177 / 22261.1 |
| AD 16, msg 1 KiB | 821 / 4843.9 | 821 / 3407.2 | 1373 / 8512.6 | 1925 / 12223.75 | 1373 / 5903.9 |
| First `out_valid`, AD 0 | 17 / 100.3 | 17 / 70.6 | 29 / 179.8 | 41 / 260.35 | 29 / 124.7 |
| p8 compute (start → final state) | 8 / 47.2 | 8 / 33.2 | 16 / 99.2 | 24 / 152.4 | 16 / 68.8 |

These include the p12 initialization and finalization at each variant's
actual cost: 12, 24 or 36 round clocks. Stalled-interface cycle counts
(fixed-seed random gaps and stalls) are in `results/summary.md` and are
traffic-dependent, not architectural. For example, 1 KiB encrypt takes 851
cycles on A and 1,385 on B/D.

### Correctness

Every variant, including the unselected `D_alt_3stage`, passes all four
benches on the final sources:

| Bench | Result per variant |
|---|---|
| Official KAT | 2,178 / 2,178 directional checks |
| Per-round permutation | 400 / 400 (36 / 68 / 80 runs reset mid-permutation for 1 / 2 / 3 stages) |
| Streaming, unstalled | 520 / 520 transactions |
| Streaming, stalled | 520 / 520 transactions |

Logs are in `results/sim/<variant>/`.

### Timing coverage

All 12 reported best runs have setup, hold and pulse-width slack ≥ 0, zero
routing errors, zero DRC errors and zero DRC critical warnings. In every run,
`check_timing` reports 0 unclocked registers, 0 unconstrained internal
endpoints and 0 loops. The only unconstrained items are the BTNC input and
the LED output. Internal register-to-register timing is fully covered;
complete interface timing closure for a real system would need I/O delay
constraints for those two ports.

### After-measurement edits

After the sweeps, variant directories were renamed to the final A/B/C/D
scheme (`scripts/rename_variants.py`) and RTL header comments were
relabelled. `results/code_hashes_as_implemented.json` holds comment-stripped
hashes taken before the relabel. They match the final files, so the
measured logic is the shipped logic. The A_ctrl1 file also had a
comment-only header edit while its default sweep was running.

## Layout

| Path | Contents |
|---|---|
| `rtl/A_ctrl1/` | control experiment: per-lane keep decoding; validation no longer gates wide enables |
| `rtl/A_ctrl2/` | control experiment: A_ctrl1 + one-hot controller + tree tag compare |
| `rtl/B_2stage/` | B: baseline core + two-stage round engine |
| `rtl/C_3stage/` | C: baseline core + three-stage round engine |
| `rtl/D/` | D: A_ctrl2 core + two-stage round engine |
| `rtl/D_alt_3stage/` | A_ctrl2 core + three-stage engine (verified, not selected, not swept) |
| `bench/` | registered timing harness, pin XDC, simulation wrapper |
| `tb/` | per-round permutation bench, streaming protocol bench |
| `scripts/` | vector generation, simulation, implementation, sweep, analysis |
| `results/` | event logs, sweeps, per-run timing reports, summary |
| `SCHEDULE.md` | edge-by-edge schedules and label mapping |

## Reproduce

```bash
# functional (inside WSL/Linux with GHDL 1.0+; writes results/sim/<variant>/)
experiments/p8_pipeline/scripts/run_all_sims.sh
# routed sweep for one variant (Windows, Vivado 2023.2)
python experiments/p8_pipeline/scripts/sweep.py --variant A --rtl rtl --strategy default --start 6.0
# tables
python experiments/p8_pipeline/scripts/analyze.py
python experiments/p8_pipeline/scripts/provenance.py
```

## Verification method

All candidates are checked by the same four benches, against the repository's
independent Python model (`verification/model/ascon_ref.py`):

1. `verification/vhdl/tb_ascon_aead128.vhd`, the existing bench: all 1,089
   official vectors, encrypt and decrypt, 2,178 directional checks.
2. `tb/tb_perm_rounds.vhd`, with `G_CLOCKS_PER_ROUND` = 1 or 2: 400 fixed-seed
   permutations (p8 and p12, including all-zero and all-one states). It checks
   the state after **every completed round**, that `state_o` never shows a
   partial round, that `done` pulses exactly once on the final-state clock with
   `busy` falling, that `start` held high with a different state while busy is
   ignored, and that reset at a varying busy clock (every round phase)
   clears the engine and the vector then completes.
3. `tb/tb_core_pipeline.vhd`, unstalled: 520 transactions (bench workloads,
   AD and payload lengths 0/1/8/15/16/17/31/32/33/48, 300 random messages up
   to 200 B, 1 KiB and 4 KiB messages). Includes forged-tag rejections and
   reset injection at random points.
4. The same bench with `G_STALL = true`: random input gaps, output stalls,
   delayed tag acceptance and tag offer, and command requests while busy.

The core bench checks output data/keep/last, tags, auth_ok/commit/discard,
exactly one `done` per transaction after the tag, no `error`, output
stability during stalls, and that `out_data_o` is zero whenever
`out_valid_o` is low (plaintext is never visible outside a handshake).
After an injected reset it checks the core is idle, emitted nothing, and the
next transaction passes.

Fault check: running the two-stage engine with the bench told it is
one-clock-per-round fails at busy clock 1, so the per-round checks really
constrain the schedule.

## Timing method

* Part xc7a100tcsg324-1, Vivado 2023.2, non-project flow
  (`scripts/impl_one.tcl`). The only timing constraint is `create_clock` on
  `CLK100MHZ`, written per run so synthesis, placement and routing see the
  same target. **No false-path or multicycle exceptions.**
* Registered harness (`bench/ascon_bench_top.vhd`): every core input comes
  from a flip-flop and every output is folded into a 128-bit signature
  register driving one LED, so nothing is optimized away. 128-bit
  data/key/nonce/tag inputs reload from an LFSR every clock; the core samples
  them only on its handshakes. A simulation check (`scripts/check_harness.sh`)
  confirms the harness completes real transactions.
* A run passes only with WNS ≥ 0, WHS ≥ 0, pulse-width slack ≥ 0, zero routing
  errors and zero DRC errors.
* Sweep (`scripts/sweep.py`): 0.5 ns bracket, then 0.1 ns, then 0.05 ns
  (declared resolution). Reported: shortest passing tested period, and the next
  shorter tested period that failed. Every point is kept.
* Timing coverage: `check_timing` lists only `BTNC` (asynchronous button into a
  2-flop synchronizer) and `LED[0]` as unconstrained I/O. All core and
  harness register-to-register paths are constrained.
* The harness was revised once. Its first version loaded the 128-bit data
  registers only on handshakes, and that harness-side fan-out was the
  second-worst path. Those runs are archived in `results/archive_harness_v1/`
  and are not used in any comparison.

## Board note

Nothing here was programmed or measured on hardware. A board test of a
faster clock must generate it with an MMCM/PLL from the 100 MHz oscillator
(legal VCO 600–1200 MHz for -1 parts), constrain the generated clock (Vivado
derives it from the MMCM), and hold the design in reset until `LOCKED` is
high, synchronized into the new domain. Editing `create_clock` alone does not
change the physical clock.
