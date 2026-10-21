> Publication update October 21, 2026: current branch `ascon-weight-stream-fold-absorb`. This is a dated working note. The later AD-padding and decryption-tag-output fixes are complete. Legacy bit-for-bit preservation claims below apply only to the pre-fix snapshot. Final status is in [the report](../../reports/Ascon%20weight%20stream%20bottlenecks.md) and [the fix note](../../docs/ad_padding_fix.md). No physical fold throughput is claimed.

# Ascon hardware literature: source ledger and architecture techniques for a high-throughput Artix-7 Ascon-AEAD128 streaming core

Context of the core under study (from the assignment, not re-measured here): VHDL Ascon-AEAD128, xc7a100t, 3 rounds/cycle (p8 = 3+3+2, p12 = 4x3), 2-entry input/output FIFOs, 6 clocks per full 16-byte block, +0.038 ns setup slack at a 100 MHz core-only constraint. Baseline: 1 round/cycle, 12 clocks/block, 1,894 LUTs. Candidate: 3,708 LUTs / 1,680 FFs.
Arithmetic from those numbers (my own): 6 clk/block = 3 permutation cycles + 3 non-permutation cycles. 12 clk/block = 8 + 4. At 100 MHz, 6 clk/block gives 128 b x 100 MHz / 6 = 2.13 Gbit/s, and 12 clk/block gives 1.07 Gbit/s.

Labels used in the ledger: **[M]** = published measurement as reported. **[E]** = estimate stated by the source. **[D]** = my own deduction or arithmetic. Recommendation tags: ADOPT idea / ADAPT implementation / COMPARE only.

Normalization rule used throughout: Ascon-128a (v1.2) and Ascon-AEAD128 (SP 800-232) share the datapath structure: 128-bit rate, p12 init/final, p8 per block. So cycles/block transfer between them [D]. Ascon-128 (64-bit rate, p6) cycles/block do NOT transfer. LUT/Fmax numbers are only loosely comparable within Artix-7, and differences in speed grade, tool, P&R vs synthesis, and wrapper (LWC API, AXI, FIFOs) can each be worth tens of percent. Where a source doesn't state these, I say so.

---

## Q1. What SP 800-232 specifies for Ascon-AEAD128, and which implementations are SP 800-232-compatible

### Takeaway
SP 800-232 (final, 13 Aug 2025) defines Ascon-AEAD128 as an Ascon-128a derivative: 128-bit key/nonce/tag, 128-bit rate / 192-bit capacity, p12 for init and finalization, p8 per block. It changes the IV to 0x00001000808c0001, switches to little-endian byte and bit order, and adds truncation and nonce-masking options. Among the sources reviewed, only rprimas/ascon-verilog, tristanitschner/ascon_cipher_verilog, ascon-c (master) and some self-reported GitHub cores claim SP 800-232. The GMU/Graz/VT LWC designs, OpenTitan, CAST ASCON-F, Malal 2024/25 and Groß 2015 are v1.2 / CAESAR-era Ascon-128 or Ascon-128a and are **not** SP 800-232-compatible bit-for-bit.

