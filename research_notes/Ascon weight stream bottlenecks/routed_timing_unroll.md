> Publication update October 21, 2026: current branch `ascon-weight-stream-fold-absorb`. This is a dated working note. The later AD-padding and decryption-tag-output fixes are complete. Legacy bit-for-bit preservation claims below apply only to the pre-fix snapshot. Final status is in [the report](../../reports/Ascon%20weight%20stream%20bottlenecks.md) and [the fix note](../../docs/ad_padding_fix.md). No physical fold throughput is claimed.

# Routed timing, critical paths and area of the Ascon-AEAD128 core vs. unroll factor (Artix-7 xc7a100tcsg324-1)

Scope and labels used below:
- **[core-only]**: out-of-context (OOC) synthesis and implementation of `ascon_aead128_core`, Vivado 2023.2, one `create_clock` on `clk_i`, external I/O unconstrained unless stated. This is the same flow as the committed `vivado/route_stream.tcl`.
- **[board]**: the board-integrated design (two cores, demo, self-test, ILA, MMCM). These are prior committed results. I did not rerun them.
- **[sim]**: cycle counts measured in earlier simulations (committed evidence).
- **[model]**: cycle counts I derived from the controller FSM. They are not simulated.
- **[variant]**: timing-only experiments on RTL copies kept in `build/`. The committed RTL was not modified.

All runs used worktree commit `8b886c075241d4f599f0a299f114b5fae133291e` with no modifications under `rtl/` or `vivado/`. After LF normalisation, the source SHA-256 values match the committed receipt (pkg `b0b4c858…`, permutation `8ca72f49…`, core `bd6480c3…`). The Windows checkout has CRLF line endings: raw core hash `ae68ab43…`, raw permutation hash `26ed449b…`. See [source_sha256.txt](../../docs/evidence/handoff_study_timing_20261021/source_sha256.txt).

**Quick reference for the folded-absorb implementer** (details and sources in sections 1 and 5):
- **Current candidate worst path:** perm `state_reg` → perm `state_reg`, 7 LUT levels, 9.9 ns at 10 ns (78 % routing). Each round is two LUTs: an S-box LUT5, then a linear-layer LUT5 that is also a lane-bypass mux driven by a fanout-327 enable. A final LUT3 `busy ? round : state_i` load mux follows.
- **2-round tail + absorb (harness, same placement pressure):** 2 rounds + rate XOR + decrypt select + load mux = 5 levels, 8.36 ns. The 3-round group is 7 levels, 9.51 ns. So the tail has about 1.1 ns of spare depth.
- **Where to put the absorb:** on lane 2's bypass input in the shared chain. A separate tail datapath widened the final mux and cost the 3-round path about +0.7 ns (9.56 vs 8.80 ns) and about 1,090 LUTs.
- **Robust core-only period today:** 9.25–9.5 ns (met). The +0.038 ns at 10 ns is within the ±0.25–0.5 ns tool noise.

**Source-integrity note (2026-10-21, 14:51).** A parallel agent edited `rtl/ascon_aead128_core.vhd` in this shared worktree without committing it. The edit adds `G_FOLDED_ABSORB` and an `ascon_aead128_fold` entity, both default-off. Eight of my runs started after that edit, and the synthesis log shows they elaborated the edited file: `f_r3b0_p9.75`, `f_r3b1_p9.25`, `f_r3b1_p9.5_explore`, `f_r4b0_p13.5`, `f_r4b1_p13`, `f_r6b1_p23`, `io_r3b0_30pct` and `io_r3b1_50pct`. Their logs read `ascon_aead128_core.vhd:1264/1273` instead of `:586`.

I reran all eight as `<run>_head`, from pristine `git show HEAD:` copies in `build/handoff_vivado/rtl_head_root/rtl/` (LF hashes `b0b4c858…`/`8ca72f49…`/`bd6480c3…`). All eight logs read line 586, and every result was identical to the original run, to the picosecond and to the LUT/FF count:
- 3-round + FIFO at 9.25 ns: +0.042 ns, 3,889 LUT, 1,680 FF.
- 3-round + FIFO at 9.5 ns with Explore: +0.043 ns.
- 3-round, no FIFO, at 9.75 ns: +0.018 ns.
- 4-round + FIFO at 13 ns: +0.056 ns.
- 4-round, no FIFO, at 13.5 ns: +0.002 ns.
- 6-round + FIFO at 23 ns: +3.325 ns.
- I/O runs: +0.002 ns (unbuffered, 30 %) and −2.105 ns (buffered, 50 %).

So the default-off fold code does not change the default configurations. Every other run used the unmodified committed RTL. Per-run provenance is the `core_rtl_source` field in [all_runs_implementation.json](../../docs/evidence/handoff_study_timing_20261021/all_runs_implementation.json).

Evidence (small text excerpts, scripts and job lists): `docs/evidence/handoff_study_timing_20261021/`. Full builds and checkpoints: `build/handoff_vivado/<run>/`. Run names: `r<R>b<buffered>_p<period>`. The `f_` prefix marks a tight-target Fmax run, `s_` a strategy run, `io_` an I/O-constraint run, `v1_` the variant permutation, and `h_` the synthetic harness.

Paths in this file are relative to the worktree root.

## 1. Does the buffered 3-round candidate reproduce +0.038 ns at 100 MHz, and what are its worst paths?

