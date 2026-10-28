# Edge-by-edge schedules

All schedules are for one full 16-byte payload block in the middle of a
message (`in_last = 0`, `in_keep = FFFF`), with input offered as early as the
protocol allows and `out_ready` held high. "Edge a" is the rising edge at
which the payload beat is accepted. Every cycle count below was confirmed by
the event logs of `tb/tb_core_pipeline.vhd` (`results/sim/*/core_unstalled.txt`).

## Mapping the diagram labels to the RTL

| Label | Controller state during the clock before the edge | What the edge does |
|---|---|---|
| **A** (absorb) | `ST_MSG_WAIT`, `in_ready_o = 1` | Input handshake. `state_reg` rate ← rate ⊕ data (encrypt) or ciphertext (decrypt); `out_data_reg` ← output block; `out_valid_reg` ← 1; next state `ST_MSG_OUTPUT`. |
| **O** (output) | `ST_MSG_OUTPUT`, `out_valid_o = 1` | Output handshake (`out_ready_i = 1`). `out_valid_reg` ← 0, `out_data_reg` ← 0; next state `ST_MSG_PERM_START`. |
| **L** (load) | `ST_MSG_PERM_START`, `perm_start = 1` | Permutation engine copies the core `state_reg` into its own `state_reg`; round index ← 4 (constant B4); engine `busy` ← 1; next state `ST_MSG_PERM_WAIT`. |
| **r** ×8 | `ST_MSG_PERM_WAIT`, engine busy | One complete Ascon round per edge, constants B4, A5, 96, 87, 78, 69, 5A, 4B. The eighth edge also sets engine `done` ← 1 and `busy` ← 0. |
| **C** (capture) | `ST_MSG_PERM_WAIT`, `perm_done = 1` | Core `state_reg` ← engine output; next state `ST_MSG_WAIT`, so `in_ready_o` rises for the next block. |

So the diagram's sequence A → O → L → r×8 → C is exactly the baseline RTL's
payload-block loop. The baseline reproduces it: 12 edges from one block's
input handshake to the next block's input handshake.

## A — baseline, and control experiments A_ctrl1 / A_ctrl2 (identical schedule)

| Edge | Label | Event |
|---|---|---|
| a | A | block *i* accepted; rate absorbed; output registered |
| a+1 | O | output block *i* accepted by the sink |
| a+2 | L | permutation input loaded from core `state_reg` |
| a+3 | r1 | round 1 (B4) result in engine `state_reg` |
| a+4 … a+9 | r2 … r7 | rounds 2–7 (A5 … 5A) |
| a+10 | r8 | round 8 (4B) result; `done` ← 1 |
| a+11 | C | result captured in core `state_reg`; `in_ready` ← 1 |
| a+12 | A | block *i+1* accepted |

Dependent-block interval: **12 edges**. p8 compute: **8 edges** (load edge to
final-state edge). Load-to-capture: 10 edges.

A_ctrl1 and A_ctrl2 change only combinational structure (and A_ctrl2 the
state encoding), so their event logs are cycle-for-cycle identical to A.

## B — two-stage round, and D = B + A_ctrl2 control changes

Each round is split into stage 1 (constant injection and S-box layer, result
in `sbox_reg`) and stage 2 (linear diffusion, result in `state_reg`). The
next round's stage 1 reads only `state_reg`, which is written only by stage
2, so round *k+1* cannot start before round *k* is complete. The round index
advances only on a stage-2 edge.

| Edge | Label | Event |
|---|---|---|
| a | A | block *i* accepted |
| a+1 | O | output accepted |
| a+2 | L | permutation input loaded; round index ← 4; phase ← 1 |
| a+3 | r1·s1 | `sbox_reg` ← S(state ⊕ B4) |
| a+4 | r1·s2 | `state_reg` ← L(`sbox_reg`): round 1 complete |
| a+5 … a+16 | r2 … r7 | two edges per round |
| a+17 | r8·s1 | `sbox_reg` ← S(state ⊕ 4B) |
| a+18 | r8·s2 | round 8 complete; `done` ← 1; `sbox_reg` cleared |
| a+19 | C | result captured; `in_ready` ← 1 |
| a+20 | A | block *i+1* accepted |

Dependent-block interval: **20 edges**. p8 compute: **16 edges**. To beat the
baseline on this interval, B or D must run more than 20/12 = 1.667× the
baseline's passing frequency.

## C — three-stage round

Stage 1: constant injection and S-box input XORs (`s1_reg`). Stage 2: chi
and S-box output XORs (`s2_reg`). Stage 3: linear diffusion (`state_reg`).
The next round's stage 1 reads only `state_reg`; the round index advances
only on a stage-3 edge.

| Edge | Label | Event |
|---|---|---|
| a, a+1, a+2 | A, O, L | as in A |
| a+3 | r1·s1 | `s1_reg` ← input XORs of (state ⊕ B4) |
| a+4 | r1·s2 | `s2_reg` ← chi + output XORs |
| a+5 | r1·s3 | `state_reg` ← diffusion: round 1 complete |
| a+6 … a+23 | r2 … r7 | three edges per round |
| a+24 … a+26 | r8 | round 8 complete at a+26; `done` ← 1; `s1_reg`, `s2_reg` cleared |
| a+27 | C | result captured; `in_ready` ← 1 |
| a+28 | A | block *i+1* accepted |

Dependent-block interval: **28 edges**. p8 compute: **24 edges**. Break-even
needs more than 28/12 = 2.333× the baseline frequency.

## Other measured intervals (unstalled, edges from command acceptance)

| Workload | A / A_ctrl1 / A_ctrl2 | B / D | C |
|---|---|---|---|
| Command → first payload accept, AD empty | 16 | 28 | 40 |
| Command → first payload accept, AD 16 B | 36 | 64 | 92 |
| Command → first `out_valid`, AD empty | 17 | 29 | 41 |
| Command → `done`, AD 0, message 0 B | 34 | 58 | 82 |
| Command → `done`, AD 0, message 16 B | 45 | 77 | 109 |
| Command → `done`, AD 0, message 32 B | 57 | 97 | 137 |
| Command → `done`, AD 0, message 1 KiB | 801 | 1337 | 1873 |
| Command → `done`, AD 0, message 4 KiB | 3105 | 5177 | 7249 |
| Command → `done`, AD 16 B, message 1 KiB | 821 | 1373 | 1925 |

Encryption and decryption have identical cycle counts in every workload. The
initialization p12 costs 12 round edges in A, 24 in B/D and 36 in C;
finalization likewise.
