# Shared-controller bugs: AD padding and decryption tag exposure

Branch `ascon-weight-stream-fold-absorb`, found and fixed 2026-10-21.
Both bugs are in the shared controller used by u1, u3 and u3-buffered, and
both are present in the published commit `8b886c0` (branch
`codex/ascon-weight-stream-3rpc`). The folded core (`G_FOLDED_ABSORB`) had
neither.

| Bug | Section | Evidence |
|---|---|---|
| Empty AD terminator skips the padded block | 1 | `docs/evidence/ad_padding_fix_20261021/` |
| Expected tag driven on `tag_out_o` during decryption | 2 | `docs/evidence/tag_output_gate_20261021/` |

# 1. Associated-data padding

## The bug

Ascon-AEAD128 (NIST SP 800-232) pads non-empty associated data with `0x01`
followed by zeros up to the 16-byte rate. When the AD length is an exact
multiple of 16, this produces one extra block, containing only the padding.
That block is absorbed with its own p8 before the domain-separation bit is
applied.

The core accepts two framings for AD that ends on a block boundary:

1. **Standard:** the last full AD beat carries `last = 1`. The controller
   records `ad_full_last_reg` and runs the padded block through
   `ST_AD_PAD_START`/`ST_AD_PAD_WAIT`. This was correct.
2. **Empty terminator:** every full AD beat is non-last and an empty beat
   (`keep = 0`, `last = 1`) ends the phase. This was wrong.

In the second framing, `ST_AD_WAIT` treated the empty last beat as "no
associated data at all". It applied domain separation only, skipping both the
padded block and its p8. It could not tell the two cases apart, because the
earlier non-last beats leave no record behind.

The payload phase handled the same empty-terminator framing correctly. Only AD
was affected.

### Effect

- Ciphertext and tag were non-standard for that framing, in both directions,
  because AD is absorbed before any output and every later block depends on
  the resulting state.
- **The AD encoding was no longer injective.** A 16-byte AD `A' ‖ 0x01` sent
  with an empty terminator reached the same state as the 15-byte AD `A'` sent
  normally. A tag computed for one would therefore verify for the other. This
  was a deduction from the code; the new regression test now checks the fixed
  core against it.
- **Not affected:**
  - the standard framing;
  - all 2,178 official KAT checks;
  - the adapter and weight-file runners;
  - the board self-test and demo.

  None of them uses the empty-terminator framing for AD.
- **Affected configurations:** u1, u3 and u3-buffered, which share one
  controller. The folded core (`G_FOLDED_ABSORB`) was written correctly and
  needed no change.

## The fix (`rtl/ascon_aead128_core.vhd`)

- **New flag `ad_seen_reg`.** It is set whenever a non-empty AD beat is
  absorbed. It is cleared on reset, at command acceptance and in
  `ST_ZEROIZE`, and it is added to the `ST_DONE` cleanup assertion.
- **New branch in `ST_AD_WAIT`.** An empty last beat with `ad_seen_reg = '1'`
  now XORs `padding_bit(0)` into the rate and enters the existing
  `ST_AD_PAD_START` → `ST_AD_PAD_WAIT` path, which runs p8 and then domain
  separation. This is the same path the standard full-last-beat framing
  already used.
- **Truly empty AD is unchanged.** An empty last beat with `ad_seen_reg = '0'`
  still applies domain separation only and runs no p8.

No new state, no datapath change and nothing on the round chain. The change
adds one flip-flop plus controller decode. The routed area delta was larger
than that; see the Vivado table below.

## Verification (measured, GHDL 1.0.0 in WSL)

**New test `empty_terminator_after_full_beats_pads_per_sp800_232`**
(`verification/cocotb/test_ascon.py`). It encrypts and decrypts with the
empty-terminator framing and compares against the SP 800-232 reference model,
requiring authentication and commit. Cases: AD of 16 and 32 bytes, split
payload, and split AD with split payload. It also checks that the previously
colliding pair (`A'` against `A' ‖ 0x01` split) now gives different tags.