### Takeaway
Yes, exactly. The candidate gave setup +0.038 ns, hold +0.144 ns, 3,708 LUT and 1,680 FF, both with the committed `route_stream.tcl` and with my parameterised copy. The worst paths are almost all round-datapath paths inside `permutation_u`, from `state_reg` to `state_reg`. Each has 7 LUT levels: three rounds of two levels each (S-box LUT, then a linear-layer LUT that is also a lane-bypass mux) plus a final load mux. About 78–80 % of the delay is routing. The slack profile is a flat wall: 164 of the 320 permutation endpoints are within 0.75 ns of failing.

### Cited Findings
- **Reproduction [core-only].** Rerunning the committed `vivado/route_stream.tcl` with args `3 1 0 10` gave `{"setup_slack_ns": 0.038, "hold_slack_ns": 0.144}`. That matches the committed evidence (+0.038/+0.144, 3,708 LUT, 1,680 FF). My `impl_core.tcl` (same flow) gave the same numbers. Two identical-input runs were bit-identical, so the default flow is deterministic. — [route_stream_repro/implementation.json](../../docs/evidence/handoff_study_timing_20261021/candidate_r3b1_100mhz/route_stream_repro/implementation.json); [candidate implementation.json](../../docs/evidence/handoff_study_timing_20261021/candidate_r3b1_100mhz/implementation.json); [prior report.json](../../docs/evidence/weight_stream_3rpc/report.json)
- **Other prior core-only results also reproduce.** Unbuffered 3-round at 10 ns: +0.125 ns, 3,192 LUT, 1,088 FF, identical to the prior "u3" entry. The prior "baseline" (+2.914 ns, 1,894 LUT, 1,081 FF) was built from the older origin/main RTL. With the current RTL and `G_ROUNDS_PER_CYCLE=1` I get +2.646 ns, 1,843 LUT, 1,086 FF at 10 ns. — [all_runs_summary.txt](../../docs/evidence/handoff_study_timing_20261021/all_runs_summary.txt); [report.json](../../docs/evidence/weight_stream_3rpc/report.json)
- **Worst path at 10 ns.**
  - Endpoints: `buffered_g.engine_u/permutation_u/state_reg_reg[50]/C` to `state_reg_reg[13]/D`.
  - Data path 9.909 ns: logic 2.152 ns (21.7 %), route 7.757 ns (78.3 %).
  - 7 levels: LUT3×1, LUT4×1, LUT5×5.
  - Clock skew −0.049 ns, uncertainty 0.035 ns.
  - Source: [setup_paths.txt](../../docs/evidence/handoff_study_timing_20261021/candidate_r3b1_100mhz/setup_paths.txt)
- **Top 200 setup paths (one worst path per endpoint, `-nworst 1`).**
  - Slack range: 0.038 to 0.819 ns. All 200 paths have 7 logic levels.
  - 176 run from `permutation_u/state_reg` to `permutation_u/state_reg`.
  - 20 run from `permutation_u/round_number_reg` to `state_reg`.
  - 4 run from FIFO entries `iq_reg[*][keep]` to the engine `state_reg`.
  - Mean split: logic 1.89 ns, route 7.51 ns (route ≈ 80 %).
  - Source: [top200_endpoint_summary.txt](../../docs/evidence/handoff_study_timing_20261021/candidate_r3b1_100mhz/top200_endpoint_summary.txt)
- **Logic-level distribution of the worst 1,000 paths:** 821 paths at 7 levels, 50 at 3, 78 at 2, 51 at 1. — [logic_level_distribution.txt](../../docs/evidence/handoff_study_timing_20261021/candidate_r3b1_100mhz/logic_level_distribution.txt)
- **Slack spread across the 320 permutation `state_reg` D endpoints:**

  | Slack bucket (ns) | Endpoints |
  |---|---:|
  | 0.00–0.25 | 12 |
  | 0.25–0.50 | 50 |
  | 0.50–0.75 | 102 |
  | 0.75–1.00 | 87 |
  | 1.00–1.25 | 54 |
  | 1.25–1.50 | 12 |
  | 1.50–1.75 | 3 |

  Source: [perm_endpoint_hist.txt](../../docs/evidence/handoff_study_timing_20261021/candidate_r3b1_100mhz/perm_endpoint_hist.txt)
- **Which RTL constructs sit on the worst path.** I read the LUT INIT values and input nets from the routed netlist.

  | Level | Cell | Function (from INIT and inputs) |
  |---|---|---|
  | 1 | LUT5 `BE4141BE` | Ascon S-box column. Inputs are bit 50 of all five words (`perm_state_out[50/114/178/242/306]`). |
  | 2 | LUT5 `9696FF00` | `en ? XOR3(linear diffusion) : bypass`. The enable is net `round_constant[…]_i_3` (fanout 327). |
  | 3 | LUT4 | Round-2 S-box. |
  | 4 | LUT5 `6969FF00` | Lane-1 linear layer plus bypass. Enable `_i_4`, fanout 327. |
  | 5 | LUT5 | Round-3 S-box. |
  | 6 | LUT5 `96FF9600` | Lane-2 linear layer plus bypass. Enable `_i_2`, fanout 327. |
  | 7 | LUT3 `B8` | `busy ? round_result : state_i`, the permutation load mux. `busy_reg_reg_rep` has fanout 110. |

  Source: [critical_path_lut_inputs.txt](../../docs/evidence/handoff_study_timing_20261021/candidate_r3b1_100mhz/critical_path_lut_inputs.txt)
