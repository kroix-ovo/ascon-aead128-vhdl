> Publication update October 21, 2026: current branch `ascon-weight-stream-fold-absorb`. This is a dated working note. The later AD-padding and decryption-tag-output fixes are complete. Legacy bit-for-bit preservation claims below apply only to the pre-fix snapshot. Final status is in [the report](../../reports/Ascon%20weight%20stream%20bottlenecks.md) and [the fix note](../../docs/ad_padding_fix.md). No physical fold throughput is claimed.

# How the FP32 adapter payload's structure and access patterns affect inline Ascon-AEAD128 cost

Scope: SAGE GPT-2 bottleneck-adapter export `adapter_weights.bin` (2,397,696 B = 599,424 little-endian FP32, tensors `down_w [12,32,768]`, `down_b [12,32]`, `up_w [12,768,32]`, `up_b [12,768]`), protected by the repository's buffered 3-round Ascon-AEAD128 core. This study keeps every byte unchanged and does not weaken security: no quantization, no lossy step, no reduced rounds, and no shortened tags.

Provenance and integrity. Before and after every run, the artifact hashes matched:
- payload `c184175f…a13a98fff8eb`
- checkpoint `7c45c25b…33545672de6`

The scripts also assert that `checkpoint[20:] == payload` and re-hash both files at exit (`post_run_hash_check: PASS`). They read the artifact only; nothing in the adapter project was modified.

Locations:
- Scratch venvs and raw outputs: WSL `~/ascon_weight_structure_scratch/`.
- Summary evidence (not committed): `docs/evidence/handoff_study_weight_structure_20261021/`. It contains `results.json`, `compression_table.csv`, `aead_plans.csv`, `third_party_*.json`, `analyze.py`, `third_party.py`, `run.sh` and `run_tp.sh`.

Measurement labels used throughout:
- **[measured]**: computed on the real bytes, with a round-trip SHA-256 check where it applies.
- **[derived]**: obtained from the repository's measured cycle counts through the cycle model below.
- **[claimed]**: a number from a third-party paper or datasheet.

## Q1. Block alignment, AEAD message plans, per-message fixed overhead, chunking cost and tag overhead

### Takeaway
Every tensor, every per-layer slice and the whole payload are exact multiples of 16 bytes. The same holds for the final remainder of every power-of-two chunk size from 512 B to 1 MiB. So **none of the plans produces a partial final block**, but each message still pays the mandatory empty padding beat.

The fixed cost per message is about 17 clocks with empty AD [derived]. That makes per-tensor (4 messages) or per-layer (12 or 48 messages) authentication essentially free: +0.006% to +0.09% cycles. Fixed-size chunking costs +1.1% at 4 KiB, +0.07% at 64 KiB and +0.004% at 1 MiB. The tag cost is 16 B per message: 0.39% of bytes at 4 KiB and 0.025% at 64 KiB.

### Cited Findings
- **Tensor sizes** [measured]:

  | Tensor | Bytes | 16-byte blocks | Per-layer slice |
  |---|---:|---:|---:|
  | `down_w` | 1,179,648 | 73,728 | 98,304 B |
  | `down_b` | 1,536 | 96 | 128 B |
  | `up_w` | 1,179,648 | 73,728 | 98,304 B |
  | `up_b` | 36,864 | 2,304 | 3,072 B |

  Every value is ≡ 0 mod 16. The total is 149,856 blocks with no remainder. A per-layer bundle (all four slices of one layer) is 199,808 B. Fixed-chunk final remainders (1,536 B at 4 KiB, 5,632 B at 16 KiB, 38,400 B at 64 KiB and 256 KiB, 300,544 B at 1 MiB) are also ≡ 0 mod 16. — [results.json `structure`, `aead_plans`](../../docs/evidence/handoff_study_weight_structure_20261021/results.json)
- **Padding behaviour in the RTL.** A message that ends exactly on a rate boundary "still has a separate padded empty block". For payload, the host sends an empty final beat (`keep=0`, `last=1`). The core XORs the padding bit into the state and goes straight to finalization without p8. A partial final payload block is padded in place, also without p8 before finalization. Partial and aligned endings therefore cost the same number of permutations. — [rtl/ascon_aead128_core.vhd, `ST_AD_PERM_WAIT` / `ST_MSG_WAIT` / `ST_MSG_OUTPUT`](../../rtl/ascon_aead128_core.vhd); [docs/weight_stream_3rpc.md](../../docs/weight_stream_3rpc.md)
- **Measured cycles** for the buffered three-round core: 899,153 per direction on this adapter (266.662 MB/s at 100 MHz), 615,761 on the 1,641,984 B small-Llama payload, and 401 for 1 KiB. All three runs used empty AD, counted from command acceptance through done, with host transfer excluded. — [docs/weight_stream_3rpc.md](../../docs/weight_stream_3rpc.md)
- **Per-message constant** [derived]. Subtracting 6 clk per full block leaves 17 clk in every measured case: 899,153 − 6·149,856 = 17; 615,761 − 6·102,624 = 17; 401 − 6·64 = 17. This 17 covers command acceptance, p12 initialization at 3 rounds per cycle, the empty padding beat, p12 finalization and tag output. — computed from [docs/weight_stream_3rpc.md](../../docs/weight_stream_3rpc.md)
- **AD and partial-block costs** [derived] from the cocotb traffic bench (`overlap` = buffered core; AD length = 3·i bytes for test index i). Unstalled rows:

  | Payload | AD | Clocks |
  |---:|---:|---:|
  | 0 B | 0 B | 19 |
  | 16 B | 9 B | 29 |
  | 32 B | 18 B | 41 |
  | 33 B | 21 B | 43 |
  | 127 B | 24 B | 73 |
  | 1,024 B | 27 B | 413 |
  | 4,096 B | 30 B | 1,565 |

  These rows fit cycles = **6·F + 17 + 2·[final beat partial or empty] + 6·P_AD** exactly, where F is the number of full payload blocks and P_AD = ⌊AD/16⌋+1 AD permutations when AD > 0. The same formula reproduces the measured 899,153 exactly. A 16-byte AD costs 2 AD permutations (12 clk), because a full final AD block also needs its padding absorb plus p8. AD of 15 bytes or less costs 6 clk. — [traffic_metrics.json](../../docs/evidence/weight_stream_3rpc/traffic_metrics.json); [verification/cocotb/test_stream.py L147-149](../../verification/cocotb/test_stream.py)
