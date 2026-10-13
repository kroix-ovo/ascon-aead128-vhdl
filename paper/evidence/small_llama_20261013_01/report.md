# Small LLaMA training results

Small experimental LLaMA trained from scratch; not Meta pretrained LLaMA 3 weights and not LoRA.

Parameters: 410,496. Architecture: 2 blocks, 128 features, 4 query heads, 2 key/value heads, 384 MLP features.
Training: 500 AdamW steps, 512,000 character targets; seed 20261013.

The source text is split before windows are made: first 90% for training, final 10% for validation. Vocabulary is derived only from training.

| Step | Train loss | Validation loss | Validation perplexity | Validation accuracy |
|---:|---:|---:|---:|---:|
| 0 | 4.173730 | 4.188578 | 65.929 | 2.25% |
| 100 | 2.411573 | 2.425938 | 11.313 | 31.68% |
| 200 | 2.273845 | 2.283303 | 9.809 | 34.88% |
| 300 | 2.155832 | 2.181966 | 8.864 | 36.98% |
| 400 | 2.082398 | 2.089755 | 8.083 | 38.27% |
| 500 | 2.002782 | 2.054294 | 7.801 | 38.98% |

Fixed first 8192 targets per split with 128-character windows; validation never used for optimizer updates.

Saved raw FP32 payload: 1,641,984 bytes, SHA-256 `d1c38f9b274368f989a3c578bb4880003ac821e57faee985ad5bd2841d80b594`.

Reload verification: 0 weight mismatches, maximum logit error 0.0, and loss error 0.0.
Actual trained-weight round trip through adapt_llama_state_dict_keys: maximum error 0.0.

## Tensor structure

| Tensor | Shape | Bytes | Update RMS |
|---|---|---:|---:|
| transformer.wte.weight | 65 x 128 | 33280 | 0.047178 |
| transformer.h.0.ln_1.weight | 128 | 512 | 0.034217 |
| transformer.h.0.attn.c_attn.weight | 256 x 128 | 131072 | 0.044403 |
| transformer.h.0.attn.c_proj.weight | 128 x 128 | 65536 | 0.033273 |
| transformer.h.0.ln_2.weight | 128 | 512 | 0.058779 |
| transformer.h.0.mlp.c_fc.weight | 384 x 128 | 196608 | 0.031182 |
| transformer.h.0.mlp.c_fc2.weight | 384 x 128 | 196608 | 0.032932 |
| transformer.h.0.mlp.c_proj.weight | 128 x 384 | 196608 | 0.034888 |
| transformer.h.1.ln_1.weight | 128 | 512 | 0.055864 |
| transformer.h.1.attn.c_attn.weight | 256 x 128 | 131072 | 0.047574 |
| transformer.h.1.attn.c_proj.weight | 128 x 128 | 65536 | 0.037430 |
| transformer.h.1.ln_2.weight | 128 | 512 | 0.053653 |
| transformer.h.1.mlp.c_fc.weight | 384 x 128 | 196608 | 0.037207 |
| transformer.h.1.mlp.c_fc2.weight | 384 x 128 | 196608 | 0.041797 |
| transformer.h.1.mlp.c_proj.weight | 128 x 384 | 196608 | 0.037917 |
| transformer.ln_f.weight | 128 | 512 | 0.148670 |
| lm_head.weight | 65 x 128 | 33280 | 0.059091 |

## Limits

- Small character-level model; not directly comparable to GPT-2 token-level perplexity.
- Single seed and short run; fixed-prefix evaluation is not a full validation dataset measurement.
- Finite gradients and improved loss are not an independent gradient correctness proof.
- Raw serialization and Meta mapping tested; no encryption or RTL run performed.