- **Why every lane has a bypass mux.** The three fanout-327 "round_constant" nets are really the per-lane guard `round_number_reg + lane <= final_round_reg`. That guard is synthesised for every lane because `final_round_reg` is a register (reset to 0, loaded with 11), not a constant. So lanes 0 and 1 also get bypass muxes, even though only lane 2 can ever be skipped (p8 = 3+3+2). — [rtl/ascon_permutation.vhd](../../rtl/ascon_permutation.vhd) lines 35, 62–79
- **Path classes at 10 ns [core-only, candidate].** Slack in ns (L = logic levels).

  | Path class | Slack | Levels | Notes |
  |---|---:|---:|---|
  | `perm.state → perm.state` | 0.038 | 7 | Round datapath. |
  | `round_number → perm.state` | 0.166 | 7 | Lane-enable decode net routes 1.48 ns. |
  | FIFO head `iq_reg[*][keep]` → engine `state_reg` CE | 0.765 | 7 | 8.98 ns datapath. Goes through keep-contiguity and error decode, then a 128-load CE net (2.19 ns). |
  | FIFO → `out_data_reg` | 1.221 | 7 | |
  | `controller_state_reg[4]` → `key_reg` | 1.178 | 1 | 8.04 ns of routing on a fanout-130 net. |
  | Absorb (engine state → engine state) | 6.577 | — | |
  | Engine state → perm load | 7.191 | — | |
  | Perm → engine write-back | 5.996 | — | |

  Source: [path_classes.txt](../../docs/evidence/handoff_study_timing_20261021/candidate_r3b1_100mhz/path_classes.txt)
- **High-fanout nets.**

  | Net | Fanout | Worst slack (ns) | Notes |
  |---|---:|---:|---|
  | `rst_i` | 753 | — | Synchronous reset. |
  | FIFO clear enable | 599 | — | |
  | `perm_reset` | 333 | — | |
  | Lane-enable decodes (×3) | 326 each | 0.166 / 1.612 / 3.244 | |
  | `controller_state[1]` | 325 | — | |
  | Perm `state_reg` CE | 320 | — | |
  | `controller_state[4]` | 130 | — | 8.04 ns worst delay. |
  | `out_valid_reg` CE | 129 | — | |

  Source: [high_fanout.txt](../../docs/evidence/handoff_study_timing_20261021/candidate_r3b1_100mhz/high_fanout.txt)
- **Hierarchical utilisation (LUT / FF).** No placer or router congestion windows at level 5 or above, and `report_qor_suggestions` returned nothing because the design meets timing.

  | Block | LUT | FF | Notes |
  |---|---:|---:|---|
  | Top total | 3,708 | 1,680 | |
  | FIFO wrapper | 73 | 601 | |
  | Engine | 1,044 | 746 | |
  | Permutation | 2,594 | 333 | |
  | LUT cells (`get_cells`) | 4,816 | — | 4,816 LUT cells packed into 3,708 slice LUTs, i.e. many LUT6_2 pairs. |

  Sources: [utilization_hier.txt](../../docs/evidence/handoff_study_timing_20261021/candidate_r3b1_100mhz/utilization_hier.txt); [design_analysis_congestion.txt](../../docs/evidence/handoff_study_timing_20261021/candidate_r3b1_100mhz/design_analysis_congestion.txt); [qor_suggestions.txt](../../docs/evidence/handoff_study_timing_20261021/candidate_r3b1_100mhz/qor_suggestions.txt)
- **[board] comparison.**
  - The failed 100 MHz board trial (−0.130 ns) had the same kind of worst path: `demo_u/core_u/…/permutation_u/state_reg[222]→[59]`, 7 levels (LUT3=1, LUT5=6), 9.961 ns data path, route 80.8 %, MMCM clock uncertainty 0.074 ns.
  - The 83.333 MHz board route (+1.110 ns) again ends on `permutation_u/state_reg`, with a looser 10.755 ns data path.
  - Sources: [board-100-failed/setup_paths.txt](../../docs/evidence/weight_stream_3rpc/board-100-failed/setup_paths.txt); [board/timing.txt](../../docs/evidence/weight_stream_3rpc/board/timing.txt)

### Inferences
- The candidate is limited by the 3-round iterative feedback loop itself, not by FIFO muxes or absorb logic. Those paths have 0.8–7 ns of slack at 100 MHz.
- About 1 ns of routing per level is inherent here. The ρ rotations (1, 6, 7, 10, 17, 19, 28, 39, 41, 61) spread every 3-round input cone over most of the 320-bit state, so placement cannot keep each cone local. This matches the route share of roughly 80 %.
- With 164 endpoints inside 0.75 ns, local fixes such as replicating one net or Pblocking one path will not move WNS much. Each LUT level removed from all lanes is worth roughly 0.9–1.3 ns.
- The board trial shows that MMCM jitter (0.074 vs 0.035 ns uncertainty) plus a larger, shared placement is enough to erase the 38 ps core-only margin. Core-only +0.038 ns should not be read as evidence that 100 MHz will close on the board.

### Gaps
- `report_qor_suggestions` gives nothing on a passing design. I did not rerun it on a failing (9.0 ns) checkpoint.
- No Pblock or floorplan experiment was run.

## 2. Achievable Fmax and throughput for 1, 2, 3, 4 and 6 rounds per cycle, with and without FIFOs

### Takeaway
**[core-only]** confirmed met periods (a run at that target with WNS ≥ 0):