- **AEAD plan costs** [derived; model reproduces measured single-message]:

  | Plan | Messages | Partial finals | Cycles | Δ vs single | Payload MB/s @100 MHz | Tag bytes (% of payload) |
  |---|---:|---:|---:|---:|---:|---:|
  | single message | 1 | 0 | 899,153 | 0 | 266.66 | 16 (0.0007%) |
  | per tensor | 4 | 0 | 899,204 | +0.006% | 266.65 | 64 (0.003%) |
  | per-layer bundle (4 slices/layer) | 12 | 0 | 899,340 | +0.021% | 266.61 | 192 (0.008%) |
  | per layer × per tensor | 48 | 0 | 899,952 | +0.089% | 266.43 | 768 (0.032%) |
  | 512 B chunks | 4,683 | 0 | 978,747 | +8.85% | 244.98 | 74,928 (3.125%) |
  | 1 KiB chunks | 2,342 | 0 | 938,950 | +4.43% | 255.36 | 37,472 (1.563%) |
  | 4 KiB chunks | 586 | 0 | 909,098 | +1.106% | 263.75 | 9,376 (0.391%) |
  | 16 KiB chunks | 147 | 0 | 901,635 | +0.276% | 265.93 | 2,352 (0.098%) |
  | 64 KiB chunks | 37 | 0 | 899,765 | +0.068% | 266.48 | 592 (0.025%) |
  | 256 KiB chunks | 10 | 0 | 899,306 | +0.017% | 266.62 | 160 (0.007%) |
  | 1 MiB chunks | 3 | 0 | 899,187 | +0.004% | 266.65 | 48 (0.002%) |

  - Adding 8 B of AD per chunk (for example a chunk index) gives +1.50% at 4 KiB and +0.093% at 64 KiB.
  - Adding 16 B of AD gives +1.89% at 4 KiB and +0.117% at 64 KiB.
  - Binding the 20-byte checkpoint header as AD costs 12 clk per message. Binding a 32-byte SHA-256 of the manifest costs 18 clk per message.
  - Storing a nonce per message would add another 16 B per message. This is avoidable when nonces are derived as base+index.

  — [aead_plans.csv / results.json `aead_plans`](../../docs/evidence/handoff_study_weight_structure_20261021/aead_plans.csv)
- **Where the 6 clocks per block go.** Three are round-group clocks. The remaining three are request, completion and block-handling overhead. The experimental full-block mask specialization (`G_FULL_BLOCK_FAST_PATH`) "saved no clocks". It raised area from 3,694 to 3,819 LUTs and cut setup slack from +0.204 to +0.030 ns, and it remains disabled. — [docs/weight_stream_3rpc.md](../../docs/weight_stream_3rpc.md)

### Inferences
- Because no plan has a partial final block, the 2-clock partial-final penalty is zero for this payload under every split. The only alignment-related per-message work left is the mandatory empty padding beat. Ascon requires it whatever the length (see the RTL comment).
- Below 4 KiB, chunking cost grows quickly: the fixed 17 clk per message is about 2.8 block-times. Natural tensor or layer boundaries (4–48 messages) are the cheapest way to get independently authenticated units.
- Chunking does **not** change per-block crypto cost. It only adds per-message cost (init p12, final p12, tag) plus 16 B of tag storage per message.

### Gaps
- The 17-clock constant and the AD/partial terms are fitted from repository simulations (empty AD on the full payload; small AD in the traffic bench). Cycles for a full-payload run with non-empty AD were not simulated here. No HDL simulation was run in this study; all plan cycles are model-derived.
- Host and DMA transfer time is excluded from all cycle figures, as in the repository evidence.

## Q2. Byte and field statistics of the FP32 values

### Takeaway
The weights are dense, nearly all distinct and roughly Gaussian.
- Zero counts: no ±0, no subnormals, no NaN or Inf.
- Distinct values: 99.66%; no value repeats more than 3 times.
- Sign bits and the 23 mantissa bits are close to maximum entropy.
- The 8-bit exponent carries only about 2.73 bits/value of information. Its 4 most significant bits are essentially constant.

The whole compressible redundancy is therefore about 5.3 bits per 32-bit value, an order-0 bound of about 16.6% (whole) or 17.2% (per tensor). It sits in the exponent byte (most of it), with a small residual in the top 7 mantissa bits (6.97 bits instead of 7).

### Cited Findings
All values below are [measured] from [results.json `stats`](../../docs/evidence/handoff_study_weight_structure_20261021/results.json).
- **Whole payload:**
  - Range [−0.12087, 0.11741]; mean 1.09e-4; std 0.018439; median |x| 0.00959.
  - Zero counts: 0 (+0), 0 (−0), 0 subnormal, 0 non-finite.
  - 299,020 negative values (49.9%).
  - Distinct values: 597,390 of 599,424 (99.66%); 4,061 values belong to repeated groups; maximum multiplicity 3.
