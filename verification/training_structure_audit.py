"""Audit existing checkpoints and test the actual LLaMA conversion functions.

Run in the existing WSL llmc-gpt2 venv. Does not train or overwrite checkpoints.
Synthetic conversion tests are explicitly separate from real GPT-2 evaluation.
"""
import argparse
import ast
import hashlib
import json
import math
import os
import re
from pathlib import Path
import sys
from types import SimpleNamespace

os.environ.setdefault('CUBLAS_WORKSPACE_CONFIG', ':4096:8')
import numpy as np
import torch


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(4 * 1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def conversion_audit(path):
    tree = ast.parse(path.read_text())
    cls = next(n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == 'LLaMA')
    functions = {}
    for node in cls.body:
        if isinstance(node, ast.FunctionDef) and node.name.startswith('adapt_llama'):
            node.decorator_list = []
            ns = {'torch': torch, 'LlamaConfig': SimpleNamespace}
            exec(compile(ast.Module(body=[node], type_ignores=[]), str(path), 'exec'), ns)
            functions[node.name] = ns[node.name]
    cfg = SimpleNamespace(n_layer=2, n_embd=16, n_head=4, n_kv_head=2)
    torch.manual_seed(13)
    source = {}
    mapping = []

    def add(src, dst, shape):
        source[src] = torch.randn(shape)
        mapping.append((src, dst))

    add('tok_embeddings.weight', 'transformer.wte.weight', (32, 16))
    for i in range(2):
        for src, dst in [('attention_norm', 'ln_1'), ('ffn_norm', 'ln_2')]:
            add(f'layers.{i}.{src}.weight', f'transformer.h.{i}.{dst}.weight', (16,))
        for src, rows in [('wq', 16), ('wk', 8), ('wv', 8)]:
            source[f'layers.{i}.attention.{src}.weight'] = torch.randn(rows, 16)
        add(f'layers.{i}.attention.wo.weight', f'transformer.h.{i}.attn.c_proj.weight', (16, 16))
        for src, dst, shape in [('w1', 'c_fc2', (24, 16)), ('w2', 'c_proj', (16, 24)), ('w3', 'c_fc', (24, 16))]:
            add(f'layers.{i}.feed_forward.{src}.weight', f'transformer.h.{i}.mlp.{dst}.weight', shape)
    add('norm.weight', 'transformer.ln_f.weight', (16,))
    add('output.weight', 'lm_head.weight', (32, 16))
    expected = {dst: source[src] for src, dst in mapping}
    for i in range(2):
        expected[f'transformer.h.{i}.attn.c_attn.weight'] = torch.cat([
            source[f'layers.{i}.attention.{s}.weight'] for s in ['wq', 'wk', 'wv']])
    hf = {'model.embed_tokens.weight': source['tok_embeddings.weight'],
          'model.norm.weight': source['norm.weight'], 'lm_head.weight': source['output.weight']}
    for i in range(2):
        for old, new in [('attention_norm', 'input_layernorm'), ('ffn_norm', 'post_attention_layernorm')]:
            hf[f'model.layers.{i}.{new}.weight'] = source[f'layers.{i}.{old}.weight']
        for old, new, heads in [('wq', 'q_proj', 4), ('wk', 'k_proj', 2), ('wv', 'v_proj', 2), ('wo', 'o_proj', 4)]:
            t = source[f'layers.{i}.attention.{old}.weight']
            # Independent inverse layout: interleave the two halves of each head.
            if old in ('wq', 'wk'):
                t = t.reshape(heads, 2, -1, 16).transpose(1, 2).reshape(t.shape)
            hf[f'model.layers.{i}.self_attn.{new}.weight'] = t
        for old, new in [('w1', 'gate_proj'), ('w2', 'down_proj'), ('w3', 'up_proj')]:
            hf[f'model.layers.{i}.mlp.{new}.weight'] = source[f'layers.{i}.feed_forward.{old}.weight']
    results = []
    for name, fixture in [('adapt_llama_state_dict_keys', source), ('adapt_llama_state_dict_keys_hf', hf)]:
        actual = functions[name]({k: v.clone() for k, v in fixture.items()}, cfg)
        assert set(actual) == set(expected), 'Missing or unexpected converted keys'
        errors = [(actual[k] - expected[k]).abs() for k in expected]
        maximum = max(float(e.max()) for e in errors)
        mismatches = sum(int(torch.count_nonzero(e)) for e in errors)
        assert maximum == 0 and mismatches == 0
        results.append(dict(function=name, tensors=len(actual), values=sum(t.numel() for t in actual.values()),
                            max_absolute_error=maximum, mismatched_values=mismatches))
    return dict(scope='Synthetic 2-layer fixtures; mapping, Q/K layout reversal, QKV concatenation. Not trained LLaMA or full forward/gradient equivalence.',
                source_sha256=sha(path), results=results)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--training-root', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    root = args.training_root
    args.output.mkdir(parents=True, exist_ok=True)
    sys.path.insert(0, str(root))
    from train_gpt2 import GPT, GPTConfig
    torch.set_num_threads(4)
    torch.use_deterministic_algorithms(True)
    torch.backends.cuda.matmul.allow_tf32 = False
    torch.backends.cudnn.allow_tf32 = False
    device = 'cuda' if torch.cuda.is_available() else 'cpu'
    paths = [root/'gpt2_124M.bin', root/'runs/ascon_demo_40/gpt2_trained_fp32.bin']
    arrays = []
    headers = []
    for path in paths:
        header = np.fromfile(path, dtype='<i4', count=256)
        assert tuple(header[:2]) == (20240326, 3)
        headers.append(header)
        arrays.append(np.memmap(path, dtype='<f4', mode='r', offset=1024))
    assert np.array_equal(headers[0], headers[1])
    h = headers[0]
    config = GPTConfig(block_size=int(h[2]), vocab_size=int(h[3]), n_layer=int(h[4]), n_head=int(h[5]), n_embd=int(h[6]))
    model = GPT(config).eval()
    named = dict(model.named_parameters())
    names = ['transformer.wte.weight', 'transformer.wpe.weight']
    for suffix in ['ln_1.weight', 'ln_1.bias', 'attn.c_attn.weight', 'attn.c_attn.bias', 'attn.c_proj.weight', 'attn.c_proj.bias',
                   'ln_2.weight', 'ln_2.bias', 'mlp.c_fc.weight', 'mlp.c_fc.bias', 'mlp.c_proj.weight', 'mlp.c_proj.bias']:
        names += [f'transformer.h.{i}.{suffix}' for i in range(config.n_layer)]
    names += ['transformer.ln_f.weight', 'transformer.ln_f.bias']
    assert set(named) == set(names)
    inventory = []
    spans = []
    offset = 0
    for name in names:
        param = named[name]
        count = param.numel()
        before, after = (a[offset:offset+count] for a in arrays)
        assert np.isfinite(before).all() and np.isfinite(after).all()
        delta = after.astype(np.float64) - before
        inventory.append(dict(name=name, shape=list(param.shape), dtype='float32', parameters=count,
            checkpoint_byte_offset=1024+offset*4, tensor_bytes=count*4,
            trained_min=float(after.min()), trained_max=float(after.max()), trained_mean=float(np.mean(after, dtype=np.float64)),
            trained_std=float(np.std(after, dtype=np.float64)), changed_values=int(np.count_nonzero(delta)),
            update_max_absolute=float(np.abs(delta).max()), update_rms=float(np.sqrt(np.mean(delta**2)))))
        spans.append((name, offset, count))
        offset += int(h[7])*config.n_embd if name == names[0] else count
    assert all(offset == len(a) for a in arrays)
    model.to(device)
    evaluations = []
    for path, array in zip(paths, arrays):
        with torch.no_grad():
            for name, start, count in spans:
                named[name].copy_(torch.from_numpy(np.array(array[start:start+count], copy=True).reshape(named[name].shape)).to(device))
        splits = {}
        for split in ['train', 'val']:
            data_path = root/f'dev/data/tinyshakespeare/tiny_shakespeare_{split}.bin'
            dh = np.fromfile(data_path, dtype='<i4', count=256)
            tokens = np.fromfile(data_path, dtype='<u2', offset=1024)
            assert tuple(dh[:2]) == (20240520, 1) and len(tokens) == dh[2]
            losses = []
            correct = 0
            with torch.inference_mode():
                for start in range(0, 1280, 64):
                    x = torch.tensor(tokens[start:start+64].astype(np.int64), device=device)[None]
                    y = torch.tensor(tokens[start+1:start+65].astype(np.int64), device=device)[None]
                    logits, loss = model(x, y)
                    assert torch.isfinite(logits).all() and torch.isfinite(loss)
                    losses.append(float(loss))
                    correct += int((logits.argmax(-1) == y).sum())
            mean = sum(losses)/len(losses)
            splits[split] = dict(data_path=str(data_path), data_sha256=sha(data_path), evaluated_tokens=1280,
                sequence_length=64, batch_losses=losses, mean_cross_entropy=mean,
                perplexity=math.exp(mean), next_token_top1_accuracy=correct/1280)
        evaluations.append(dict(checkpoint=str(path), sha256=sha(path), splits=splits))
        print(f'Evaluated {path.name}', flush=True)
    log = root/'runs/ascon_demo_40/main.log'
    log_values = {'training': [], 'validation': []}
    for line in log.read_text().splitlines():
        step, metric = line.split()
        key, value = metric.split(':')
        log_values['training' if key == 'trl' else 'validation'].append(dict(step=int(step.split(':')[1]), loss=float(value)))
    c_log = args.output/'c_reference_test.log'
    c_result = None
    if c_log.exists():
        text = c_log.read_text()
        assert 'overall okay: 1' in text
        gradients = re.findall(r'^(d\w+)\n(?:.*\n)*?TENSOR OK, maxdiff = ([\deE.+-]+)', text, re.MULTILINE)
        assert len(gradients) == 16
        logits_error = float(re.search(r'OK \(LOGITS\), max_diff = ([\deE.+-]+)', text)[1])
        losses = [float(v) for v in re.findall(r'step \d+: loss ([\d.]+)', text)]
        source_text = (root/'test_gpt2.c').read_text()
        expected_block = re.search(r'expected_losses\[10\] = \{(.*?)\}', source_text, re.DOTALL)[1]
        expected_losses = [float(v) for v in re.findall(r'([\d.]+)f', expected_block)]
        assert len(losses) == len(expected_losses) == 10
        c_result = dict(scope='Existing GPT-2 C reference executable with original checkpoint/debug state; 10 optimizer steps in memory. Not the trained checkpoint or LLaMA.',
            executable_sha256=sha(root/'test_gpt2'), source_sha256=sha(root/'test_gpt2.c'),
            checkpoint_sha256=sha(paths[0]), debug_state_sha256=sha(root/'gpt2_124M_debug_state.bin'),
            log_sha256=sha(c_log), logits_max_absolute_error=logits_error, logits_absolute_tolerance=0.01,
            gradient_tensors=[dict(name=n, max_absolute_error=float(v)) for n, v in gradients],
            gradient_absolute_tolerance=0.02, worst_gradient_max_absolute_error=max(float(v) for _, v in gradients),
            printed_step_losses=losses, reference_step_losses=expected_losses,
            max_step_loss_absolute_error_from_rounded_output=max(abs(a-b) for a,b in zip(losses, expected_losses)),
            step_loss_absolute_tolerance=0.01,
            limitation='Executable was reused; source-to-binary build provenance was not established. Step losses are printed to six decimal places.')
    report = dict(llama_conversion=conversion_audit(root/'train_llama3.py'), c_reference_test=c_result,
        gpt2_config=config.__dict__, gpt2_source_sha256=sha(root/'train_gpt2.py'), device=device,
        precision='FP32, TF32 disabled, deterministic algorithms', tensor_inventory=inventory,
        evaluations=evaluations, historical_log=dict(path=str(log), sha256=sha(log), series=log_values),
        limitations=['No LLaMA checkpoint found; no LLaMA training measured.',
          'Historical training command was not recovered. The val split is not certified unseen: the training script defaults to training on that file.',
          'Current evaluations use only the first 1280 targets of each split, with 64-token context windows.',
          'Weight changes and loss improvements do not independently verify backward-pass implementation.',
          'No new persistent training run or checkpoint changes were performed. The C reference test performs 10 optimizer steps in memory.'])
    (args.output/'report.json').write_text(json.dumps(report, indent=2)+'\n')
    lines = ['# Weight structure and quantitative training audit', '',
        'LLaMA conversion tests use synthetic weights. Training measurements below use existing GPT-2 checkpoints.', '',
        '## LLaMA conversion', '', '| Function | Tensors | Values | Maximum error | Mismatches |', '|---|---:|---:|---:|---:|']
    for r in report['llama_conversion']['results']:
        lines.append(f"| {r['function']} | {r['tensors']} | {r['values']} | {r['max_absolute_error']} | {r['mismatched_values']} |")
    lines += ['', 'The conversion functions have no trainable weights. They rename, concatenate, and (for HF Q/K) reorder base-model weights.', '',
        'The default LLaMA configuration in the inspected source declares 32 blocks, 4096 embedding features, 32 query heads, and 8 key/value heads. Each head has 128 features; the MLP hidden width is 14336. These are declared dimensions, not measured trained LLaMA tensors.', '',
        '| Source (Meta) | Destination | Default shape | Meaning |', '|---|---|---|---|',
        '| tok_embeddings.weight | transformer.wte.weight | 128256 x 4096 | One learned feature vector per token |',
        '| attention_norm / ffn_norm | ln_1 / ln_2 | 4096 each | RMSNorm scale before attention / MLP |',
        '| attention.wq | part of attn.c_attn.weight | 4096 x 4096 | Query projection |',
        '| attention.wk / attention.wv | parts of attn.c_attn.weight | 1024 x 4096 each | Key and value projections |',
        '| Q, K, V combined | attn.c_attn.weight | 6144 x 4096 | Concatenated projection, split into Q/K/V in forward |',
        '| attention.wo | attn.c_proj.weight | 4096 x 4096 | Attention output projection |',
        '| feed_forward.w1 | mlp.c_fc2.weight | 14336 x 4096 | SwiGLU gate projection |',
        '| feed_forward.w3 | mlp.c_fc.weight | 14336 x 4096 | MLP feature projection |',
        '| feed_forward.w2 | mlp.c_proj.weight | 4096 x 14336 | MLP output projection |',
        '| norm.weight | transformer.ln_f.weight | 4096 | Final RMSNorm scale |',
        '| output.weight | lm_head.weight | 128256 x 4096 | Scores for next-token vocabulary |', '',
        'For a linear layer, y = x W^T: each row of W defines one output feature and each column weights one input feature. Weight magnitude alone does not uniquely reveal the network architecture.', '',
        'A block computes x <- x + attention(RMSNorm(x)), then x <- x + W2(SiLU(W1 RMSNorm(x)) * W3 RMSNorm(x)). The multiplication inside the MLP is elementwise.', '',
        'The HF converter reverses the rotary-position layout for Q and K and leaves V unchanged. Its comment says K and V, but the executable code handles Q and K. The synthetic test checks the executable behavior.', '',
        '## Existing GPT-2 evaluation', '', '| Checkpoint | Split | Cross-entropy | Perplexity | Next-token accuracy |', '|---|---|---:|---:|---:|']
    for label, e in zip(['Original checkpoint', 'Trained checkpoint'], evaluations):
        for split, r in e['splits'].items():
            lines.append(f"| {label} | {split} | {r['mean_cross_entropy']:.6f} | {r['perplexity']:.3f} | {100*r['next_token_top1_accuracy']:.2f}% |")
    if c_result:
        lines += ['', '## GPT-2 numerical implementation checks', '',
            f"Existing C reference executable: maximum logit error {c_result['logits_max_absolute_error']:.9f}; worst gradient tensor error {c_result['worst_gradient_max_absolute_error']:.9f} across 16 tensors; maximum 10-step loss error {c_result['max_step_loss_absolute_error_from_rounded_output']:.9f} (rounded console values).", '',
            'These checks use the original checkpoint and its reference debug state. They do not establish trained-checkpoint or LLaMA correctness. The existing binary was reused; build provenance was not established.']
    lines += ['', 'These are fixed-prefix evaluations, not a full dataset score. Historical split isolation is unverified.', '',
        f"Compared {sum(r['parameters'] for r in inventory):,} real GPT-2 parameters; {sum(r['changed_values'] for r in inventory):,} values changed.", '',
        'Full per-tensor shapes, byte offsets, statistics, update magnitudes, hashes, evaluation losses, and historical loss series are in report.json.', '',
        '## Limits', ''] + ['- '+s for s in report['limitations']]
    (args.output/'report.md').write_text('\n'.join(lines)+'\n')
    print('\n'.join(lines), flush=True)


if __name__ == '__main__':
    main()