| Rounds per cycle | FIFOs | Confirmed period (ns) | Fmax (MHz) |
|---:|---|---:|---:|
| 1 | off | 5.0 | 200 |
| 1 | on | 7.0 | 143 |
| 2 | off | 7.0 | 143 |
| 2 | on | 7.0 | 143 |
| 3 | off | 9.75 | 103 |
| 3 | on | 9.25 | 108 |
| 4 | off | 13.5 | 74 |
| 4 | on | 13.0 | 77 |
| 6 | on | 23 | 43.5 |

Six rounds per cycle without FIFOs was not confirmed (estimate ≈ 22.9 ns).

Using clocks per block (12/11/8/7/7/6/6/5/6/5, see the table below), the best steady-state throughput is **2 rounds/cycle with FIFOs: about 326 MB/s [model cycles]**. The 3-round candidate gives 288 MB/s [sim cycles] and 1 round without FIFOs gives 267 MB/s [sim cycles]. 4 and 6 rounds per cycle are worse because their clock period grows faster than their cycle count falls.

### Cited Findings
- **Supported generics.** `G_ROUNDS_PER_CYCLE : positive range 1 to 12`. The permutation runs `rounds_this_cycle` lanes per cycle with a per-lane guard.
  - R=4 gives p8 = 4+4 and p12 = 4+4+4.
  - R=6 gives p8 = 6+2 and p12 = 6+6.
  - R=2 gives p8 = 2×4 and p12 = 2×6.
  - Buffering (`G_BUFFERING_ENABLE`, FIFO depth 2) is available for every R and enables `G_OVERLAP_OUTPUT`.
  - Sources: [rtl/ascon_aead128_core.vhd](../../rtl/ascon_aead128_core.vhd) lines 537–544 and 683–686; [rtl/ascon_permutation.vhd](../../rtl/ascon_permutation.vhd) lines 17–20 and 74–87
- **Cycle model [model, checked against sim].** Clocks per full 16-byte message block:
  - Unbuffered: ⌈8/R⌉ + 4 (MSG_WAIT, MSG_OUTPUT, PERM_START, then ⌈8/R⌉ busy cycles plus one done/copy-back cycle).
  - Buffered with output overlap: ⌈8/R⌉ + 3.
  - This gives 12, 7 and 6 for R=1 unbuffered, R=3 unbuffered and R=3 buffered. Those values match the simulated block intervals of [12, 12], [7, 7] and [6, 6], and the full-file averages of 12.0003, 7.0002 and 6.0002.
  - Every other value in the table below is a model estimate.
  - Sources: [traffic_metrics.json](../../docs/evidence/weight_stream_3rpc/traffic_metrics.json); [report.json](../../docs/evidence/weight_stream_3rpc/report.json); [rtl/ascon_aead128_core.vhd](../../rtl/ascon_aead128_core.vhd) lines 341–432
- **Fmax sweep [core-only].** "Tight run" is target → achieved (target − WNS). "Confirmed" is the smallest target that met. Throughput = 16 B / (clocks × confirmed period).

  | R | FIFO | Tight run (ns) | Confirmed (ns), WNS | Fmax (MHz) | Clocks/block | MB/s | LUT / FF at confirmed run | Limiting path at tight target |
  |---|---|---|---|---|---|---|---|---|
  | 1 | off | 4.5 → 4.695 | 5.0, +0.248 | 200 | 12 [sim] | 266.7 | 1,843 / 1,086 | Controller state → out_data / perm CE (3–4 levels, control fanout). The round path has 1.24 ns slack at 5 ns. |
  | 1 | on | 5.0 → 7.570 | 7.0, +0.043 | 143 | 11 [model] | 207.8 | 2,472 / 1,678 | FIFO head keep → engine CE/out_data (7 levels). |
  | 2 | off | 6.5 → 6.741; 6.75 → 6.780 | 7.0, +0.011 | 143 | 8 [model] | 285.7 | 2,681 / 1,086 | round_number → perm state (6 levels) and the round datapath. |
  | 2 | on | 7.5 → 7.252 | 7.0, +0.118 | 143 | 7 [model] | 326.5 | 3,456 / 1,679 | Round path and FIFO path both within 0.5 ns (FIFO path 0.447 ns slack at 7.5). |
  | 3 | off | 9.0 → 9.527; 9.5 → 9.573 | 9.75, +0.018 | 102.6 | 7 [sim] | 234.4 | 3,318 / 1,088 | Round datapath (7 levels). |
  | 3 | on | 9.0 → 9.505 | 9.25, +0.042 (9.5 also met, +0.040) | 108.1 | 6 [sim] | 288.3 | 3,889 / 1,680 | Round datapath. FIFO→CE was −0.152 at the 9.0 target. |
  | 4 | off | 12 → 12.84; 13 → 13.367 | 13.5, +0.002 | 74.1 | 6 [model] | 197.5 | 3,637 / 1,091 | Round datapath (9 levels). |
  | 4 | on | 12 → 12.479; 12.5 → 12.807 | 13.0, +0.056 | 76.9 | 5 [model] | 246.2 | 4,519 / 1,680 | Round datapath (9 levels). |
  | 6 | off | 10 → 23.83; 18 → 22.874 | not confirmed (estimate ≈ 22.9) | ≈ 43.7 (est.) | 6 [model] | ≈ 116 (est.) | 4,711 / 1,088 at 18 ns | 13 levels. |
  | 6 | on | 18 → 22.342 | 23.0, +3.325 (achieved 19.675) | 43.5 confirmed (≈ 50.8 achieved) | 5 [model] | 139.1 at 23 ns | 5,270 / 1,684 | 13 levels. |

  Sources: [all_runs_summary.txt](../../docs/evidence/handoff_study_timing_20261021/all_runs_summary.txt); [all_runs_implementation.json](../../docs/evidence/handoff_study_timing_20261021/all_runs_implementation.json); [fmax_paths/](../../docs/evidence/handoff_study_timing_20261021/fmax_paths/)