| Suite | u1 | u3 | u3-buffered | fold |
|---|---|---|---|---|
| `test_ascon` (11 tests) | 11/11 | 11/11 | 11/11 (also queue depth 1/1) | 11/11 |
| `test_ascon`, full official KAT | 11/11 | — | 11/11 | — |
| `test_stream`, full official KAT | — | — | pass | — |
| `test_cycles` regression | pass | pass | pass | pass |

| Framing probe (16 B AD, 16 B payload) | u1 | u3 | u3-buffered | fold |
|---|---|---|---|---|
| AD empty-terminator, before fix | mismatch (56 clk) | mismatch (30) | mismatch (29) | pass (22) |
| AD empty-terminator, after fix | **pass (66)** | **pass (35)** | **pass (34)** | pass (22) |
| Payload empty-terminator | pass (66) | pass (35) | pass (34) | pass (22) |

- **Cycle cost.** The fixed AD case now costs exactly the same cycles as the
  payload case: one extra p8, which the standard requires.
- **Standard framing is unchanged.** The cycle-regression test passes on all
  four configurations, and the full official KAT set still passes.

Reproduce with `build/padfix/run.sh` (copied to the evidence folder). It
mirrors the worktree into `~/ascon_fold_scratch` and runs the matrix above,
then the framing probe.

## Vivado core-only route at 100 MHz (measured)

Setup: Vivado 2023.2, xc7a100tcsg324-1, `vivado/route_stream.tcl`, 10 ns
clock, external I/O unconstrained, the same method as the earlier runs.
Sources were snapshotted to `build/padfix/vivado/src/`; their hashes are in
the evidence folder.

| Configuration | Setup | Hold | LUTs | FFs | Worst path |
|---|---:|---:|---:|---:|---|
| Buffered 3-round, before fix (8b886c0) | +0.038 ns | +0.144 ns | 3,708 | 1,680 | permutation state→state, 7 levels |
| **Buffered 3-round, with fix** | **+0.287 ns** | **+0.110 ns** | **3,871** | **1,688** | permutation state→state, 7 levels, 9.706 ns (80% route) |
| Fold, before fix | +0.139 ns | +0.101 ns | 2,985 | 1,085 | fold state→state, 7 levels |
| **Fold, with fix** | **+0.139 ns** | **+0.101 ns** | **2,985** | **1,085** | identical: 9.841 ns, 7 levels |

- **Both configurations meet 100 MHz with the fix.**
- **Fold result is identical.** The fix is in the shared engine, which the
  fold configuration does not instantiate.
- **Buffered setup slack rose (+0.249 ns).** This is placement variation on the
  same round-chain critical path; the fix is not on that path. The timing
  study measured ±0.25–0.5 ns of noise for this design, so this is not a real
  timing gain.
- **Buffered area rose by 163 LUTs and 8 FFs.** That is more than one flag
  needs. The likely cause is the extra source on the state-register rate mux
  in `ST_AD_WAIT` (the padding XOR), plus run-to-run variation. It is not
  analysed further; it amounts to about 0.26% of the device.
- **One run failed on a tool start-up error.** Starting both Vivado jobs
  together once caused a transient synthesis file-read failure, as the timing
  study also saw. The buffered run was repeated on its own; the failed log is
  kept as `buf_p10_failed_parallel_start.log`.

# 2. Decryption exposes the expected tag

## The bug

`ST_FINAL_WAIT` loads `tag_reg` with the computed tag in both modes. In
decryption that value is the tag the core expects to receive. The core then
waits in `ST_TAG_IN` for `tag_in_i`, while the concurrent assignment
`tag_out_o <= tag_reg` drove the expected tag onto the output port for the
whole wait. `tag_out_valid_o` stayed low, but the bits were present.

### Effect

The bug turns the core into a tag oracle. An attacker who can modify
ciphertext or AD and can read `tag_out_o`:

1. submits modified ciphertext;
2. reads the correct tag for it from `tag_out_o`;
3. returns that tag on `tag_in_i`.