- **Per-tensor ranges:**

  | Tensor | Range | Std | Distinct values |
  |---|---|---:|---|
  | `down_w` | [−0.1209, 0.1174] | 0.02449 | 99.81% |
  | `down_b` | [−0.0300, 0.0444] | 0.0172 | 100% |
  | `up_w` | [−0.0429, 0.0511] | 0.00943 | 99.80% |
  | `up_b` | [−0.0239, 0.0278] | 0.00776 | 99.99% |

  No tensor has any zero, subnormal or non-finite value.
- **Byte-plane entropy** (little-endian byte 0 → 3) for the whole payload: 7.9997, 7.9997, 7.9703 and 2.8365 bits/byte. Byte 3 holds the sign and the top 7 exponent bits. Byte 2 holds the exponent LSB and the top 7 mantissa bits.
- **Field entropies (whole payload):**
  - Sign: 0.999996 bits.
  - Exponent: **2.730 bits**, over 24 distinct biased exponents in 95…123, i.e. magnitudes about 2^-32…2^-4. The top three exponents are 120 (27.6%), 121 (20.3%) and 119 (20.1%).
  - Mantissa: top 7 bits 6.972; middle 8 bits 7.9997; low 8 bits 7.9997.
  - Per-tensor exponent entropies: `down_w` 2.543 (20 distinct), `up_w` 2.516 (22), `up_b` 2.431 (16), `down_b` 1.874 (9).
- **Bit-plane entropy (whole payload):** bits 0–22 (mantissa) and bit 31 (sign) are all at least 0.98 bits. Exponent bits 23–26 range from 0.968 to 0.999. Bits 27 to 30 are 0.019, 0, 0 and 0 bits.
- **Order-0 bounds:**
  - Fields, whole payload: 2,000,686 B (83.44% of 2,397,696).
  - Byte planes, whole payload: 2,008,532 B.
  - Fields summed per tensor: 1,985,298 B (82.80%).
- **Relation to `adapter_initial.bin`:** 0 of 599,424 values are bit-identical to the initial checkpoint after 200 steps. XOR against the initial checkpoint, then byte-shuffle and zstd-19, gives 2,011,032 B. That is barely better than standalone compression (2,016,675 B) and would require the decoder to hold the reference. — [results.json `vs_initial`](../../docs/evidence/handoff_study_weight_structure_20261021/results.json)

### Inferences
- This payload looks like a "regular" (non-rounded) FP32 model in ZipNN's taxonomy, where only the exponent compresses (see Q4). No exploitable runs, zeros or repeated values exist. Dictionary/LZ coders on raw bytes therefore gain little (around 7%), and XOR-predictive float coders such as Gorilla expand the data.

### Gaps
- Higher-order context models (for example, exponent conditioned on position within a row or column) were not measured beyond what zstd, xz and brotli capture implicitly.

## Q3. Lossless compression measured on the actual bytes, and what it would mean for the crypto pipeline

### Takeaway
The best verified lossless result is a **17.2% saving** (ratio 0.8284). It comes from per-tensor exponent extraction plus brotli-11. Several far simpler schemes come within about 0.5%:
- exponent-only Huffman with raw mantissa bytes, per tensor: 0.8304
- ZipNN 0.5.4 byte mode: 0.8314
- zstd-19 + exponent split: 0.8301

LZ4 gives 0% on raw bytes and 8.7% with byte-shuffle. Gorilla expands the data by 6.3%; fpzip saves 7.9%.

Compress-then-encrypt would cut Ascon blocks and memory or wire bytes by the same ~15–17%. Effective plaintext throughput would rise from 266.7 to about 313–322 MB/s at 100 MHz, but only if a decompressor sustains about 3.1–3.2 plaintext bytes per core clock behind a verify-then-decompress buffer. The cryptographic work per ciphertext block is unchanged.

### Cited Findings
All rows are [measured] and round-trip verified: each reconstructed payload has SHA-256 `c184175f…98fff8eb`. Ratio = compressed bytes / 2,397,696; lower is better. Sources: [compression_table.csv](../../docs/evidence/handoff_study_weight_structure_20261021/compression_table.csv) and [results.json](../../docs/evidence/handoff_study_weight_structure_20261021/results.json).

Transforms:
- **byteshuffle**: Blosc-style 4-plane byte transpose.
- **bitshuffle**: 32 bit-planes.
- **xorprev**: XOR each value with the previous one, then byteshuffle.
- **ee_split**: ZipNN-style split into one exponent byte stream plus three sign/mantissa byte streams, each compressed separately.

**General-purpose codecs, whole payload:**

| Codec | raw | byteshuffle | bitshuffle | xorprev+bs | ee_split |
|---|---:|---:|---:|---:|---:|
| zstd-1 | 0.9263 | 0.8431 | 0.8662 | 0.8519 | 0.8376 |
| zstd-3 | 0.9272 | 0.8520 | 0.8601 | 0.8592 | 0.8466 |
| zstd-19 | 0.9269 | 0.8411 | 0.8555 | 0.8465 | **0.8301** |
| zstd-22 | 0.9269 | 0.8411 | 0.8555 | 0.8465 | 0.8301 |
| lz4 (frame) | 1.0001 | 0.9126 | 0.8751 | 0.9264 | 0.9066 |
| lz4hc-12 | 1.0001 | 0.8689 | 0.8708 | 0.8764 | 0.8632 |
| gzip-6 | 0.9281 | 0.8473 | 0.8610 | 0.8534 | 0.8429 |
| gzip-9 | 0.9281 | 0.8446 | 0.8607 | 0.8514 | 0.8409 |
| xz-6 | 0.9218 | 0.8349 | 0.8523 | 0.8428 | 0.8340 |
| xz-9e | 0.9215 | 0.8324 | 0.8521 | 0.8427 | 0.8318 |
| bz2-9 | 0.9507 | 0.8479 | 0.8731 | 0.8508 | 0.8441 |
| brotli-11 | 0.9153 | 0.8306 | 0.8523 | 0.8421 | 0.8290 |