- **10 ns runs used to seed the sweep** (core-only, WNS in ns):

  | Config | WNS at 10 ns | Worst path |
  |---|---:|---|
  | R=1 off | +2.646 | Control path. |
  | R=1 on | +0.610 | FIFO keep → CE. |
  | R=2 off | +1.764 | `busy_reg` → `state_reg`: one LUT with 7.54 ns of routing on a fanout-332 net. |
  | R=2 on | +0.751 | FIFO path. |
  | R=3 off | +0.125 | Round path. |
  | R=3 on | +0.038 | Round path. |
  | R=4 on | −2.164 | Round path. |
  | R=6 off | −13.831 | Round path. |
  | R=6 on | −9.804 | Round path. |

  Period − WNS at 10 ns is a poor Fmax estimate for loose configurations. Vivado does not replicate or optimise once timing is met, so lightly loaded designs show unrepaired fanout nets. — [all_runs_summary.txt](../../docs/evidence/handoff_study_timing_20261021/all_runs_summary.txt)
- **Levels per R.** The round path is 2·R LUT levels plus 1 for the load mux: R=1 gives 3 (not critical), R=2 gives 5–6, R=3 gives 7, R=4 gives 9, R=6 gives 13. These are observed worst-path levels. — [all_runs_summary.txt](../../docs/evidence/handoff_study_timing_20261021/all_runs_summary.txt)

### Inferences
- **Delay per LUT level.** In routed delay, each round costs about 2.5–3.2 ns. A 3-round group (7 levels) needs about 9.2–9.5 ns, R=4 (9 levels) about 13 ns, and R=6 (13 levels) about 20–23 ns. The per-level delay grows with R, from about 1.35 ns at R=3 to about 1.5–1.7 ns at R=6, because longer cones spread further.
- **R=6 is dominated.** It needs the same 2 permutation cycles per p8 as R=4, with a much longer period. Only p12 (init and final) gets shorter.
- **R=2 with FIFOs is the best measured throughput option** today (about 326 MB/s at 7.0 ns, 7 clocks [model], 3,456 LUT). It is about 13 % above the 3-round candidate at its best confirmed 9.25 ns, and about 22 % above it at 100 MHz.
  - It needs a 143 MHz clock in the system, which is harder on the board. The [board] design already closes the candidate only at 83.333 MHz.
  - At the board's 83.333 MHz the ranking flips: 3-round + FIFO gives 222 MB/s and 2-round + FIFO gives 190 MB/s, because only cycles count.
- **R=1 without FIFOs at 200 MHz** matches the candidate's throughput with half the LUTs. That is a core-only number; a 200 MHz board clock with these unregistered ports is unrealistic.
- **The candidate itself:** 108 MHz is reachable core-only (9.25 ns met, +0.042). But the 9.0 ns target produced 9.505 ns, so results are not monotonic in the target. Treat about 105 MHz as the robust core-only number and 100 MHz as the practical ceiling once board uncertainty is added.

### Gaps
- Clocks per block for R=2, 4 and 6 and for R=1 with FIFOs are not simulated. They are FSM-derived [model].
- R=6 without FIFOs was not run at a relaxed (about 23 ns) target.
- No [board] runs were made for any configuration other than the committed 3-round + FIFO one.
- Throughput excludes per-message overhead: 17 cycles for 3-round, 33 for 1-round [sim].

## 3. Do external I/O constraints change the picture, and what is a realistic core-only constraint set?

### Takeaway
At a 30 % I/O budget (3 ns input and output delay at 10 ns) the candidate still closes, at +0.170 ns. Ports are not limiting, but some are close.

At 50 % (5/5 ns) the design fails by −2.105 ns. The cause is the combinational port-to-port path `rst_i → in_ready_o`. Register-to-register slack also degraded to −0.348 ns.

The unbuffered 3-round core is worse at 30 %: input `in_keep_i` → engine `state_reg` CE has 7 levels and only +0.209 ns slack. In the unbuffered variant, the absorb control path starts directly at the ports.

### Cited Findings
- **[core-only] candidate at 10 ns, by I/O delay.**

  | Input / output delay | Overall | Main finding |
  |---|---|---|
  | 0 / 0 ns | Setup +0.140; hold **−0.317** | 1,171 hold failures, e.g. `key_i[124] → key_reg[124]`. This is an OOC artefact of a 0 ns minimum input delay with a 0.97 ns clock-insertion delay. |
  | 3 / 3 ns | **+0.170** | Port paths: input→reg +1.676 (`rst_i →` 5 levels → perm CE); reg→output **+0.197** (`orp_reg[0]_rep → out_data_o`, 1 LUT and 5.13 ns route, the FIFO read mux); in→out +1.895 (`rst_i → in_ready_o`). |
  | 5 / 5 ns | **−2.105** | Worst path `rst_i → in_ready_o`, combinational port to port. Register-to-register slack −0.348. |

  Sources: [io_constraints/](../../docs/evidence/handoff_study_timing_20261021/io_constraints/) (`io_r3b1_0`, `io_r3b1_30pct`, `io_r3b1_50pct`), each with `path_classes.txt` and `timing_summary_excerpt.txt`