### Cited Findings
**Ledger entry S1: NIST SP 800-232 (final)**
- Title: "Ascon-Based Lightweight Cryptography Standards for Constrained Devices: Authenticated Encryption, Hash, and Extendable Output Functions". Authors: M. Sönmez Turan, K. McKay, J. Kang, J. Kelsey (NIST), D. Chang (Strativia). Published August 2025 (final 08/13/25; draft 11/08/24). DOI 10.6028/NIST.SP.800-232. — [NIST CSRC](https://csrc.nist.gov/pubs/sp/800/232/final); [PDF](https://csrc.nist.gov/pubs/sp/800/232/final)
- Ascon-AEAD128.enc takes a 128-bit key K and a 128-bit nonce N. It outputs C with |C| = |P| and a 128-bit tag T. "The rate and capacity of Ascon-AEAD128 are 128 and 192 bits, respectively." — [SP 800-232 §4.1](https://csrc.nist.gov/pubs/sp/800/232/final)
- Init: S ← IV‖K‖N with IV = 0x00001000808c0001, then S ← Ascon-p12(S), then S ← S ⊕ (0^192‖K). — [SP 800-232, Eq. 15–17](https://csrc.nist.gov/pubs/sp/800/232/final)
- AD: blocks are padded with pad(Ã,128) = Ã‖1‖0^(127−|Ã|). Each block is XORed into S[0:127], then Ascon-p[8] is applied. Domain separation is S ← S ⊕ (0^319‖1), applied even when AD is empty. — [SP 800-232, Eq. 18–22](https://csrc.nist.gov/pubs/sp/800/232/final)
- PT: S[0:127] ← S[0:127] ⊕ P_i, then C_i ← S[0:127], then S ← Ascon-p8(S). The last partial block is padded and C̃_n ← S[0:ℓ−1]. An empty final block still gets padded, so a message that is a multiple of 128 bits gets one extra padding-only absorb. — [SP 800-232, Eq. 23–29](https://csrc.nist.gov/pubs/sp/800/232/final)
- Decryption replaces the rate with ciphertext: P_i ← S[0:127] ⊕ C_i; S[0:127] ← C_i. The last block uses S[0:ℓ−1] ← C̃_n; S[ℓ:127] ⊕= (1‖0^(127−ℓ)). — [SP 800-232, Eq. 42–47](https://csrc.nist.gov/pubs/sp/800/232/final)
- Finalization: S ← S ⊕ (0^128‖K‖0^64), then Ascon-p[12], then T ← S[192:319] ⊕ K. On decryption, T′ is compared with T. "If the two match, the plaintext P is returned. Otherwise, an error message fail is returned." — [SP 800-232, Eq. 30–32, 49–51](https://csrc.nist.gov/pubs/sp/800/232/final)
- Differences from v1.2 listed by NIST:
  - round constants are defined for up to 16 rounds;
  - Ascon-AEAD128 "is based on ASCON-128a";
  - new IVs;
  - "endianness has been switched from big endian to little endian";
  - truncation and nonce-masking options are added.
  — [SP 800-232, Introduction](https://csrc.nist.gov/pubs/sp/800/232/final)
- Bit/byte mapping: the LSB of S0 is S[0:0], and the MSB of S4 is S[319:319]. The first byte of the state is the LSB byte of S0. Byte strings load directly on little-endian machines and "Neither bytes nor bits need to be reversed." — [SP 800-232, Appendix A](https://csrc.nist.gov/pubs/sp/800/232/final)
- Round constants: c_i = const_(16−rnd+i). The first 56 bits of each constant are zero, so only the low byte of S2 is affected. — [SP 800-232 §3.2](https://csrc.nist.gov/pubs/sp/800/232/final)
- Requirements:
  - R3: nonces shall be distinct for each encryption under a given key.
  - R4: truncated tags must be ≥32 bits, and <64 bits only after a careful risk analysis.
  - R5: limit the number of decryption failures.
  - R6: total data processed, including the nonce, "shall not exceed 2^54 bytes for a given key". (The exponent was lost in text extraction; the document also states the equivalent 2^50 blocks.)
  - R7: key update at that limit.
  — [SP 800-232 §4.3](https://csrc.nist.gov/pubs/sp/800/232/final)
- Truncation keeps the leftmost λ bits T[0:λ−1]. Nonce masking uses a 256-bit key K1‖K2 and masks N with K2. — [SP 800-232 §4.2](https://csrc.nist.gov/pubs/sp/800/232/final)
- Hypothesis motivated: none on cycles. It fixes the functional contract that any fused-absorb datapath must preserve (pad position, domain-separation bit in the MSB of S4, ciphertext replace on decrypt, key XORs). Tag: ADOPT (normative).

**Compatibility of implementations (checked against their own docs/code)**
- SP 800-232: rprimas/ascon-verilog. README: "as specified by NIST in SP 800-232". config.sv: `IV_AEAD = 64'h00001000808c0001`. Domain separation flips `64'h8000000000000000` in x4. — [ascon-verilog](https://github.com/rprimas/ascon-verilog); [config.sv](https://raw.githubusercontent.com/rprimas/ascon-verilog/main/rtl/config.sv); [ascon_core.sv](https://raw.githubusercontent.com/rprimas/ascon-verilog/main/rtl/ascon_core.sv)
- SP 800-232: tristanitschner/ascon_cipher_verilog (Ascon AEAD128 "as implemented in ascon-c / NIST SP 800-232", 1089 KAT cases) — [repo](https://github.com/tristanitschner/ascon_cipher_verilog); also listed as SP 800-232-compliant in the [ascon_collection README](https://github.com/ascon/ascon_collection/blob/master/README.md)
- SP 800-232: ascon-c master (`crypto_aead/asconaead128`). Branch v1.2 holds the submitted algorithms; KATs are at tag v1.3.0 (SP 800-232) vs v1.2.8. The README notes only `asm_rv32i` has been updated to SP 800-232 among the assembly variants. — [ascon-c](https://github.com/ascon/ascon-c)
- NOT SP 800-232:
  - ascon/ascon-hardware: ascon128v12 / ascon128av12 — [repo](https://github.com/ascon/ascon-hardware)
  - all GMU Round-2 Ascon designs (ascon128v12 / ascon128av12) — [GMU report](https://cryptography.gmu.edu/athena/LWC/GMU_LWC_Round_2_FPGA_Benchmarking.pdf)
  - OpenTitan Ascon (Ascon-128 / Ascon-128a) — [OpenTitan ToO](https://opentitan.org/book/hw/ip/ascon/doc/theory_of_operation.html)
  - CAST ASCON-F ("Ascon v1.2") — [CAST](https://www.cast-inc.com/security/encryption-primitives/ascon-f)
  - Malal (ASCON-128 / 128a) — [ePrint 2025/825](https://eprint.iacr.org/2025/825)
  - Groß et al. 2015 (CAESAR Ascon) — [ePrint 2015/034](https://eprint.iacr.org/2015/034)
- Self-reported SP 800-232 GitHub cores, unverified and not reviewed in depth: IEEEYorkU/lascon-ip (AEAD128/Hash256/XOF128/CXOF128, AXI4-Stream), hothiennhan021/ascon-aead128-genesys2 (APB, 1089 KATs claimed), dangminh6568 DOM-masked (~2,252 LUT unprotected vs 7,723 masked, synthesis, per the search summary). — [lascon-ip](https://github.com/IEEEYorkU/lascon-ip); genesys2 (repository unavailable at publication check); [DOM masked](https://github.com/dangminh6568/ascon_aead128_dom_masked)
- A 2025 MDPI Electronics paper ("Ascon on FPGA: Post-Quantum Safe Authenticated Encryption with Replay Protection for IoT") was reported by the search summary to implement older Ascon-128 on Artix-7 and to cite the SP 800-232 draft. I could not open it (403), so this is unverified. — [doi 10.3390/electronics14132668](https://doi.org/10.3390/electronics14132668)

### Inferences
- [D] The v1.2 → SP 800-232 changes are wiring-only for hardware: IV constant, byte/bit order of the bus-to-state mapping, pad-bit position, and domain-separation bit position (MSB of S4 under SP 800-232 Appendix A). They don't change the round logic or the number of cycles. So Ascon-128a cycles/block and approximate LUT/Fmax are a reasonable proxy for AEAD128. Ascon-128 (p6, 64-bit rate) numbers are not.
- [D] The v1.2 domain-separation and pad-bit positions (big-endian convention: LSB of x4, pad 0x80 in the first byte) come from my recollection of v1.2. I didn't re-verify them in this session.
- [D] A fused-absorb design has to handle the "full-block message still gets a padding-only block" rule. With multiples of 16 bytes, which is likely for weight streams, every message pays one extra p8 before finalization. That is a per-message cost, not a per-block cost.

### Gaps
- I didn't read the NIST LWC KAT format notes or conformance section (§6) in detail.
- I didn't verify the lascon-ip, genesys2, or DOM-masked cores' KAT claims.

---

## Q2. Robert Primas's ascon-verilog, ascon-hardware, ascon-c: variants, interfaces, numbers, and absorb scheduling

### Takeaway
ascon-verilog (SP 800-232) offers UROL ∈ {1, 2, 4} with 32- or 64-bit buses (six variants). It absorbs data in separate FSM states, one bus word per cycle, after the permutation finishes. Absorb is **not** fused into the first round, so steady-state cycles/block ≈ 128/CCW + 8/UROL. ascon-hardware (VHDL, LWC API v1.2.0, v1.2 algorithms) offers 1/2/3/4 rounds/cycle. Neither README gives FPGA LUT/Fmax numbers. The GMU report contains Artix-7 numbers for the older Graz variants (Q4).

### Cited Findings
**Ledger entry S2: rprimas/ascon-verilog (GitHub, CC0)**
- Variants v1–v6 = {32-bit bus: UROL 1, 2, 4; 64-bit bus: UROL 1, 2, 4}. ROUNDS_A = 12, ROUNDS_B = 8. No UROL 3 or 6. — [config.sv](https://raw.githubusercontent.com/rprimas/ascon-verilog/main/rtl/config.sv)
- Published cycle counts for Ascon-AEAD128 (msg = AD = 0 / 32 / 1024 B) [M, simulation counts]: v1 41/99/1587; v2 29/67/1059; v3 23/51/795; v4 35/85/1325; v5 23/53/797; v6 17/37/533. No LUT/area/frequency numbers are given; synthesis is Yosys with a "simple" cell library. — [README](https://github.com/rprimas/ascon-verilog)
- Interface: LWC-API-inspired `key/key_valid/key_ready`; `bdi` (32/64 bit) with `bdi_valid` (byte-valid vector), `bdi_ready`, `bdi_eot`, `bdi_eoi`, `bdi_type`; `bdo/bdo_valid/bdo_ready/bdo_type/bdo_eoo`; `auth/auth_valid`. The README warns that decrypted plaintext is output immediately and "an additional buffer should be used" until the tag is verified. — [README](https://github.com/rprimas/ascon-verilog)
- FSM (code): states include IDLE, LD_KEY, LD_NPUB, INIT, KADD_2, ABS_AD, PAD_AD, PRO_AD, DOM_SEP, ABS_MSG, PAD_MSG, PRO_MSG, KADD_3, FINAL, KADD_4, SQZ_TAG, VER_TAG.
  - Absorb happens in ABS_* states by XOR of one padded 64- or 32-bit word: `state_slice_nx = state_slice ^ bdi_pad`.
  - The permutation (`state_d = asconp_o`) runs only in INIT, PRO_AD, PRO_MSG and FINAL.
  - Key additions and domain separation are separate states.
  - `round_cnt_d = round_cnt_q - UROL`; a phase ends when `round_cnt_q == UROL`.
  - In ABS_MSG, `bdi_ready = mode_enc_dec ? bdo_ready : 1`, so input ready depends combinationally on output ready.
  — [ascon_core.sv](https://raw.githubusercontent.com/rprimas/ascon-verilog/main/rtl/ascon_core.sv)
- asconp.sv is purely combinational: a `generate for (i = 0; i < UROL; i++)` chain of rounds. The round constant is computed arithmetically per unrolled stage, `t[i] = 4'hC - (round_cnt - i)`, and injected into the low byte of x2. There is no data XOR inside the permutation module. — [asconp.sv](https://raw.githubusercontent.com/rprimas/ascon-verilog/main/rtl/asconp.sv)
- Hypothesis motivated:
  - (a) A separate absorb-cycle architecture costs ≥1 cycle per block even with a full-width bus.
  - (b) Arithmetic round-constant generation per stage is cheap but needs care with non-uniform schedules (3+3+2).
  - Tag: COMPARE (architecture baseline); ADAPT the constant indexing.

**Ledger entry S3: ascon/ascon-hardware (VHDL, GPL-3.0)**
- Variants: v1 (32-bit, 1 r/c, ascon128v12), v1_8bit, v1_16bit, v2 (32-bit, 1 r/c, ascon128av12), v3 (32-bit, 2 r/c, 128), v4 (32-bit, 2 r/c, 128a), v5 (32-bit, 3 r/c, 128), v6 (32-bit, 4 r/c, 128a).
- Based on the GMU LWC Hardware API Development Package v1.2.0. No resource/throughput numbers in the README. The README points to ascon-verilog as the newer, smaller-code implementation.
- Tag: COMPARE.
— [ascon-hardware](https://github.com/ascon/ascon-hardware)

**Ledger entry S4: ascon/ascon-c**
- SP 800-232 algorithms in `crypto_aead/asconaead128` (ref recommended).
- LWC-format KATs at `crypto_*/*/LWC*.txt`.
- Bit-interleaved and masked software variants; nothing hardware-specific.
- Tag: ADOPT as test oracle only.
— [ascon-c](https://github.com/ascon/ascon-c)

### Inferences
- [D] From the published cycle counts, the steady-state cost per 16-byte block is (count(1024) − count(0)) / 128 blocks (1024 B AD + 1024 B msg = 128 blocks):

  | Variant | Bus / UROL | Cycles/block | Split |
  |---|---|---|---|
  | v1 | 32-bit / 1 | ≈12.1 | 4 absorb + 8 perm |
  | v2 | 32-bit / 2 | ≈8.0 | 4 + 4 |
  | v3 | 32-bit / 4 | ≈6.0 | 4 + 2 |
  | v4 | 64-bit / 1 | ≈10.1 | 2 + 8 |
  | v5 | 64-bit / 2 | ≈6.0 | 2 + 4 |
  | v6 | 64-bit / 4 | ≈4.0 | 2 + 2 |

  This matches the FSM code: absorb words are serialized and not overlapped with rounds. The user's 1-round baseline (12 clk/block) has the same profile as v1. The user's 3-round core (6 clk/block = 3 + 3) has 3 non-round cycles per block, more than ascon-verilog's 64-bit variants (2).
- [D] Primas's `bdi_ready = bdo_ready` coupling is an example of the input/output handshake dependency that LaForest's rules flag as a trade-off (Q6).

### Gaps
- The ascon-verilog README has no FPGA LUT/Fmax numbers. I found no published Artix-7 numbers for the SP 800-232 version.
- I didn't inspect functions.sv (pad) or register.sv.
- The latest commit hash and date weren't visible.

---

## Q3. OpenTitan Ascon (hw/ip/ascon)

### Takeaway
OpenTitan's Ascon is an in-progress CSR-based IP for Ascon-128/128a (v1.2 naming), not Ascon-AEAD128. It uses a 320-bit datapath, 1 round/cycle, and a separate 1-cycle absorb/extract. That gives 9 cycles between consecutive Ascon-128a blocks. Masking (DOM) is planned, not implemented. Pipelining is explicitly rejected because each permutation depends on the previous one.

### Cited Findings
**Ledger entry S5: OpenTitan Ascon theory of operation + README**
- "320-bit data-path 1 round/cycle", unhardened first version. First-order DOM masking is planned ("still TBD"). Pipelining is rejected because each permutation call depends on the previous output. The core waits between permutation calls if the next input block is not available. Data is byte-aligned little-endian with hardware padding via CTRL.VALID_BYTES. Output buses are zero when not producing output.
- Area estimates [E]: ~6098 GE unhardened (391 FFs + 128-bit key); overall ~7 kGE unhardened, 14–28 kGE hardened. Throughput target 200–400 Mbit/s at 1 GHz [E]. Modes: Ascon-128 and Ascon-128a; supporting both costs about three 2:1 64-bit muxes [E].
- Start: the FSM leaves idle on a start command (encrypt/decrypt) via CSR. No done-handshake details are given.
— [OpenTitan ToO](https://opentitan.org/book/hw/ip/ascon/doc/theory_of_operation.html)
- README: permutation latency 6 cycles (Ascon-128) / 8 cycles (128a) unmasked. "Absorption and extraction take 1 cycle", so the latency between consecutive blocks is 7 / 9 cycles for large inputs. High-speed multi-round-per-cycle is "not required". Masking, PRNG reseeding and hashing are future work. — [opentitan hw/ip/ascon](https://github.com/lowRISC/opentitan/tree/master/hw/ip/ascon)
- Tags: COMPARE (1-cycle absorb overhead design point; not SP 800-232; ASIC GE estimates only).

### Inferences
- [D] OpenTitan's 8 + 1 cycles/block with a full-width (128-bit) absorb is the "one overhead cycle" design point. The user's baseline (8 + 4) has 3 more overhead cycles than this at the same rounds/cycle.

### Gaps
- I didn't read the actual OpenTitan RTL files (rtl/ listing not returned) or the masking/fault-countermeasure FSM. No post-synthesis numbers are published.

---

## Q4. GMU CERG LWC hardware API and benchmarking: formulas, cycles/block, Artix-7 numbers, API overhead

### Takeaway
GMU's Round-2 benchmarking (Mohajerani et al., ePrint 2020/1207) defines long-message throughput as a steady-state differential, which excludes init and finalization. It reports Ascon designs on xc7a12tcsg325-3 (−3 speed grade), post-place-and-route via Minerva, including the LWC API wrapper. The best Ascon was Ascon_GMU-v1 (Ascon-128a, 2 rounds/cycle): 5 cycles per 128-bit block (4 permutation + 1), 246 MHz, 2,410 LUTs, 6.30 Gbit/s. The Graz designs with a 32-bit absorb path paid 4 cycles per 128-bit block. So the API bus width, not the round logic, dominated them.

### Cited Findings
**Ledger entry S6: Mohajerani, Haeussler, Nagpal, Farahmand, Abdulgadir, Kaps, Gaj, "FPGA Benchmarking of Round 2 Candidates in the NIST LWC Standardization Process: Methodology, Metrics, Tools, and Results", ePrint 2020/1207 (Sept 2020, rev. Feb 2021)**
- Long-message throughput = d·Block_size / (Time(N+d blocks) − Time(N blocks)). Also reported for 1536, 64 and 16 B inputs, separately for AD, PT, AD+PT and hash. — [GMU PDF](https://cryptography.gmu.edu/athena/LWC/GMU_LWC_Round_2_FPGA_Benchmarking.pdf)
- Conditions:
  - Artix-7 xc7a12tcsg325-3, Vivado 2020.1.
  - Fmax and resources from Minerva automated optimization (~3.5 h per variant), "raw post-place and route results".
  - No BRAM/DSP.
  - Design goal: unprotected ≤2000 LUTs (one quarter of the device).
  - GMU notes that teams sometimes got better results themselves, e.g. due to Vivado version or out-of-context mode.
  — [GMU PDF §3–4](https://cryptography.gmu.edu/athena/LWC/GMU_LWC_Round_2_FPGA_Benchmarking.pdf)
- Basic iterative = 1 round/cycle; unrolled designs reduce cycles and increase LUTs. Ascon_Graz v1/v2 had the smallest key-reload overhead (3 cycles). — [GMU PDF §5](https://cryptography.gmu.edu/athena/LWC/GMU_LWC_Round_2_FPGA_Benchmarking.pdf)
- Table 3 cycles per PT block [M]:

  | Design | Algorithm | Block | Rounds/cycle | Cycles/block |
  |---|---|---|---|---|
  | Graz-v1 | 128 | 64-bit | 1 | 8 |
  | Graz-v2 | 128a | 128-bit | 1 | 12 |
  | Graz-v3 | 128 | 64-bit | 2 | 5 |
  | Graz-v4 | 128a | 128-bit | 2 | 8 |
  | Graz-v5 | 128 | 64-bit | 3 | 4 |
  | Graz-v6 | 128a | 128-bit | 4 | 6 |
  | VT-v1 | 128 | 64-bit | 1 | 10 |
  | GMU-v1 | 128a | 128-bit | 2 (2× unrolled) | 5 |
  | GMU-v2 | 128a | 128-bit | 1 | 9 |
  | GMU2-v1h / v2h / v3h | 128 | 64-bit | — | 7 / 4 / 3 |

  Rounds/cycle for Graz is per the ascon-hardware variant list. — [GMU PDF Table 3](https://cryptography.gmu.edu/athena/LWC/GMU_LWC_Round_2_FPGA_Benchmarking.pdf); [ascon-hardware](https://github.com/ascon/ascon-hardware)
- Table 22, Artix-7 LUT / FF / slices / MHz [M, post-P&R]:

  | Design | LUTs | FFs | Slices | MHz |
  |---|---|---|---|---|
  | GMU-v1 | 2,410 | 974 | 670 | 246 |
  | GMU-v2 | 1,790 | 974 | 513 | 307 |
  | GMU2-v1h | 1,375 | 862 | 436 | 276 |
  | GMU2-v2h | 2,126 | 861 | 632 | 234 |
  | GMU2-v3h | 2,493 | 860 | 689 | 142 |
  | Graz-v1 | 1,465 | 666 | 396 | 191 |
  | Graz-v2 | 1,541 | 668 | 431 | 213 |
  | Graz-v3 | 2,142 | 665 | 582 | 201 |
  | Graz-v4 | 2,249 | 669 | 620 | 206 |
  | Graz-v5 | 2,797 | 666 | 785 | 150 |
  | VT-v1 | 1,913 | 539 | 518 | 233 |
  | VT-v2 | 1,928 | 544 | 515 | 219 |

  — [GMU PDF Table 22](https://cryptography.gmu.edu/athena/LWC/GMU_LWC_Round_2_FPGA_Benchmarking.pdf)
- Table 25, Artix-7 PT encryption throughput, long messages [M]: GMU-v1 6,297.6 Mbit/s; GMU-v2 4,366.2; GMU2-v2h 3,744.0; Graz-v4 3,296.0; GMU2-v3h 3,029.3; Graz-v3 2,572.8; GMU2-v1h 2,523.4; Graz-v5 2,400.0; Graz-v2 2,272.0; VT-v2 1,557.3; Graz-v1 1,528.0; VT-v1 1,491.2. — [GMU PDF Table 25](https://cryptography.gmu.edu/athena/LWC/GMU_LWC_Round_2_FPGA_Benchmarking.pdf)
- GMU text: "Ascon_GMU-v1 is a 2× unrolled variant of Ascon-128a, Ascon_GMU-v2 is the basic iterative architecture". Adding hashing (VT-v1 vs VT-v2) had no area or throughput penalty. — [GMU PDF §5.2.3](https://cryptography.gmu.edu/athena/LWC/GMU_LWC_Round_2_FPGA_Benchmarking.pdf)
- LWC Development Package: generic PreProcessor, PostProcessor and CMD FIFO. It supports external/internal bus combinations {32:16} and {32:8}. — [GMU PDF §1–2](https://cryptography.gmu.edu/athena/LWC/GMU_LWC_Round_2_FPGA_Benchmarking.pdf)
- API documents: "Hardware API for Lightweight Cryptography v1.1" (Kaps, Diehl, Tempelmeier, Homsirikamol, Gaj, 31 Jan 2022) and Development Package v1.2.0 (20 Feb 2022). Final-round GMU work is "SCA Evaluation and Benchmarking of Finalists…" (ePrint 2023/484). GMU's athena page lists no separate final-round unprotected FPGA benchmarking report. — [GMU athena LWC](https://cryptography.gmu.edu/athena/index.php?id=LWC)
- Tags: COMPARE (numbers, xc7a12t-3); ADOPT the throughput-measurement methodology (differential long-message cycles).

### Inferences
- [D] Check: 128 b × 246 MHz / 5 = 6,297.6 Mbit/s, which matches Table 25. So GMU-v1 really runs 4 permutation + 1 other cycle per block in steady state, inside the LWC API wrapper. One overhead cycle per block is achievable with the API. The API itself doesn't force 3–4 cycles.
- [D] The Graz 128a variants follow cycles = 4 + 8/r (v2: 4 + 8 = 12, v4: 4 + 4 = 8, v6: 4 + 2 = 6), consistent with 4 × 32-bit sequential absorb words. The 32-bit API data width is the bottleneck at high unroll. Graz-v6 at 4 rounds/cycle (6 cyc) is no better in cycles than the user's 3-round core.
- [D] Critical-path proxy on Artix-7 −3 (post-P&R, including API): 1 round/cycle ≈ 3.3 ns (GMU-v2, 307 MHz); 2 rounds ≈ 4.1 ns (GMU-v1, 246 MHz); 3 rounds ≈ 6.7 ns (Graz-v5, 150 MHz, Ascon-128 with 32-bit interface). The user's xc7a100t is most likely a −1 part (Nexys A7). That's an assumption; check the part string. Lower speed grades are slower, so the −3 numbers are an upper bound. Even so, a 3-round path that only just meets 10.0 ns suggests the user's critical path includes substantial logic beyond the three rounds (absorb/pad mux, FIFO/handshake, round-select muxing for 3 vs 2 vs 4 round cycles). This is a hypothesis to confirm with the timing report.

### Gaps
- Couldn't open ePrint PDFs directly (HTTP 403). The final-round GMU paper (2023/484) unprotected Ascon numbers weren't extracted.
- Didn't read the LWC HW API v1.1 PDF for its exact handshake rules (pdi/sdi/do valid/ready). I don't know how GMU-v1 obtains its 128-bit block within a 32-bit external API (internal widening in the PreProcessor or a wider CryptoCore interface).
- GMU Table 22 has no Graz-v6 Artix-7 row in the extracted text.

---

## Q5. Recent (and foundational) Ascon FPGA/ASIC papers and implementations: unrolled, fused absorb, multi-stream

### Takeaway
High-throughput Ascon designs that report about ceil(rounds/r) cycles per block, with no separate absorb cycle, exist in several independent sources. Examples: a speed-focused SP 800-232 Verilog core, the CAST commercial core (16 bits/cycle for 128a at 1 round/cycle), Groß 2015 (0.75 cycles/byte), and Malal 2024 (64 bit/cycle at 4 r/c). This is the main known way to remove the user's 3 extra cycles. On xc7a100t, rounds/cycle beyond 2–3 rapidly lengthens the period. Khairallah & Yadhunathan report 5 ns for 1–2 r/c, 7 ns for 3, 7.5 ns for 4 and 10 ns for 6. Multi-stream pipelining only helps when independent messages are available.

### Cited Findings
**Ledger entry S7: T. Itschner, ascon_cipher_verilog (GitHub; SP 800-232; "focus on speed")**
- Generic `rounds_per_clk` (1…12). README cycle formula: ceil(12/r) for key setup, plus ceil(8/r) per 128-bit AD and PT block, plus ceil(12/r) for the tag, plus one pause cycle between packets. That means no per-block absorb cycle.
- AXI-Stream interface: s_cmd (key [127:0], nonce [255:128], flags), s_ad, s, tag-in; outputs m_ad, m, tag. Optional input and output "isolators" (register slice / skid buffer) for timing. Input AXIS compliance only holds with the isolator.
- Results [M, OOC synthesis, Zynq UltraScale+ xczu7eg-3]:
  - r = 1: 500 MHz target met with +0.683 ns slack; 1,526 LUT / 995 FF top level.
  - r = 4: 400 MHz met with +0.141 ns slack; 4,271 LUT / 1,028 FF top level, ascon_p 3,842 LUT.
- No measured throughput. The 6.185 Gbit/s figure is a worked example, not a measurement.
— [README](https://github.com/tristanitschner/ascon_cipher_verilog)
- Code: absorb is a combinational XOR on the permutation output feeding the next permutation input, `ap_m_data_xored = ap_m_data_ds ^ ({192'b0, s_data} << 192)`. Ciphertext = `ap_m_data[319:192] ^ s_data`. Decrypt loads the ciphertext into the rate. The input beat is accepted in the same cycle the permutation output is consumed. The author comments that the interlock breaks strict AXIS compliance, and a TODO notes that removing the one-cycle packet pause "breaks timing". — [ascon_aead128_core.v](https://raw.githubusercontent.com/tristanitschner/ascon_cipher_verilog/master/rtl/ascon_aead128_core.v)
- Hypothesis: fuse the absorb XOR and ciphertext generation into the cycle boundary, giving ceil(8/r) cycles per block. Tag: ADOPT the idea; ADAPT the implementation (it targets UltraScale+, so the numbers are COMPARE only).

**Ledger entry S8: CAST ASCON-F datasheet (commercial; Ascon v1.2; not SP 800-232)**
- Throughput without init/padding overhead: Ascon-128 10.6, Ascon-128a 16, Ascon-Hash 5.3, Ascon-Hasha 8 bits/cycle.
- ~11k eq. gates.
- ASIC pre-layout synthesis [E]: TSMC 28HPC 1,900 MHz; 16 nm 2,150; 7 nm 2,300.
- AMD [M?, "sample implementation results", P&R status not stated]: Kintex-7 xc7k420t-3 1,202 LUT at 475 MHz; KU 1,223 LUT at 700 MHz; KU+ 1,211 LUT at 900 MHz.
- AXI4-Stream via separately sold bridges.
— [CAST ASCON-F](https://www.cast-inc.com/security/encryption-primitives/ascon-f)
- [D] 16 bits/cycle = 128 b / 8 cycles for 128a (p8), and 10.6 ≈ 64 / 6 for Ascon-128 (p6). Together with ~1.2k LUT, this is consistent with a 1 round/cycle core with zero absorb-overhead cycles. It's inferred from the bits/cycle figures; the architecture isn't documented. Tag: COMPARE.

**Ledger entry S9: H. Groß, E. Wenger, C. Dobraunig, C. Ehrenhöfer, "Suit up! Made-to-Measure Hardware Implementations of Ascon", DSD 2015, ePrint 2015/034 (pre-2022; foundational, by Ascon co-designer Dobraunig)**
- Design points for RFID / WSN / embedded / max-performance. A "single unrolled round transformation" design is ~7 kGE and up to 5.5 Gbit/s at 0.75 cycles/byte. A threshold implementation is ~8 kGE (3.1× low-area).
- CAESAR-era Ascon-128 (64-bit rate); not SP 800-232.
- Tags: COMPARE; it supports the zero-overhead-absorb idea.
— [ePrint 2015/034](https://eprint.iacr.org/2015/034)
- [D] 0.75 cycles/byte × 8 bytes = 6 cycles per 64-bit block = p6 at 1 round/cycle. So absorb is overlapped with round computation (zero extra cycles). The ePrint abstract page doesn't describe how; I didn't read the full PDF.

**Ledger entry S10: A. Malal, "High-Performance FPGA Implementations of Lightweight ASCON-128 and ASCON-128a with Enhanced Throughput-to-Area Efficiency", ISCTürkiye 2024 (DOI 10.1109/ISCTrkiye64784.2024.10779273), ePrint 2025/825**
- 6 rounds/cycle (Ascon-128) and 4 rounds/cycle (Ascon-128a). — [ePrint 2025/825](https://eprint.iacr.org/2025/825)
- Repo table [M; P&R status and I/O inclusion not stated]:

  | Device | Algorithm | MHz (period) | LUT / FF | Mbit/s (Mbit/s per LUT) |
  |---|---|---|---|---|
  | Artix-7 | 128a | 83.33 (12.0 ns) | 2,183 / 653 | 5,333.3 (2.44) |
  | Artix-7 | 128 | 55.25 (18.1 ns) | 2,957 / 595 | 3,535.91 (1.19) |
  | Kintex-7 | 128a | 158.73 | 3,051 / 653 | 10,158 |
  | Spartan-7 | 128a | 83.33 | 2,178 / 653 | 5,333.33 |

  — [AhmetMALAL/ascon-vhdl](https://github.com/AhmetMALAL/ascon-vhdl)
- [D] Throughput = 64 b / period, i.e. 128 b per 2 cycles for 128a at 4 r/c. That's ceil(8/4) = 2 cycles/block, implying no separate absorb cycle, and it excludes init/final. Not SP 800-232. Tags: COMPARE (same family). It also shows what 4 r/c costs in period on Artix-7 (12 ns, speed grade unstated).

**Ledger entry S11: M. Khairallah, S. Yadhunathan (Seagate), "FPGA Implementations of Message Authentication Codes based on Ascon-p", NIST LWC Workshop 2023 accepted paper**
- Duplex MACs (FSKS-64/128, Ascon-PRF-64/192) as iterative cores with r = 1…12 rounds/cycle, plus Ascon-Farfalle as a "six-stream pipelined implementation" (six-round pipeline, six 320-bit blocks in flight).
- Verilog, Vivado, "Xilinx Artix-7 100t" (same device as the user's). They say "synthesized"; speed grade and P&R status are not stated.
- Table II [M], FSKS-128:

  | Rounds/cycle | LUT | FF | Period |
  |---|---|---|---|
  | 1 | 1,082 | 391 | 5 ns |
  | 2 | 1,728 | 390 | 5 ns |
  | 3 | 2,232 | 391 | 7 ns |
  | 4 | 2,751 | 389 | 7.5 ns |
  | 6 | 3,370 | 390 | 10 ns |
  | 12 | 6,207 | 389 | 20 ns |

- Ascon-Farfalle: 3,863 LUT / 2,634 FF, 4 ns, 1,198 Mbit/s long-message, best throughput/LUT (0.31). They note pipeline registers "come for free" in FPGA slices, citing "Looting the LUTs" (INDOCRYPT 2017).
- These are MACs, not AEAD. Use them as a COMPARE-only proxy for permutation-core period vs rounds/cycle on xc7a100t.
— [NIST LWC 2023 paper PDF](https://csrc.nist.gov/csrc/media/Events/2023/lightweight-cryptography-workshop-2023/documents/accepted-papers/14-fpga-implementations-of-message-authentication-codes.pdf)

**Other 2022–2026 items found (lower confidence, not opened)**
- 2024 Int. J. Information Security (Springer, s10207-024-00904-1): Ascon on 32 nm and 45 nm PDKs with loop-folded, loop-unrolled and fully-unrolled designs. Per the search summary, Ascon-128 loop-folded ≈36.7k µm² vs fully unrolled ≈277.1k µm². ASIC; COMPARE only. — [Springer](https://link.springer.com/article/10.1007/s10207-024-00904-1)
- Reviews: "Review and Analysis of FPGA and ASIC Implementations of NIST Lightweight Cryptography Finalists" (ACM, doi 10.1145/3721122); "The Quest for Efficient ASCON Implementations" (MDPI 2025); Martín-González et al., Electronics Letters 2025 (doi 10.1049/ell2.70260). All returned 403, so they weren't read. The search summary mentions Khan et al. 2023 (6-round unrolled, 3,728 LUT, 792.56 Mbps) and Nguyen et al. (Artix-7, 2.233 Gb/s Ascon-128). These are secondary citations and unverified. — [ACM](https://dl.acm.org/doi/full/10.1145/3721122); [MDPI](https://www.mdpi.com/2674-0729/4/2/15); [Wiley](https://ietresearch.onlinelibrary.wiley.com/doi/10.1049/ell2.70260)
- IEEE Access (Jan 2024; DOAJ listing): Ascon-128/128a on 7-series with 317 MHz on Artix-7 and power 222 mW, per the search summary. Architecture and throughput unknown. COMPARE only, unverified. — [DOAJ](https://doaj.org/article/f5c39c9798d14daebe4b183db805af3e)

### Inferences
- [D] The pattern across independent sources is: separate-absorb designs pay ceil(128/bus)/word cycles per block (Primas, Graz) or 1 cycle (GMU-v1, OpenTitan). Fused designs (Itschner, CAST, Groß, Malal) pay 0. The user's 3 overhead cycles per block are above every published design point reviewed.
- [D] Artix-7 period vs rounds/cycle is sub-linear at low r. Khairallah xc7a100t: 1 → 2 rounds costs ~0 ns, 2 → 3 costs +2 ns, 3 → 4 costs +0.5 ns. The pairs GMU 2r 4.1 ns vs Graz 3r 6.7 ns (−3 grade) and Malal 4r 12 ns show that wrapper and control logic, not just rounds, set the period. The spread between sources is large (7.5 ns vs 12 ns for 4 rounds), so treat these only as order-of-magnitude.
- [D] For p8, r = 3 and r = 4 both give 3 vs 2 cycles. r = 3 yields 3 cycles (3+3+2) with one 2-round cycle that has ~1 round of spare slack.

### Gaps
- I couldn't open the IEEE/ACM/MDPI/Wiley full texts (403), so I found no 2022–2026 peer-reviewed paper explicitly describing "absorb fused into first round" on Artix-7. The evidence is from code (Itschner) and from bits/cycle arithmetic (CAST, Groß, Malal).
- No TCHES/CHES unrolled-Ascon FPGA paper surfaced in my searches. Masked designs were only touched as contrast (OpenTitan DOM planned; Groß TI; DOM GitHub core).
- The Ascon design team's J. Cryptology 2021 paper (Dobraunig, Eichlseder, Mendel, Schläffer, "Ascon v1.2: Lightweight Authenticated Encryption and Hashing", doi 10.1007/s00145-021-09398-9) was not retrievable (Springer redirect). Its hardware statements are not captured here.

---

## Q6. Ready/valid handshake rules and skid buffers for zero-bubble handoffs

### Takeaway
The pipeline-handshake literature gives three rules:
- Transfers happen on any cycle where valid && ready.
- Valid must not depend combinationally on ready in a source, and ready should not depend on valid in a destination (a combinational valid → ready path is allowed only as a deliberate trade-off).
- To get one transfer per cycle, each side keeps its signal asserted after a handshake.

A skid buffer (two registers, ready = !buffer_valid) lets ready be registered without bubbles. For the core, the next block can be accepted on the same edge the permutation's last round cycle writes the state, provided in_ready is asserted from registered state (round-counter == last) and the FIFO presents valid data.

### Cited Findings
**Ledger entry S12: C. E. LaForest, "Pipeline Skid Buffer" (fpgacpu.ca)**
- Two data registers (main output + buffer) with control states Empty / Busy / Full. Input ready is computed from the next state, so there is no combinational path between interfaces. Connecting output ready directly to input ready "defeats the purpose of pipelining". A circular buffer mode gives full throughput with 2-cycle latency. For a 64-bit link, ~128 data FFs plus a few LUTs.
- Tags: ADOPT (output side / FIFO boundary).
— [fpgacpu.ca skid buffer](http://fpgacpu.ca/fpga/Pipeline_Skid_Buffer.html)

**Ledger entry S13: C. E. LaForest, "Ready/Valid Handshake" rules (fpgacpu.ca)**
- A transfer occurs when both are high; "the destination interface accepts the data in the same cycle".
- Valid shall not depend combinationally on ready, and ready not on valid. An addendum permits a combinational valid → ready path as a trade-off if loops, deadlock and livelock are avoided.
- The source must not wait for ready before asserting valid. Once asserted, valid stays high until the handshake completes.
- After a handshake, keep valid/ready high so the next transfer occurs in the very next cycle.
- Internal state that affects an interface may change only on a completed handshake.
- Synchronous reset is recommended because asynchronous reset inhibits retiming.
- Tags: ADOPT.
— [fpgacpu.ca handshake](http://fpgacpu.ca/fpga/handshake.html)

**Ledger entry S14: ZipCPU (Gisselquist Technology), "Building a Skid Buffer for AXI processing", 22 May 2019**
- The skid buffer exists to register a stall/ready signal in a pipeline: `o_ready = !r_valid`. When not stalled it acts as a pass-through. With OPT_OUTREG the output reloads only when `!o_valid || i_ready`.
- Formal properties cover stability under stall, no data loss, and buffer drain.
- Tags: ADOPT; also a formal-property template.
— [ZipCPU skid buffer](https://zipcpu.com/blog/2019/05/22/skidbuffer.html)

**Supporting examples from Ascon cores**
- Itschner accepts the next input beat in the same cycle the permutation output is consumed. The author notes this interlock breaks AXIS compliance, and that an isolator (skid buffer) restores input compliance. — [ascon_aead128_core.v](https://raw.githubusercontent.com/tristanitschner/ascon_cipher_verilog/master/rtl/ascon_aead128_core.v); [README](https://github.com/tristanitschner/ascon_cipher_verilog)
- Primas couples `bdi_ready = bdo_ready` during encryption/decryption message absorb, a combinational input/output dependency. — [ascon_core.sv](https://raw.githubusercontent.com/rprimas/ascon-verilog/main/rtl/ascon_core.sv)
- OpenTitan stalls between permutation calls when the next block isn't available. — [OpenTitan ToO](https://opentitan.org/book/hw/ip/ascon/doc/theory_of_operation.html)

### Inferences
- [D] For a fused-absorb core, define `in_ready = last_round_cycle_q && out_space_q`. last_round_cycle_q is decoded from the round-counter register, or better, a one-hot registered flag set one cycle ahead. out_space_q comes from the registered output-FIFO count. The state register then loads `round_logic(S ⊕ pad(block))` on the handshake edge. No cycle is spent on a separate absorb or handoff state.
- [D] If the input FIFO's empty flag and the output FIFO's full flag are registered, in_ready has no combinational dependency on in_valid. That satisfies LaForest's rule. The cost is that the output FIFO must be able to accept one more block when it signals space, which is exactly what a 2-entry FIFO or skid buffer provides.
- [D] Because the ciphertext C = S_rate ⊕ P is generated on the same edge, the output FIFO write and the input FIFO read must happen on the same cycle. Coupling them through registered flags, rather than combinational ready chaining, keeps them off the critical path.

### Gaps
- I didn't fetch LaForest's Pipeline FIFO Buffer / half-buffer pages or the referenced FPL 2018 latency-insensitive design paper (Abbas & Betz).

---

## Q7. Theoretical minimum cycles/block, tricks to remove absorb/output overhead, and ranked techniques for this core

### Takeaway
I found no paper that states a "theoretical minimum" formula explicitly. The published cycle counts imply ceil(8/r) cycles per 128-bit block in steady state, when the absorb XOR (and ciphertext tap) sits combinationally in front of the first round of the next p8. Examples are Itschner's README formula, the CAST bits/cycle, Groß 0.75 c/B, and Malal 64 b/cycle at r = 4. For r = 3 that gives 3 cycles/block versus the current 6, roughly doubling throughput at equal Fmax. The main risk is the added XOR/pad/mux depth on an already tight 10 ns path. The highest-value adaptations are therefore those that move the absorb into the short (2-round) cycle and pre-register padding.

### Cited Findings
- ceil(8/r) per 128-bit block plus per-message ceil(12/r) × 2 and one pause, in a SP 800-232 core. — [Itschner README](https://github.com/tristanitschner/ascon_cipher_verilog)
- Absorb XOR placed combinationally before the permutation input: `ap_m_data_ds ^ ({192'b0, s_data} << 192)`. Ciphertext = permutation output rate ⊕ input. — [ascon_aead128_core.v](https://raw.githubusercontent.com/tristanitschner/ascon_cipher_verilog/master/rtl/ascon_aead128_core.v)
- 1 overhead cycle per block designs: OpenTitan (8 + 1) and GMU-v1 (4 + 1). — [OpenTitan README](https://github.com/lowRISC/opentitan/tree/master/hw/ip/ascon); [GMU PDF](https://cryptography.gmu.edu/athena/LWC/GMU_LWC_Round_2_FPGA_Benchmarking.pdf)
- Word-serial absorb designs: Primas, Graz (4 or 2 cycles + 8/r). — [ascon_core.sv](https://raw.githubusercontent.com/rprimas/ascon-verilog/main/rtl/ascon_core.sv); [GMU PDF](https://cryptography.gmu.edu/athena/LWC/GMU_LWC_Round_2_FPGA_Benchmarking.pdf)
- Round constants affect only the low byte of S2, c_i = const_(16−rnd+i). Primas computes them arithmetically per unrolled stage from the counter. — [SP 800-232 §3.2](https://csrc.nist.gov/pubs/sp/800/232/final); [asconp.sv](https://raw.githubusercontent.com/rprimas/ascon-verilog/main/rtl/asconp.sv)
- Period vs rounds/cycle on Artix-7 100t: 5 / 5 / 7 / 7.5 / 10 ns for r = 1 / 2 / 3 / 4 / 6 (MAC cores, synthesis). — [Khairallah & Yadhunathan 2023](https://csrc.nist.gov/csrc/media/Events/2023/lightweight-cryptography-workshop-2023/documents/accepted-papers/14-fpga-implementations-of-message-authentication-codes.pdf)
- Multi-stream pipelined permutation (6 streams, 4 ns, 3,863 LUT / 2,634 FF on Artix-7 100t) for a parallel (Farfalle) MAC. — [same](https://csrc.nist.gov/csrc/media/Events/2023/lightweight-cryptography-workshop-2023/documents/accepted-papers/14-fpga-implementations-of-message-authentication-codes.pdf)
- OpenTitan explicitly rejects pipelining for a single AEAD stream because of the inter-permutation dependency. — [OpenTitan ToO](https://opentitan.org/book/hw/ip/ascon/doc/theory_of_operation.html)
- GMU used automated tool-option search (Minerva). It notes that Vivado version and out-of-context mode changed results. — [GMU PDF §4](https://cryptography.gmu.edu/athena/LWC/GMU_LWC_Round_2_FPGA_Benchmarking.pdf)

### Inferences: ranked techniques for the xc7a100t 3-round core
Ranked by expected cycles/block or critical-path benefit vs. risk. All rankings are my deductions from the sources above, not published results for this exact core.

1. **Fuse absorb + ciphertext tap into the permutation cycle boundary (target 6 → 3 clk/block at r = 3).**
   - The state-register input is `round3(S ⊕ (pad(P)‖0^192))` when a block is accepted. C = S[0:127] ⊕ P is taken combinationally from the current state register and the FIFO head.
   - Decrypt variant: replace the rate with C before the rounds.
   - Evidence: S7 (code), S8, S9, S10 (cycle arithmetic).
   - Tag: ADOPT idea / ADAPT implementation.
2. **Reorder p8 as 2+3+3 (short cycle first) and put the absorb XOR / decrypt-replace mux in the 2-round cycle.**
   - Under 3+3+2 the absorb would lengthen a 3-round cycle, which is the existing critical path. Under 2+3+3 it rides on the cycle with ~1 round of slack.
   - Round constants for the first cycle become const indices 8, 9 and the next cycles 10–12 and 13–15 (p8 uses const_8 … const_15). Precompute per cycle slot.
   - Same idea for p12 = 3+3+3+3 with the finalization key XOR (0^128‖K‖0^64). That cycle has no slack, so either keep a separate per-message key-add cycle (amortized; Primas does this in KADD states) or use 2+3+3+3+1.
   - I did not find this specific schedule in the literature (own deduction).
   - Tag: ADAPT.
3. **Pre-register padding, byte-valid masking and domain separation outside the round path.**
   - The input FIFO stage stores the already padded 128-bit block plus a "last/partial" flag, so the absorb is a pure 2-input XOR into S0/S1.
   - Domain separation (MSB of S4) and the key XORs are single-bit/word XORs applied from registered flags.
   - Primas computes `pad(bdi, bdi_valid)` combinationally in the absorb path, which is a counter-example.
   - Tag: ADAPT.
4. **Registered, zero-bubble handshake.** `in_ready` comes from a registered "last round cycle" flag AND registered output-FIFO space. Use a skid buffer or 2-entry FIFO on both sides so no ready signal is chained combinationally through the core (S12–S14). This removes FSM handoff states.
   - Tag: ADOPT.
5. **Simplify the round-count mux.** With mixed 2/3/4-round cycles (p8 = 3+3+2 and p12 = 4×3), the state-register input mux selects among different unroll depths and taps. A uniform r = 3 or r = 4 datapath with one tap (e.g. p12 = 3+3+3+3, p8 = 2+3+3 via a bypass of one round, or a constant-index trick) removes a mux level. Check whether the existing 4-round p12 path is the true critical path. The Khairallah data shows 4 rounds costing ~0.5 ns more than 3 on xc7a100t.
   - Tag: ADAPT (deduction; verify in the timing report).
6. **r = 4 everywhere (p8 = 2, p12 = 3; target 2 clk/block with fused absorb).**
   - Published Artix-7 4-round periods are 7.5 ns (Khairallah, synthesis) to 12 ns (Malal). That likely doesn't close at 100 MHz once absorb, control and FIFO are added on a −1 part.
   - Tag: COMPARE / later experiment.
7. **Tool-level: out-of-context runs, retiming, performance strategies.** GMU's Minerva-style search; synchronous reset to permit retiming (S13).
   - Tag: COMPARE / low-cost experiment.
8. **Multi-stream interleaving / pipelined permutation.** Only valid if the application can supply independent messages (separate nonces under SP 800-232 R3, e.g. per weight chunk). It gives up to k× throughput for k streams at significant FF/LUT cost (S11 Farfalle: 3,863 LUT / 2,634 FF). It is not applicable to a single duplex stream (S5).
   - Tag: COMPARE / ADAPT only if the stream format allows it.

- [D] Expected effect of #1 at the current 100 MHz: 128 b × 100 MHz / 3 = 4.27 Gbit/s steady-state, versus 2.13 Gbit/s now. Per-message overhead (init 4 + final 4 cycles + key adds + padding block) is unchanged and amortized over long weight streams.
- [D] LUT-level reasoning, not from a source: each Ascon round output bit is the XOR of three S-box output bits (linear layer), and each S-box output bit depends on up to 5 state bits. So one round needs ≥2 LUT6 levels. Folding a data XOR and a 2:1 encrypt/decrypt mux in front of the first round adds inputs to the first S-box layer, likely one more LUT level. This is the cost #2 and #3 aim to hide.

### Gaps
- No source states a formal lower bound. ceil(8/r) is inferred from published cycle counts and code.
- I found no published Artix-7 −1 speed-grade post-route numbers for an SP 800-232 core at r = 3 to calibrate the user's +0.038 ns slack.
- The user's actual critical path (from the Vivado timing report) wasn't examined here. Rankings #2 and #5 depend on it.
- Full texts of the 2022–2026 IEEE/ACM/MDPI papers were inaccessible (403), so I may have missed a paper describing technique #2 or multi-lane AEAD interleaving.