**Per-tensor compression** (4 units) helps slightly:
- brotli-11 ee_split: 0.8284 (best overall)
- zstd-19 ee_split: 0.8296
- xz-9e ee_split: 0.8323
- zstd-3 ee_split: 0.8462

**Per layer × tensor** (48 units): zstd-19 ee_split 0.8307; zstd-3 ee_split 0.8456. Byteshuffle with zstd-3 degrades to 0.9087 at this granularity.

**Fixed-size independent chunks** (random access):

| Codec / transform | 4 KiB | 64 KiB | 1 MiB |
|---|---:|---:|---:|
| zstd-3 + byteshuffle | 0.9256 | 0.9080 | 0.8518 |
| zstd-3 + ee_split | 0.8674 | 0.8494 | 0.8494 |
| zstd-19 + byteshuffle | 0.8784 | 0.8491 | 0.8425 |
| lz4 + byteshuffle | 0.9772 | 0.9393 | 0.9136 |

A 4-byte length index per chunk adds 2,344 B at 4 KiB and 148 B at 64 KiB.

**Float- and weight-specific codecs:**
- **Exponent-only canonical Huffman + raw 3 mantissa bytes** (own implementation; this is the DFloat11/Huff-LLM idea applied to FP32), including tables and headers:
  - Whole payload: 2,006,424 B (0.8368), maximum code length 20 bits.
  - **Per tensor: 1,991,138 B (0.8304)**, maximum code length 18 bits.
  - This is within 0.3% of the per-tensor order-0 bound (1,985,298 B).
- **ZipNN 0.5.4**, built from the PyPI sdist with `--no-deps`. Torch and safetensors were stubbed because only `input_format='byte'` was used.
  - `bytearray_dtype='float32'`, default method (AUTO) at zstd level 3: whole 1,993,418 B (**0.8314**); per tensor 1,991,587 B (0.8306). Both round-trips were verified.
  - The zstd-19 and explicit `method='HUFFMAN'` configurations **failed the round-trip byte check** in this stubbed install. They are excluded; the cause was not investigated and may be an artifact of the stubbing.
  - Source: [third_party_zipnn_0.5.4.json](../../docs/evidence/handoff_study_weight_structure_20261021/third_party_zipnn_0.5.4.json)
- **ZipNN 0.1.1** (pure Python, 4-way byte grouping + zstd): zstd-3 0.8495 and zstd-19 0.8323, both verified. — [third_party_zipnn_0.1.1.json](../../docs/evidence/handoff_study_weight_structure_20261021/third_party_zipnn_0.1.1.json)
- **fpzip 1.2.5, lossless** (precision=0): whole 1-D 2,208,227 B (0.9210); per tensor with shapes 0.9247. Both verified. — [third_party_fpzip.json](../../docs/evidence/handoff_study_weight_structure_20261021/third_party_fpzip.json)
- **Gorilla XOR codec**, FP32 variant (own implementation, verified): 2,547,557 B (**1.0625, a 6.3% expansion**), both whole and per tensor.
- **Chimp** was not implemented. It is XOR-based like Gorilla and was not expected to help given these mantissa entropies (unmeasured).
- **Blosc2 4.3.3**, verified:

  | Codec | Shuffle | Bitshuffle | No filter |
  |---|---:|---:|---:|
  | ZSTD level 9 | 0.8425 | 0.8578 | 0.9269 |
  | ZSTD level 5 | 0.8463 | 0.8703 | 0.9264 |
  | LZ4 | 0.9296 | 0.8803 | 1.0000 |
  | LZ4HC level 9 | 0.8775 | 0.8723 | 1.0000 |

  — [third_party_blosc2.json](../../docs/evidence/handoff_study_weight_structure_20261021/third_party_blosc2.json)

**Translation to Ascon cycles** [derived with the Q1 model; compressed stream treated as one message unless noted]:

| Scheme | Wire bytes (incl. index) | Ascon cycles | Δ vs 899,153 | Effective plaintext MB/s @100 MHz (if decoder keeps up) |
|---|---:|---:|---:|---:|
| uncompressed | 2,397,696 | 899,153 | 0 | 266.7 |
| lz4 + byteshuffle | 2,188,117 | 820,561 | −8.7% | 292.2 |
| zstd-3 + byteshuffle | 2,042,797 | 766,063 | −14.8% | 313.0 |
| zstd-3 + ee_split | 2,029,990 | 761,263 | −15.3% | 315.0 |
| exp-Huffman + raw mantissa (whole) | 2,006,424 | 752,425 | −16.3% | 318.7 |
| zstd-19 + ee_split | 1,990,447 | 746,431 | −17.0% | 321.2 |
| brotli-11 + ee_split per tensor (best) | 1,986,154 | 744,823 | −17.2% | 321.9 |
| 4 KiB chunks zstd-3 + ee_split, 586 AEAD msgs | 2,082,135 | 791,710 | −11.9% | 302.9 (wire −12.8% incl. tags) |
| 64 KiB chunks zstd-3 + ee_split, 37 msgs | 2,036,722 | 764,389 | −15.0% | 313.7 |
| 1 MiB chunks zstd-19 + byteshuffle, 3 msgs | 2,020,063 | 757,569 | −15.7% | 316.5 |

The chunked rows approximate per-message sizes by equal division of the total; compressed chunks are not 16-byte aligned, so each pays the +2 clk partial-final term. — [results.json `crypto_translation`](../../docs/evidence/handoff_study_weight_structure_20261021/results.json)