- **[core-only] unbuffered 3-round at 10 ns with 3/3 ns:** WNS +0.002. Input `in_keep_i[2] → bypass_g.engine_u/state_reg[162]/CE` has 7 levels, 7.475 ns, slack +0.209. — [io_r3b0_30pct/path_classes.txt](../../docs/evidence/handoff_study_timing_20261021/io_constraints/io_r3b0_30pct/path_classes.txt)
- **Port-coupled logic in the RTL (buffered wrapper):**
  - `in_ready_o` and `out_valid_o` include `rst_i` combinationally.
  - `out_data_o <= oq(orp).data` is a read mux, not a register.
  - `out_ready_i` feeds `opop → eo_ready →` the engine's `out_ready_i → perm_start` (overlap) and a 320-bit load enable.
  - Source: [rtl/ascon_aead128_core.vhd](../../rtl/ascon_aead128_core.vhd) lines 666–677 and 184–185
- **Prior evidence already flags this boundary.** "Core-only routes have unconstrained external I/O." — [report.json](../../docs/evidence/weight_stream_3rpc/report.json) (`boundaries`)

### Inferences
- **A realistic core-only constraint set** for this core, assuming it is driven by same-clock registers in the adapter or DMA:
  - `create_clock` on `clk_i`.
  - `set_input_delay -max 0.3·T` (about 3 ns at 10 ns) and `-min 0.5` (about the upstream register clock-to-out, to avoid the 0 ns hold artefact) on all inputs except `clk_i`.
  - `set_output_delay -max 0.3·T` and `-min 0` on outputs.
  - Either `set_false_path -from rst_i` (if reset is synchronised and held for several cycles), or a multicycle path on reset.
- With that set, the candidate meets at 10 ns. The remaining near-critical port path is the unregistered `out_data_o` read mux (+0.197 ns).
- In the board design, the ports connect to on-chip logic, so the real budget depends on the wrapper. The previously unconstrained runs overstated port margin only slightly at 30 %, but would hide a failure at 50 %.

### Gaps
- I did not test `rst_i` false paths or HD.CLK_SRC/partition-pin (`HD.PARTPIN_LOCS`) placement. OOC port placement is unconstrained, so port-route delays (about 5 ns on `out_data_o`) are estimates.

## 4. How sensitive is the candidate to implementation strategy, and how much should a 38 ps margin be trusted?

### Takeaway
The default flow is deterministic: identical inputs gave identical results. Across 11 directive sets at 10 ns the candidate WNS ranged from +0.038 ns (default) to +0.254 ns (Explore). All passed, but no strategy bought more than about 0.25 ns. Under a tighter target, the achieved period swings by about ±0.5 ns between neighbouring targets. The 38 ps margin is therefore only a "met by luck" number. The robust core-only figure is about 9.25–9.5 ns.

### Cited Findings
- **[core-only] candidate at 10 ns, by strategy** (`opt`/`place`/`phys_opt`/`route` directives; there is no seed knob in 7-series place and route). All runs: [all_runs_summary.txt](../../docs/evidence/handoff_study_timing_20261021/all_runs_summary.txt); arguments in [scripts/strat.jobs](../../docs/evidence/handoff_study_timing_20261021/scripts/strat.jobs).

  | Strategy | WNS (ns) | Notes |
  |---|---:|---|
  | Default | +0.038 | |
  | Default + `phys_opt` AggressiveExplore + post-route `phys_opt` | +0.038 | No change. |
  | `opt`/`place`/`route` Explore | +0.254 | |
  | Performance_Explore-like (Explore everywhere + `phys_opt` Explore + post-route `phys_opt`) | +0.254 | Identical to Explore. |
  | ExtraNetDelay_high + `phys_opt` AggressiveExplore + `route` AggressiveExplore | +0.071 | |
  | AltSpreadLogic_high | +0.115 | |
  | AltSpreadLogic_medium | +0.164 | |
  | ExtraTimingOpt | +0.097 | 4,013 LUT. |
  | EarlyBlockPlacement | +0.075 | |
  | Placement over-constrained by 0.5 ns uncertainty | +0.110 | Raw summary entry: 9.890 ns achieved = 10 − 0.110. |
  | Synthesis `-retiming` | +0.141 | 3,608 LUT, 1,675 FF; retiming found no registers to move. |

- **Run-to-run variation under tight targets.**
  - 3-round + FIFO: 9.0 ns target → 9.505 achieved (failed); 9.25 → met (+0.042); 9.5 → met (+0.040); 9.5 with Explore → met (+0.043).
  - Variant permutation: 9.0 → −0.007, but 9.1 → **−0.440**. That is a 0.43 ns swing for a 0.1 ns change in target.
  - Sources: [all_runs_summary.txt](../../docs/evidence/handoff_study_timing_20261021/all_runs_summary.txt); [all_runs_implementation.json](../../docs/evidence/handoff_study_timing_20261021/all_runs_implementation.json)
- **Board vs core-only.** The [board] 100 MHz trial failed at −0.130 ns on the same permutation path class, with 0.074 ns uncertainty versus 0.035 ns core-only. — [board-100-failed/setup_paths.txt](../../docs/evidence/weight_stream_3rpc/board-100-failed/setup_paths.txt)

