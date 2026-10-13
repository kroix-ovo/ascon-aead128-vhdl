"""Train a small experimental LLaMA from scratch using the existing model class.

Uses character tokens and a contiguous 90/10 text split. Saves a raw FP32 weight
payload plus a tensor manifest for subsequent encryption; no encryption here.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import random
import sys
import time

os.environ.setdefault('CUBLAS_WORKSPACE_CONFIG', ':4096:8')
import numpy as np
import torch


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--training-root', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--steps', type=int, default=500)
    args = p.parse_args()
    if args.output.exists():
        raise FileExistsError('Choose a fresh output directory to preserve previous evidence')
    args.output.mkdir(parents=True)
    sys.path.insert(0, str(args.training_root))
    from train_llama3 import LLaMA, LlamaConfig
    seed = 20261013
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    torch.cuda.manual_seed_all(seed)
    torch.set_num_threads(4)
    torch.use_deterministic_algorithms(True)
    torch.backends.cuda.matmul.allow_tf32 = False
    torch.backends.cudnn.allow_tf32 = False
    assert torch.cuda.is_available(), 'This run expects the verified WSL GPU'
    source_path = args.training_root/'dev/data/tinyshakespeare/tiny_shakespeare.txt'
    text = source_path.read_text()
    split = int(len(text)*0.9)
    train_text, val_text = text[:split], text[split:]
    alphabet = sorted(set(train_text))
    assert set(val_text) <= set(alphabet), 'Validation has characters absent from training vocabulary'
    encode = {c: i for i, c in enumerate(alphabet)}
    train = torch.tensor([encode[c] for c in train_text], dtype=torch.long, device='cuda')
    val = torch.tensor([encode[c] for c in val_text], dtype=torch.long, device='cuda')
    settings = dict(version='experimental-small', block_size=128, vocab_size=len(alphabet),
        n_layer=2, n_head=4, n_kv_head=2, n_embd=128, ffn_dim_multiplier=1.0,
        multiple_of=64, norm_eps=1e-5, rope_theta=500000.0,
        use_scaled_rope=False, max_gen_batch_size=8, use_kv=False, flash=False)
    model = LLaMA(LlamaConfig(**settings)).cuda()
    # The reference class does not move its plain RoPE tensor with Module.to().
    model.freqs_cis = model.freqs_cis.cuda()
    with torch.no_grad():
        for name, weight in model.named_parameters():
            if weight.ndim == 2:
                torch.nn.init.normal_(weight, mean=0.0, std=0.02)
            else:
                weight.fill_(1.0)
    initial = {n: w.detach().cpu().clone() for n, w in model.named_parameters()}
    optimizer = torch.optim.AdamW(model.parameters(), lr=0.003, weight_decay=0.01)
    batch_generator = torch.Generator(device='cuda').manual_seed(seed+1)
    log = []

    def evaluate(tokens):
        model.eval()
        losses = []
        correct = 0
        with torch.inference_mode():
            for batch in range(8):
                starts = torch.arange(batch*8, (batch+1)*8, device='cuda')*128
                positions = starts[:, None]+torch.arange(128, device='cuda')[None]
                x, y = tokens[positions], tokens[positions+1]
                logits, loss = model(x, y)
                assert torch.isfinite(logits).all() and torch.isfinite(loss)
                losses.append(float(loss))
                correct += int((logits.argmax(-1) == y).sum())
        mean = sum(losses)/len(losses)
        return dict(cross_entropy=mean, perplexity=math.exp(mean),
                    next_character_accuracy=correct/8192, evaluated_targets=8192)

    def record(step):
        entry = dict(step=step, train=evaluate(train), validation=evaluate(val))
        log.append(entry)
        (args.output/'learning_curve.json').write_text(json.dumps(log, indent=2)+'\n')
        print(f"step {step}: train={entry['train']['cross_entropy']:.4f}, validation={entry['validation']['cross_entropy']:.4f}, validation perplexity={entry['validation']['perplexity']:.3f}", flush=True)

    record(0)
    norms = []
    step_losses = []
    torch.cuda.reset_peak_memory_stats()
    torch.cuda.synchronize()
    started = time.perf_counter()
    for step in range(1, args.steps+1):
        model.train()
        starts = torch.randint(0, len(train)-129, (8,), generator=batch_generator, device='cuda')
        positions = starts[:, None]+torch.arange(128, device='cuda')[None]
        optimizer.zero_grad(set_to_none=True)
        _, loss = model(train[positions], train[positions+1], return_logits=False)
        assert torch.isfinite(loss)
        loss.backward()
        norm = torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0, error_if_nonfinite=True)
        norms.append(float(norm))
        step_losses.append(float(loss))
        lr = 0.0003+0.5*(0.003-0.0003)*(1+math.cos(math.pi*(step-1)/args.steps))
        for group in optimizer.param_groups:
            group['lr'] = lr
        optimizer.step()
        if step % 100 == 0 or step == args.steps:
            record(step)
    torch.cuda.synchronize()
    seconds = time.perf_counter()-started
    model.eval()
    weights = {n: w.detach().cpu().contiguous() for n, w in model.named_parameters()}
    torch.save(weights, args.output/'trained_state_dict.pt')
    torch.save(initial, args.output/'initial_state_dict.pt')
    manifest = []
    payload = bytearray()
    for name, tensor in weights.items():
        assert torch.isfinite(tensor).all()
        raw = tensor.numpy().astype('<f4').tobytes()
        delta = tensor.double()-initial[name].double()
        manifest.append(dict(name=name, shape=list(tensor.shape), dtype='float32-le',
            byte_offset=len(payload), byte_count=len(raw), parameters=tensor.numel(),
            min=float(tensor.min()), max=float(tensor.max()), mean=float(tensor.double().mean()),
            std=float(tensor.double().std(unbiased=False)), changed_values=int(torch.count_nonzero(delta)),
            update_max_absolute=float(delta.abs().max()), update_rms=float(torch.sqrt((delta**2).mean()))))
        payload.extend(raw)
    (args.output/'trained_weights_fp32.bin').write_bytes(payload)
    # Reload every weight from the raw encryption payload, then compare model outputs.
    restored = LLaMA(LlamaConfig(**settings)).cuda().eval()
    restored.freqs_cis = restored.freqs_cis.cuda()
    with torch.no_grad():
        restored_named = dict(restored.named_parameters())
        for entry in manifest:
            array = np.frombuffer(payload, dtype='<f4', count=entry['parameters'], offset=entry['byte_offset']).copy()
            restored_named[entry['name']].copy_(torch.from_numpy(array.reshape(entry['shape'])).cuda())
        x, y = val[:128][None], val[1:129][None]
        logits_a, loss_a = model(x, y)
        logits_b, loss_b = restored(x, y)
        weight_mismatches = sum(int(torch.count_nonzero(w-restored_named[n])) for n,w in model.named_parameters())
        logits_error = float((logits_a-logits_b).abs().max())
        assert weight_mismatches == 0 and torch.equal(logits_a, logits_b) and torch.equal(loss_a, loss_b)
    # Test the actual Meta converter on this trained network's real weights.
    meta = {'tok_embeddings.weight': weights['transformer.wte.weight'],
            'norm.weight': weights['transformer.ln_f.weight'], 'output.weight': weights['lm_head.weight']}
    for i in range(2):
        prefix = f'transformer.h.{i}.'
        for old, new in [('attention_norm','ln_1'),('ffn_norm','ln_2')]:
            meta[f'layers.{i}.{old}.weight'] = weights[prefix+new+'.weight']
        q,k,v = weights[prefix+'attn.c_attn.weight'].split([128,64,64], dim=0)
        for old,t in [('wq',q),('wk',k),('wv',v),('wo',weights[prefix+'attn.c_proj.weight'])]:
            meta[f'layers.{i}.attention.{old}.weight'] = t
        for old,new in [('w1','c_fc2'),('w2','c_proj'),('w3','c_fc')]:
            meta[f'layers.{i}.feed_forward.{old}.weight'] = weights[prefix+'mlp.'+new+'.weight']
    converted = LLaMA.adapt_llama_state_dict_keys(dict(meta), model.config)
    assert set(converted) == set(weights)
    conversion_error = max(float((converted[n]-w).abs().max()) for n,w in weights.items())
    assert conversion_error == 0
    # Deterministic text example; not a quality metric.
    sequence = torch.tensor([[encode[c] for c in 'ROMEO:']], device='cuda')
    with torch.inference_mode():
        for _ in range(200):
            logits,_ = model(sequence[:, -128:])
            sequence = torch.cat([sequence, logits[:, -1].argmax(-1)[:,None]], dim=1)
    sample = ''.join(alphabet[i] for i in sequence[0].tolist())
    report = dict(description='Small experimental LLaMA trained from scratch; not Meta pretrained LLaMA 3 weights and not LoRA.',
        config=settings, seed=seed, training_steps=args.steps, batch_size=8, sequence_length=128,
        processed_training_targets=args.steps*8*128, learning_rate_start=0.003, learning_rate_floor=0.0003,
        optimizer='AdamW', gradient_clip=1.0, precision='FP32; deterministic; TF32 disabled',
        source=str(source_path), source_sha256=digest(source_path.read_bytes()),
        model_source_sha256=digest((args.training_root/'train_llama3.py').read_bytes()),
        trainer_sha256=digest(Path(__file__).read_bytes()), torch_version=torch.__version__,
        device=torch.cuda.get_device_name(0), train_characters=len(train_text), validation_characters=len(val_text),
        split_character_offset=split, split_method='Contiguous first 90% training / final 10% validation; windows never cross boundary.',
        tokenizer='Character vocabulary derived from training split only', alphabet=alphabet,
        train_text_sha256=digest(train_text.encode()), validation_text_sha256=digest(val_text.encode()),
        evaluation_scope='Fixed first 8192 targets per split with 128-character windows; validation never used for optimizer updates.',
        learning_curve=log, step_losses=step_losses, gradient_norms_before_clipping=norms,
        seconds_including_periodic_evaluation=seconds, peak_allocated_gpu_bytes=torch.cuda.max_memory_allocated(),
        parameter_count=sum(w.numel() for w in weights.values()), tensor_manifest=manifest,
        weight_payload_bytes=len(payload), weight_payload_sha256=digest(payload),
        serialization_check=dict(weight_mismatches=weight_mismatches, max_logit_absolute_error=logits_error,
            loss_absolute_error=float((loss_a-loss_b).abs()), compared_logits=logits_a.numel()),
        trained_weight_meta_conversion_max_absolute_error=conversion_error, greedy_text_sample=sample,
        limitations=['Small character-level model; not directly comparable to GPT-2 token-level perplexity.',
            'Single seed and short run; fixed-prefix evaluation is not a full validation dataset measurement.',
            'Finite gradients and improved loss are not an independent gradient correctness proof.',
            'Raw serialization and Meta mapping tested; no encryption or RTL run performed.'])
    (args.output/'report.json').write_text(json.dumps(report, indent=2)+'\n')
    (args.output/'config.json').write_text(json.dumps(settings, indent=2)+'\n')
    (args.output/'tensor_manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
    lines = ['# Small LLaMA training results', '', report['description'], '',
        f"Parameters: {report['parameter_count']:,}. Architecture: 2 blocks, 128 features, 4 query heads, 2 key/value heads, 384 MLP features.",
        f"Training: {args.steps} AdamW steps, {report['processed_training_targets']:,} character targets; seed {seed}.", '',
        'The source text is split before windows are made: first 90% for training, final 10% for validation. Vocabulary is derived only from training.', '',
        '| Step | Train loss | Validation loss | Validation perplexity | Validation accuracy |', '|---:|---:|---:|---:|---:|']
    for row in log:
        r=row['validation']
        lines.append(f"| {row['step']} | {row['train']['cross_entropy']:.6f} | {r['cross_entropy']:.6f} | {r['perplexity']:.3f} | {100*r['next_character_accuracy']:.2f}% |")
    lines += ['', report['evaluation_scope'], '',
        f"Saved raw FP32 payload: {len(payload):,} bytes, SHA-256 `{digest(payload)}`.", '',
        f"Reload verification: {weight_mismatches} weight mismatches, maximum logit error {logits_error}, and loss error {report['serialization_check']['loss_absolute_error']}.",
        f"Actual trained-weight round trip through adapt_llama_state_dict_keys: maximum error {conversion_error}.", '',
        '## Tensor structure', '', '| Tensor | Shape | Bytes | Update RMS |', '|---|---|---:|---:|']
    for r in manifest:
        lines.append(f"| {r['name']} | {' x '.join(map(str,r['shape']))} | {r['byte_count']} | {r['update_rms']:.6f} |")
    lines += ['', '## Limits', '']+['- '+s for s in report['limitations']]
    (args.output/'report.md').write_text('\n'.join(lines)+'\n')
    print(json.dumps({k:report[k] for k in ['parameter_count','weight_payload_bytes','serialization_check','trained_weight_meta_conversion_max_absolute_error']}, indent=2), flush=True)


if __name__ == '__main__':
    main()