- **Decompressor rate needed** [derived]. The core consumes 16 B of ciphertext per 6 clk (2.67 B/clk). At ratio 0.83 the decompressor must emit 3.21 plaintext B/clk, i.e. 0.80 FP32 values/clk (321 MB/s at 100 MHz), to avoid becoming the bottleneck. At ratio 0.852 the figure is 3.13 B/clk.
- **Hardware decompressor reference points** [claimed]:
  - AMD Vitis Libraries on Alveo U200, streaming decompressors:

    | Kernel | Throughput | Clock | LUTs | BRAM | URAM |
    |---|---:|---:|---:|---:|---:|
    | ZStd | 658.86 MB/s | 240 MHz | 23K | 34 | 3 |
    | LZ4 | 1.8 GB/s | 292 MHz | 11K | 15 | 2 |
    | Snappy | 1.97 GB/s | 300 MHz | 12K | 15 | 2 |
    | GZip/Zlib | 518 MB/s | 283 MHz | 6.7K | 8 | 0 |

    The ZStd window is limited to 128 KB. — [Vitis Libraries data_compression benchmark (2022.2)](https://raw.githubusercontent.com/Xilinx/Vitis_Libraries/2022.2/data_compression/docs/src/benchmark.rst); summary also seen via [AMD docs](https://docs.amd.com/r/2022.2-English/Vitis_Libraries/data_compression/benchmark.html_2)
  - CAST LZ4SNP-D decompressor IP: 7.8 bytes/clock in its default configuration, more than 300 MHz on Kintex UltraScale+, and 3,377–5,105 LUTs with 19–20 RAMB on Artix UltraScale+. These figures come from a search-result summary of the vendor brief; the PDF itself was not read. — [CAST LZ4SNP-D brief](https://cast-inc.com/pdfs/cast_lz4snp-d-brief-amd.pdf-0)
  - Huff-LLM's Huffman decoder emits one decompressed weight per clock with no bubbles. It uses 5-bit sub-decoders, each with a 32-entry CAM. Overhead is 6.13% of a 128×128 systolic array in GF12; one decoder is 1,199.3 µm² (L_max = 12). — [Huff-LLM (arXiv 2502.00922)](https://arxiv.org/html/2502.00922v1)
  - A canonical Huffman decoder reaching 408.97 MHz on Artix-7 using about 1% of LUTs (Tariq et al., 2022). This is from a search snippet only. — [ADU repository](https://repository.adu.ac.ae/items/09a8aa8e-228f-41fa-817e-643cf6140608)
  - The repository's buffered Ascon core itself is 3,708 LUTs and 1,680 registers (core-only route). — [docs/weight_stream_3rpc.md](../../docs/weight_stream_3rpc.md)
- **Compression side channel** [claimed]. Compressing before encrypting lets ciphertext length reveal plaintext compressibility. Kelsey described this in 2002. CRIME (2012) and BREACH turned it into practical attacks by mixing attacker-chosen input with secrets in one compression context. Mitigations include length hiding and disabling compression. — [BREACH paper](https://css.csail.mit.edu/6.566/2018/readings/breach.pdf); [Alawatugoda, Stebila, Boyd FC 2015](https://www.douglas.stebila.ca/files/research/papers/FC-AlaSteBoy15.pdf); [breachattack.com](https://breachattack.com/)

### Inferences
- **Byte or plane separation is essential.** On raw interleaved FP32 bytes, every LZ-family codec saves at most about 8.5% (brotli-11; zstd about 7.3%), and LZ4 saves nothing. Separating the exponent byte is what reaches 15–17%.
- **An exponent-only Huffman decoder is the most hardware-plausible design.** It gets within about 0.2–0.5% of the best verified result, and the mantissa passes straight through as 3 raw bytes per value.
  - One exponent symbol per clock delivers 1 value/clk (4 B/clk). That exceeds the 0.80 values/clk needed behind this core at the same clock, so a single small decoder would not be the bottleneck.
  - Code length must be limited for hardware (for example ≤ 11–12 bits; Huff-LLM uses L_max = 12). The unconstrained code here reaches 18–20 bits. The ratio cost of length-limiting was not measured, but is expected to be small because those long codes cover rare exponents.
- **A Zstd hardware decoder could become the bottleneck.** Scaling the Vitis ZStd decoder's 2.75 B/clk to the core's clock gives less than the 3.13 B/clk needed at zstd ratios. This is an inference that assumes bytes/clock is roughly clock-independent, and it would cost about 6× the Ascon core's LUTs. LZ4 hardware is fast enough but only reaches ratio 0.87–0.91 with shuffling.
- **Required ordering.** Encryption must be compress-then-encrypt; encrypt-then-compress is useless because ciphertext is incompressible. On the load path the order is authenticate/decrypt, then decompress.
  - The core's decryption output is provisional until `commit_o`. A decompressor must therefore consume only committed plaintext, both to keep the authentication contract and to avoid parsing unauthenticated, attacker-controlled compressed data.
  - With one message, that means quarantining the whole ~2.0 MB compressed message before decompression starts, so no decrypt/decompress overlap.
  - Per-chunk AEAD (for example 64 KiB) allows a verify-then-decompress pipeline with a chunk-sized quarantine. It costs +0.07% cycles and 16 B of tag per chunk, plus the ratio loss shown above (0.849 vs 0.830).
- **Side-channel exposure is low but not zero.** Weights are static and compressed offline once, with no attacker-controlled data mixed into the compression context, so CRIME/BREACH-style adaptive attacks do not directly apply. Per-chunk compressed lengths still leak per-chunk compressibility, which reflects exponent spread per tensor or layer. Repeated re-encryption of evolving fine-tuned checkpoints could leak change patterns. Padding each compressed chunk to a fixed bucket removes the leak at the cost of part of the saving.
- **Effect on transfer bytes.** Compression shrinks transfer and storage bytes and Ascon block count by the same ~15–17%. Codec framing is small: zstd frame headers are included in the measured sizes, and the ee_split stream-length fields add 16 B per unit. It introduces a second datapath (decoder plus buffering) whose area likely exceeds the Ascon core's.

### Gaps
- No hardware decompressor was synthesized. The decoder throughput and area figures above are vendor or paper claims on other devices and clocks.
- ZipNN 0.5.4's zstd-19 and Huffman modes failed round-trip only under a torch-stubbed install. A full install with torch was avoided (multi-GB CUDA dependencies), so it is unknown whether this is a ZipNN bug or a stub artifact.
- The software throughputs in the JSON are single-threaded Python/WSL figures, for information only.
- Chimp and Chimp128 were not run.

## Q4. Literature ledger: lossless weight and float compression and hardware decoders

### Takeaway
The literature agrees with the measurements above.
- For "regular" FP32 weights, only the exponent compresses. ZipNN reports about 17% savings (about 83% size) for FP32 models, against about 33% for BF16. Our adapter: 16.9–17.2%.
- The BF16-focused entropy coders (DFloat11, Huff-LLM, NeuZip, ZipServ) get about 30% because BF16 has a smaller mantissa share. DFloat11 is BF16-specific and does not apply directly to FP32, though the same exponent-entropy idea transfers.
- Hardware Huffman decoders that emit one weight per clock exist, at a few percent of accelerator area.

### Cited Findings

| Title | Authors | Year / venue | Finding | Applicability to this FP32 adapter | Status |
|---|---|---|---|---|---|
| [ZipNN: Lossless Compression for AI Models](https://arxiv.org/html/2411.05239v2) | Hershcovitch, Wood, Choshen, Girmonsky, Leibovitz, Ennmouri, Malka, Chin, Sundararaman, Harnik | 2024 arXiv; v2 2025; comment says IEEE Cloud, unconfirmed | BF16 ≈66.4% size, regular FP32 ≈83% (Wav2vec 83.3%, Bert 83.0%, Olmo 83.1%). "Clean" (rounded) FP32 models compress to 33.7–48.1%. Exponent compresses about 3× with Huffman; fraction and sign "hardly compress". Olmo-1b FP32: zstd 92.3% → ZipNN 83.2%. Byte-group size 64 KB for FP32; chunk size 256 KB. Up to 80 GB/s decompression multi-threaded. | Directly applicable. Adapter measures 83.1% with ZipNN 0.5.4 and 92.7% with zstd-3 raw, matching the "regular FP32" class. | Claimed by paper; matched by our measurement |
| [DFloat11 ("70% Size, 100% Accuracy")](https://arxiv.org/abs/2504.11651) | T. Zhang, Hariri, Zhong, Chaudhary, Sui, Hu, Shrivastava | 2025, NeurIPS 2025 | BF16 only. Entropy-codes the exponent to about 70% size, bit-exact; 2.3–46.2× token throughput vs CPU offload; 405B model on 8×80 GB. | Not directly applicable (BF16 format). Our FP32 exponent-Huffman analogue gives 83.0%. | Claimed |
| [Huff-LLM](https://arxiv.org/html/2502.00922v1) | Yubeaton, Mahmoud, Naga, Taheri, Xia, George, Khalil, S. Q. Zhang, Joshi, Hegde, Garg | 2025 arXiv | FP16 1.17–1.47×, BF16 1.37–1.38×; FP32 not evaluated. Decoder emits one weight per clock; 6.13% area of a 128×128 array (GF12). Latency −13 to −31%; energy −3 to −26%. | Decoder architecture is applicable to an FP32 exponent stream. Ratio for FP32 would be about 1.2× (ours: 1.20×). | Claimed |
| [NeuZip](https://arxiv.org/html/2410.20650v1) | Hao, Cao, Mou | 2024, NeurIPS 2024 | Exploits low entropy of floating-point exponents. Llama-3 8B training memory 31 GB → under 16 GB; lossless for training, near-lossless for inference. | Its lossless exponent part matches our finding. Its inference memory savings involve a lossy mantissa step, which is excluded here. | Claimed (search summary of arXiv/NeurIPS pages) |
| [ZipServ](https://arxiv.org/abs/2603.17435) | Fan, Yu, Pan, Li, Luo, Q. Wang, W. Wang, Chu | 2026, ASPLOS'26 | Fixed-length, Tensor-Core-aware triple-bitmap encoding with fused decompress-GEMM. Up to 30% smaller; up to 2.21× kernel speedup vs cuBLAS; 1.22× end to end vs vLLM. | GPU-side; shows fixed-length decodable formats avoid variable-length decoder serialization. Not measured on FP32. | Claimed |
| EntroLLM ([arXiv 2505.02380](https://arxiv.org/pdf/2505.02380v2)) | — | 2025 arXiv | Huffman coding of quantized weights; up to 30% storage reduction vs uint8. | Not applicable (quantized). | Claimed (search snippet only) |
| [Gorilla](https://www.vldb.org/pvldb/vol8/p1816-teller.pdf) | Pelkonen et al. | 2015 VLDB | XOR-with-previous float coding for time series. | Measured on adapter: 106.3% (expansion). Weights lack temporal smoothness. | URL from prior knowledge, not fetched; measured locally |
| [Chimp](https://vldb.org/pvldb/vol15/p3058-liakos.pdf) | Liakos, Papakonstantinopoulou, Kotidis | 2022 PVLDB 15(11) | Improved XOR float coder for time series; Chimp128 variant. | Not run; expected to share Gorilla's limitation (inference). | Paper metadata confirmed via search |
| fpzip (Lindstrom & Isenburg, "Fast and Efficient Compression of Floating-Point Data") | Lindstrom, Isenburg | 2006 IEEE TVCG | Predictive lossless or lossy float coder for gridded data. | Measured lossless: 92.1% (whole), 92.5% (shaped per tensor). | Measured; no paper URL fetched this session |
| [AMD Vitis Libraries data compression](https://raw.githubusercontent.com/Xilinx/Vitis_Libraries/2022.2/data_compression/docs/src/benchmark.rst) | AMD/Xilinx | 2022.2 docs | U200 decompressors: ZStd 658.86 MB/s, 23K LUT; LZ4 1.8 GB/s, 11K LUT; GZip 518 MB/s, 6.7K LUT. | Sizing reference for an FPGA decompressor behind the core. | Claimed |
| [CAST LZ4SNP-D](https://cast-inc.com/pdfs/cast_lz4snp-d-brief-amd.pdf-0) | CAST Inc. | vendor brief | 7.8 B/clk; >300 MHz; 3.4–5.1K LUT. | LZ4 ratios on this payload are poor (0.87–0.91 with shuffle). | Claimed (search summary) |
| [Criminology: refined compression side-channel attacks](https://eprint.iacr.org/2026/1972.pdf) | Song, Mareková, Paterson | 2026 ePrint | Refined compression side-channel techniques (abstract only seen). | Context for length-leak risk. | Not read beyond search snippet |

### Inferences
- Published FP32 results (about 83%) and our adapter (82.8–83.1% best) agree to within about 0.5 percentage points. Further lossless gains on this payload are therefore unlikely without changing the bytes, for example by rounding.

### Gaps
- No FPGA paper found reports an FP32-exponent-specific Huffman decoder with measured throughput and area on a Xilinx 7-series part comparable to this board.
- Huff-LLM's figures are for an ASIC (GF12).

## Q5. Access patterns in the adapter and GPT-2 code, and what predeclared metadata allows

### Takeaway
The CUDA inference and training code loads the **entire adapter at once**. It reads the 20-byte header, then the four tensor groups sequentially into one contiguous device allocation, before any forward pass. The forward pass then reads one layer's slice from each of the four tensors at strided offsets, from device memory.

So per-layer or per-tensor authenticated chunks would not enable useful random access or load/compute overlap in the current software. They would only bound the verify-then-release quarantine buffer and enable multi-core parallel Ascon. All lengths are known ahead of time from the 20-byte header and the manifest.

### Cited Findings
All files below were inspected read-only in `/home/kroix/projects/SAGE_Adapter_Experiment/llmc-gpt2/`.
- **`load_adapter()` reads the whole file in order.** `gpt2_generation.cu` L1788–1806 and `inference_adapter.cu` L607–624 read 5 ints (B, L, C, r, T), then call `file_to_device` four times: `down_w` (L·C·r), `down_b` (L·r), `up_w` (L·r·C), `up_b` (L·C), then `cudaStreamSynchronize`.
- **The transfer is a single chunk.** `file_to_device` (`llmc/cuda_common.h` L169+) double-buffers through pinned host memory with `IO_BUF_SIZE` = 32 MiB (`gpt2_generation.cu` L82). The 2.4 MB adapter is therefore one read plus one H2D copy per tensor group.
- **One device allocation, in tensor-major order.** `allocate_adapters()` (`gpt2_generation.cu` L405–431) makes one `cudaMalloc` for all adapter parameters, laid out `down_w | down_b | up_w | up_b` exactly as in the file.
- **Per-layer slices are strided across the four tensors.** In the forward pass (L997–1003, and similarly in `inference_adapter.cu` L767–769 and the backward pass at L1235–1243), layer `l` uses `down_w + l·C·r`, `down_b + l·r`, `up_w + l·r·C` and `up_b + l·C`. These are four discontiguous slices of 98,304 / 128 / 98,304 / 3,072 B.
- **PyTorch paths also read whole files.** `adapter_io.parse_checkpoint` reads the whole file (`read_bytes`), and `load_groups` copies by tensor group, then per layer.
- **Export and verification.** `export_adapter_weights.py` writes header-stripped bytes and pads to 16 only if needed (0 padding here). `model_verification.json` records 0 of 599,424 mismatched values and a maximum logit error of 0.0 on the fixed input.
- **Lengths are fully predeclared.** The header `[B, L, C, r, T]` = (2, 12, 768, 32, 64) determines every tensor length, and `manifest.json` records offsets, lengths and hashes. — `runs/adapter_fp32_200/export/manifest.json`

### Inferences
- **Random access.** Nothing in the current code fetches one layer's weights on demand, so per-layer AEAD messages give no random-access benefit today.
  - Overlapping decryption with layer compute would require changes to the load path. Possible approaches include per-layer events or a lazy loader.
  - Even then, the adapter's 9 ms decrypt time is small next to the frozen GPT-2 base weights that `gpt2_build_from_checkpoint` loads separately in the same session.
- **Per-layer messages without changing stored bytes.** A message can be defined as a gather list of the four strided slices of a layer (199,808 B), described by DMA descriptors, while ciphertext keeps the original file layout. Every slice is a multiple of 16, so gather boundaries fall on block boundaries and the gather costs no padding.
- **Predeclared lengths and the "last/keep" decision.** The decision cannot be skipped entirely: Ascon must still pad, and an aligned message still needs the empty padding step. A length-preloaded command interface could:
  - (a) let the core apply the final padding internally instead of requiring the host's empty `keep=0`, `last=1` beat, saving about one handshake per message;
  - (b) treat `keep` as constant `FFFF` for all but the last beat;
  - (c) let the controller check the declared length against beats received, which is a protocol-integrity check.

  The repository's own experiment shows that specializing the full-block mask saved 0 clocks and cost area and slack. Gains from (a) and (b) are therefore controller simplification or host-side work, not throughput.
- **Binding layout metadata.** The header or manifest hash can be bound as AD to authenticate the layout. This costs 12 clk per message for the 20-byte header and 18 clk for a 32-byte hash.

### Gaps
- `train_adapter.cu`'s full training loop was only grepped, not traced line by line. Its `load_adapter` matches the version in `gpt2_generation.cu`.
- Any FPGA- or kernel-driver-side loader for adapters (the repo mentions an "FFN accelerator: FPGA, kernel driver") was not inspected.

## Q6. Conclusions: what actually saves cycles, controller work or bytes

### Takeaway
**FP32 structure cannot be used to skip cryptographic work.** Ascon-AEAD128 must absorb every 16-byte block of the exact plaintext or ciphertext with a full p8, plus p12 for initialization and finalization. Data values, exponent redundancy, alignment or known lengths cannot reduce rounds or blocks without changing the bytes or weakening security.

What structure buys:
- Cheap, perfectly aligned message boundaries for independent authentication and parallelism.
- Small controller simplifications.
- About 17% fewer bytes through lossless compression, at the price of a separate decompressor datapath and a verify-then-decompress buffer.

### Cited Findings
- **Per-block cost is fixed by the permutation and controller handshake.** 6 clk per full block: 3 round groups plus 3 overhead. Unrolling plus buffering gave about 2× over the one-round baseline. The mask fast path saved 0 clk. — [docs/weight_stream_3rpc.md](../../docs/weight_stream_3rpc.md)
- **All natural partitions are block-aligned,** with fixed costs of 0.006–0.09% (Q1). — [aead_plans.csv](../../docs/evidence/handoff_study_weight_structure_20261021/aead_plans.csv)
- **Multi-core makespans** [derived; LPT greedy schedule; cycle model per message; assumes memory can feed every core]:

  | Plan | 2 cores | 4 cores | 8 cores |
  |---|---|---|---|
  | per-layer bundles (12 msgs) | 449,670 clk (533 MB/s) | 224,835 clk (1,066 MB/s) | 149,890 clk (1,600 MB/s) |
  | per layer × tensor (48 msgs) | 449,976 clk | 224,988 clk | 112,981 clk (2,122 MB/s) |
  | 64 KiB chunks | 457,091 clk | 235,754 clk | 122,965 clk |
  | per tensor (4 msgs) | 456,226 clk (526 MB/s) | — | — |
  | single message | 899,153 clk (any core count) | | |

  Per-tensor plateaus at 442,385 clk because of the two 1.18 MB tensors, and 1 MiB chunks plateau at 393,233. Each additional buffered core costs about 3.7K LUTs and 1.7K registers (core-only). — computed here; core area from [docs/weight_stream_3rpc.md](../../docs/weight_stream_3rpc.md)

### Inferences
**Genuinely reduce cycles or latency (structure-enabled, crypto unchanged):**
- **Parallel independent AEAD messages.** Per-layer or per-tensor messages with distinct nonces, for example base+index, run on N core instances. This is the only structure-derived route to large throughput gains (near-linear up to 4–8 cores for 12–48 layer messages). Costs:
  - N× core area;
  - N× memory bandwidth (the cipher stops being the bottleneck at about 1 GB/s);
  - 17 clk and 16 B of tag per message;
  - nonce-management care.

  Each message remains a full-strength Ascon-AEAD128 instance.
- **Per-chunk authentication** shrinks the decryption quarantine. Release can then follow each chunk's commit, and the time to the first usable tensor or layer drops from the whole payload (9.0 ms) to one chunk, e.g. about 0.75 ms per layer bundle. This needs software that consumes data incrementally, which the current CUDA loader does not.

**Reduce controller or host work only (about 0 cycles):**
- Known lengths and all-full-block streams let the host emit constant `keep=FFFF`. They also allow a length-preloaded command that applies the final padding internally (saving one empty beat per message) and a check of the declared length against beats received.
- The partial-final keep-mask logic is never exercised by this payload's natural partitions. Removing it from the datapath saved nothing in the repository's experiment.

**Reduce transferred or stored bytes, and Ascon blocks in proportion (not a crypto speedup per block):**
- Lossless compress-then-encrypt. Measured, verified:
  - 15.3% with zstd-3 + exponent split;
  - 16.3–17.0% with exponent-only Huffman (whole or per tensor);
  - 17.0% with zstd-19 + exponent split;
  - 17.2% best.

  Ascon cycles fall in proportion (about 899K → about 745–761K). End-to-end gains require a decoder sustaining at least 3.1–3.2 B/clk and an authenticated-before-decompress buffer.
- The best hardware fit is a length-limited exponent Huffman decoder (1 value/clk) with mantissa bypass.
- Fixed-chunk random access below 64 KiB erodes the ratio: 0.867 at 4 KiB vs 0.849 at 64 KiB for zstd-3 + ee_split.

**Merely shift cost:**
- Compression moves work from the cipher to a decompressor that is larger and more complex: Zstd at about 23K LUTs is about 6× the Ascon core, and its decode rate may be too low. It also adds an encoder step at export, a variable-length format and length-leak considerations.
- AD binding of metadata adds 6–18 clk per message.
- Fine-grained chunking (< 4 KiB) trades random-access granularity for +1.1% to +8.9% cycles and 0.4–3.1% tag storage.
- Delta or XOR coding against the initial checkpoint gives about 0.3% extra and needs the reference at the decoder.
- Gorilla-style XOR codecs and fpzip are worse than byte-grouped entropy coding on these weights.

### Gaps
- No RTL changes, multi-core synthesis or decompressor integration were attempted. The multi-core and compression throughput numbers are model-derived, not simulated.
- Memory or DMA bandwidth limits of the target board were not characterized here. They will cap multi-core scaling.