### Inferences
- Implementation noise is about ±0.25–0.5 ns, roughly 3–5 % of the period. That is an order of magnitude larger than the 38 ps margin. Any claim of "100 MHz" for the candidate should cite the 9.25–9.5 ns confirmations or a margin of at least 0.3 ns, not +0.038.
- Tool-only levers (Explore) give about 0.2 ns. Real headroom needs fewer LUT levels or shorter routes (section 5).

### Gaps
- Each strategy got a single run. Swept clock-uncertainty "pseudo-seeds" were not run across many values, so the variability distribution is coarse (about 15 data points).

## 5. RTL changes that buy back setup margin, and whether the absorb XOR fits in the 2-round tail group

### Takeaway
1. **Static lane guards / short group first.** These remove two of the three bypass muxes and the three fanout-327 enable nets. Measured: +0.394 ns vs +0.038 ns at 10 ns. A 2-round build met 6.0 ns where the committed RTL only reached 6.78 ns. Area falls by about 90–340 LUTs.
2. **Absorb-in-tail (coordinator's question).** Yes, it fits. In a synthetic harness sharing one 320-bit register, the path "2 rounds (10, 11) + rate XOR din + decrypt select + load mux" had 5 levels and 8.36 ns. The 3-round group had 7 levels and 9.51 ns, so the tail path has about 1.1 ns more slack.
   - The cost appears on the 3-round path if the tail is built as a separate datapath. The wider final mux adds about 0.7 ns there (9.56 ns vs 8.80 ns for the 3-round-only reference), and costs about 1,090 LUTs.
   - The cheaper form is to put the absorb XOR on the existing lane-2 bypass leg of the shared chain. My estimate is that this adds no level to the 3-round path.
3. **Other fixes.** Precomputed keep/error flags and a fixed FIFO head register (for the buffered keep → CE path), a registered `out_data_o`, removing combinational `rst_i` from ready/valid, and fanout control on `busy`/controller decodes.

### Cited Findings
- **[variant] `build/handoff_vivado/variants/ascon_permutation_v1.vhd`.**
  - Design changes:
    - The short group runs first (p8 at R=3 = 2+3+3, lane 0 bypassed on the first step).
    - Bypass muxes exist only on lanes that can ever be skipped, decided at elaboration time.
    - Lane enables are registered one-hot bits.
    - `final_round_reg` is removed.
  - Equivalence: checked in XSim against the committed permutation for R = 1, 2, 3, 4, 6, with 400 random states each, alternating p8/p12. All passed. A deliberate round-index mutation was caught (`state mismatch`).
  - Not simulated in the full AEAD testbench.
  - Sources: [variants/](../../docs/evidence/handoff_study_timing_20261021/variants/); [equiv_xsim_results.txt](../../docs/evidence/handoff_study_timing_20261021/variants/equiv_xsim_results.txt)
- **[variant] timing.**

  | Config | Target (ns) | Variant WNS | Committed RTL WNS | Variant LUT | Committed LUT |
  |---|---:|---:|---:|---:|---:|
  | 3-round + FIFO | 10 | +0.394 | +0.038 | 3,618 | 3,708 |
  | 3-round + FIFO | 9.0 | −0.007 | −0.505 | — | — |
  | 3-round + FIFO | 9.1 | −0.440 | — | — | — |
  | 2-round, no FIFO | 6.5 | +0.085 | −0.241 | — | — |
  | 2-round, no FIFO | 6.0 | **+0.082** | — | 2,449 | — |
  | 2-round + FIFO | 6.5 | −0.629 | — | — | — |
  | 4-round + FIFO | 11 | −3.87 | — | — | — |

  - The committed RTL's best 2-round no-FIFO result was 6.78 ns, against the variant's 6.0 ns met.
  - In the 9.1 ns run the variant lost to placement noise.
  - The 2-round + FIFO failure was on the FIFO keep → CE path (7 levels).
  - The 4-round + FIFO run was a poor single run with a 2,309 s runtime; the variant removes no level for R=4 because R=4 has no guards.
  - In the variant's worst path the load mux merged into the last linear-layer LUT (`LUT5 9696FF00 = busy ? XOR3 : state_i`). The path still has 7 levels because the lane-0 bypass sits inside round 1.
  - Sources: [all_runs_summary.txt](../../docs/evidence/handoff_study_timing_20261021/all_runs_summary.txt); [v1_r3b1_p9.0_critical_path_lut_inputs.txt](../../docs/evidence/handoff_study_timing_20261021/fmax_paths/v1_r3b1_p9.0_critical_path_lut_inputs.txt)
- **[variant] tail harness at 9.0 ns.** `build/handoff_vivado/variants/tail_harness.vhd` has one 320-bit register with next value `load ? state_i : tail ? absorb(round11(round10(s)), din, dec) : round×3(s, rn)`, plus registered din/ctrl and a 128-bit ciphertext register.

  | Harness run | WNS (ns) | Path | Levels | Delay (ns) |
  |---|---:|---|---:|---:|
  | keep_hierarchy | −0.560 | Through the 3-round chain | 7 | 9.507 |
  | keep_hierarchy | +0.589 (path slack) | Through 2-round tail + absorb | 5 | 8.358 |
  | keep_hierarchy | +5.142 (path slack) | `din_reg → state` | 2 | 3.80 |
  | keep_hierarchy | +1.715 (path slack) | Tail → ciphertext register | 4 | 7.16 |
  | Flattened, with tail | −0.564 | Worst path | 7 | 9.555 |
  | Flattened, 3-round only reference | **+0.148** | Worst path (load mux folded into the last LUT) | 6 | 8.799 |

  Area: flattened with tail 2,810 LUT / 588 FF; reference 1,719 LUT / 325 FF. Sources: [tail_harness/](../../docs/evidence/handoff_study_timing_20261021/tail_harness/) (`classes.txt`, `implementation.json`, `utilization_hier.txt`)
- **Committed 2-round designs as a reference for 2-round group cost.** Their round datapaths (2 rounds + load mux, 5–6 levels) closed at 6.6–7.2 ns when placed on their own. — [all_runs_summary.txt](../../docs/evidence/handoff_study_timing_20261021/all_runs_summary.txt)
- **FIFO-head → engine CE path.**
  - Path: `iq_reg[*][keep] →` LUT3 FIFO read mux `iq(ir) →` four LUTs of keep-contiguity, count and error decode (`keep_is_contiguous`, `keep_count`, `in_keep_i /= x"FFFF"`) `→` controller `→` 128-load CE.
  - At 10 ns: 7 levels, 8.98 ns.
  - At tight targets it limits buffered R=1 (7.57 ns) and R=2, and it was −0.152 ns on the candidate at the 9.0 ns target.
  - Sources: [fifo_to_eng.txt](../../docs/evidence/handoff_study_timing_20261021/candidate_r3b1_100mhz/fifo_to_eng.txt); [f_r3b1_p9.0_path_classes.txt](../../docs/evidence/handoff_study_timing_20261021/fmax_paths/f_r3b1_p9.0_path_classes.txt); [rtl/ascon_aead128_core.vhd](../../rtl/ascon_aead128_core.vhd) lines 341–367 and 660–700

### Inferences
Ranked recommendations. Gains are estimates unless marked measured.

1. **Absorb folding (coordinator's leading candidate).** The 2-round tail has about 2 levels and about 1.1–1.5 ns of spare depth relative to the 3-round group, so one more XOR/mux level fits.
   - Use the shared chain: compute `bypass = dec ? din : r2_rate ⊕ din` on lane 2's bypass input for the 128 rate bits. The existing lane-2 mux LUT then selects it. That adds about 1–2 LUT levels on a leg that currently has 4, so it stays at or below 6 levels while the 3-round leg stays at 7.
   - Do not build a separate tail datapath. The harness shows it adds a mux level to the 3-round path (+0.7 ns) and about 1,090 LUTs.
   - At the candidate's confirmed 9.25 ns, 3 clocks/block would give about 577 MB/s [model, estimate]. At 100 MHz it would give about 533 MB/s.
   - For R=2 or R=4 the absorb would sit on a full group and add a level to the critical path (about +1 ns). R=3 is the factor where folding is free.
2. **Static guards with a registered one-hot lane schedule** (v1, measured above). Run the short group first, or at least drop guards on lanes that can never be skipped.
   - Gain: about 0.3–0.5 ns at R=3 (noisy) and about 0.8 ns at R=2.
   - Cost: −90 to −340 LUTs and +1 to +2 FFs.
   - Folding the load mux into the last linear LUT works only when the last lane has no bypass. With the absorb-on-lane-2 plan, lane 2 keeps its mux. Choose one of the two, or put the short group first and the absorb on the first step's bypass leg.
3. **Precompute the keep classification.** Store `keep_full`, `keep_contiguous`, `keep_zero` and the error class with each FIFO entry at push time (about 4 FF per entry). Make the FIFO head a fixed register (shift-style 2-entry FIFO) instead of the `iq(ir)` read mux.
   - Estimated saving on the FIFO → CE path: 3–4 LUT levels (about 3 ns).
   - This makes buffered R=1 and R=2 round-limited. Buffered R=1 would go from 143 MHz to about 200 MHz, the same as the unbuffered R=1 control limit.
   - Cost: about 10–20 FFs and fewer LUTs.
4. **Register the I/O boundary.**
   - Drive `out_data_o/keep/last` from a head register; the fixed-head FIFO also removes the +0.197 ns path.
   - Remove `rst_i` from `in_ready_o`/`out_valid_o`, which fixes the 50 % budget failure.
   - Optionally register `out_ready_i` before it reaches `perm_start`.
   - Cost: about 0–150 FFs.
5. **Fanout control.**
   - Put `max_fanout` (or manual replication) on `busy_reg`: fanout 332, up to 7.5 ns of routing on R=2 at 10 ns.
   - Use one-hot encoding or replicated decodes for `controller_state`: `key_reg` CE fanout 129 with 8.0 ns routing; `out_valid_reg` CE fanout 129.
   - Cost: tens of FFs. Effect: removes the second-tier 1-level/8-ns paths that appear once round paths improve.
6. **Do not raise R above 3** for throughput. Both 4 and 6 were measured slower per block.
7. **Precompute round constants.** This barely matters: the RC decode is not on the worst path because round_number paths are 0.13 ns behind. It folds naturally into recommendation 2.

### Gaps
- The shared-chain absorb-on-lane-2 form is an estimate. Only the separate-datapath harness was implemented.
- Neither the harness nor the v1 permutation was run in the full AEAD KAT testbench; the variant passed only permutation-level equivalence.
- The FIFO-flag and I/O-register recommendations are unimplemented estimates. Their gains are inferred from the measured path composition.
- No Pblock or floorplanning trials were run.