Authentication then passes, `commit_o` fires, and the modified plaintext is
released as genuine. For weight protection, this defeats
quarantine-until-commit and allows committed, targeted bit-flips in the
weights.

**Exposure in this repository: latent, not live.**

- The demo samples `tag_out_o` only after `tag_out_valid_o`, in the
  encrypt-only `UI_TAG_OUT` state.
- The weight self-test samples it only on `tag_out_valid_o`.
- The board ILA does not probe the tag.

The leak becomes live as soon as the port is wired into anything readable
without its valid flag: a register file, bus, ILA or DMA. An "only sample
when valid" convention is not a security boundary.

## The fix (`rtl/ascon_aead128_core.vhd`, one line)

```vhdl
tag_out_o <= tag_reg when decrypt_reg = '0' else (others => '0');
```

- **Gated on mode, not on `ST_TAG_OUT`.** The demo samples the encryption tag
  one clock after the handshake, while the controller is already in
  `ST_ZEROIZE`; a state-based gate would break that.
- **No window where the gate opens on an expected tag.** `decrypt_reg` and
  `tag_reg` are cleared on the same edge.
- **One gate covers all three configurations.** The u1, u3 and buffered
  wrappers pass the engine's port straight through. The folded core already
  gates its tag output.

## Verification (measured, GHDL 1.0.0 in WSL)

**New test `decryption_never_exposes_expected_tag`**
(`verification/cocotb/test_ascon.py`):

- It samples `tag_out_o` every clock from command to done, during a valid
  decryption and a tampered one, with an 8-clock tag delay so the core stays
  parked in its tag-input state.
- It requires the port to read zero throughout.
- It requires correct auth, commit and discard results in both cases.
- It confirms that encryption still publishes the correct tag.

| Suite | u1 | u3 | u3-buffered | fold |
|---|---|---|---|---|
| `test_ascon` (12 tests) | 12/12 | 12/12 | 12/12 (also queue depth 1/1) | 12/12 |
| `test_ascon`, full official KAT | 12/12 | — | 12/12 | 12/12 |
| `test_stream`, full official KAT | — | — | pass | pass |
| `test_cycles` regression | pass | pass | pass | pass |

- **Negative control.** The same test was run with the ungated assignment
  restored in a scratch copy, and it **fails** on u3 and u3-buffered as
  expected (11/12). This confirms the test detects the leak.
- **Board fixtures**, simulated with the committed board generics (legacy
  buffered engine, gated):
  - `tb_weight_selftest`: PASS, 1,161 cycles.
  - `tb_weight_demo`: PASS, 8 cases, 274 cycles.

  Both counts match the physical ILA captures, so the demo's
  one-clock-late tag sample still works.
- **Reproduce** with `build/tagfix/run.sh` and `build/tagfix/board_sim.sh`
  (copied to the evidence folder).

# Not yet done (both fixes)

- **Vivado not rerun for the tag gate.** The change is a 128-bit AND on an
  output port, off the round chain, so setup impact is expected to be
  negligible, but it is unmeasured. The Vivado results in section 1 predate
  this gate.
- **Netlists for u1/u3/u3-buffered now intentionally differ from `8b886c0`.**
  The earlier "bit-for-bit unchanged" evidence in
  `docs/evidence/handoff_study_fold_20261021/` applies to the pre-fix source.
- **Other components:**
  - **Already-encrypted data:** any ciphertext produced earlier with the AD
    empty-terminator framing used the non-standard computation and will no
    longer decrypt. No repository runner produced such data.
  - **Published branch:** neither fix is on `codex/ascon-weight-stream-3rpc`.
  - **CI at evidence capture:** the saved local fix logs predate publication. The HDL publication commit `e460452` subsequently passed [GitHub Actions run 39691698078](https://github.com/kroix-ovo/ascon-aead128-vhdl/actions/runs/39691698078).

These fixes are included in the fold-absorb publication. Saved regression logs predate the publication commit; remote CI is reported by its workflow run.
