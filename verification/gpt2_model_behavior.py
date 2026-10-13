"""Run in the existing WSL training venv; compare the recovered slice in GPT-2.

Loads the complete trained llm.c FP32 checkpoint twice. Only the first 1 KiB
of parameter data in the second model travels through RTL. Hashes bind both
loaded models to the checkpoint and reject serialization/order mistakes.
"""
import os
os.environ["CUBLAS_WORKSPACE_CONFIG"] = ":4096:8"
import argparse
import hashlib
import io
import json
from pathlib import Path
import sys

import numpy as np
import torch
import tiktoken


class HashSink:
    def __init__(self):
        self.hash = hashlib.sha256()
        self.count = 0

    def write(self, data):
        self.hash.update(data)
        self.count += len(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--training-root", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    sys.path.insert(0, str(args.training_root))
    from train_gpt2 import GPT, GPTConfig, write_tensors
    checkpoint = args.training_root / "runs/ascon_demo_40/gpt2_trained_fp32.bin"
    recovered = (args.evidence / "recovered_weights.bin").read_bytes()
    rtl = json.loads((args.evidence / "report.json").read_text())
    assert rtl["result"] == "PASS" and len(recovered) == 1024
    with checkpoint.open("rb") as file:
        header_bytes = file.read(1024)
        source_slice = file.read(1024)
    assert source_slice == recovered
    header = np.frombuffer(header_bytes, dtype="<i4")
    assert tuple(header[:2]) == (20240326, 3)
    config = GPTConfig(block_size=int(header[2]), vocab_size=int(header[3]),
                       n_layer=int(header[4]), n_head=int(header[5]), n_embd=int(header[6]))
    padded_vocab = int(header[7])
    params = np.memmap(checkpoint, dtype="<f4", mode="r", offset=1024)
    recovered_values = np.frombuffer(recovered, dtype="<f4")
    names = ["transformer.wte.weight", "transformer.wpe.weight"]
    for suffix in ("ln_1.weight", "ln_1.bias", "attn.c_attn.weight", "attn.c_attn.bias",
                   "attn.c_proj.weight", "attn.c_proj.bias", "ln_2.weight", "ln_2.bias",
                   "mlp.c_fc.weight", "mlp.c_fc.bias", "mlp.c_proj.weight", "mlp.c_proj.bias"):
        names += [f"transformer.h.{i}.{suffix}" for i in range(config.n_layer)]
    names += ["transformer.ln_f.weight", "transformer.ln_f.bias"]

    def load(replace_slice):
        model = GPT(config)
        named = dict(model.named_parameters())
        assert set(names) == set(named)
        offset = 0
        with torch.no_grad():
            for name in names:
                parameter = named[name]
                count = parameter.numel()
                disk_count = padded_vocab * config.n_embd if name == names[0] else count
                values = np.array(params[offset:offset+count], copy=True)
                if replace_slice and name == names[0]:
                    values[:256] = recovered_values
                parameter.copy_(torch.from_numpy(values.reshape(tuple(parameter.shape))))
                offset += disk_count
        assert offset == len(params)
        # Recreate the exact on-disk tensor ordering and vocabulary padding.
        serialized = dict(model.named_parameters())
        serialized[names[0]] = torch.nn.functional.pad(serialized[names[0]],
                                                     (0, 0, 0, padded_vocab-config.vocab_size))
        sink = HashSink()
        sink.write(header_bytes)
        write_tensors(serialized, config.n_layer, sink, "float32")
        assert sink.count == checkpoint.stat().st_size
        return model, sink.hash.hexdigest()

    file_hash = HashSink()
    with checkpoint.open("rb") as file:
        while data := file.read(4 * 1024 * 1024):
            file_hash.write(data)
    original, original_hash = load(False)
    restored, restored_hash = load(True)
    assert original_hash == restored_hash == file_hash.hash.hexdigest()
    assert all(torch.equal(p, dict(restored.named_parameters())[n])
               for n, p in original.named_parameters())
    torch.use_deterministic_algorithms(True)
    torch.backends.cuda.matmul.allow_tf32 = False
    torch.backends.cudnn.allow_tf32 = False
    assert torch.cuda.is_available()
    original = original.eval().cuda()
    restored = restored.eval().cuda()
    tokenizer = tiktoken.get_encoding("gpt2")
    prompts = ["To be, or not to be", "ROMEO:", "The king shall", "Once upon a time", "The meaning of life is"]
    comparisons = []
    greedy = []
    sampled = []
    max_diff = 0.0
    with torch.inference_mode():
        # Token 0 owns the first 256 embedding values tested by the RTL.
        for prompt, ids in [(p, tokenizer.encode(p)) for p in prompts] + [("explicit_token_0", [0, 1, 2, 3])]:
            tokens = torch.tensor([ids], dtype=torch.long, device="cuda")
            logits_a, _ = original(tokens, targets=tokens)
            logits_b, _ = restored(tokens, targets=tokens)
            assert torch.isfinite(logits_a).all() and torch.isfinite(logits_b).all()
            diff = float((logits_a-logits_b).abs().max().item())
            assert torch.equal(logits_a, logits_b)
            max_diff = max(max_diff, diff)
            comparisons.append(dict(prompt=prompt, tokens=ids, identical_logits=True,
                                    compared_logits=logits_a.numel(), max_absolute_difference=diff))

        def generate(model, ids, stochastic):
            sequence = torch.tensor([ids], dtype=torch.long, device="cuda")
            generator = torch.Generator(device="cuda").manual_seed(20261006)
            for _ in range(24):
                logits, _ = model(sequence)
                scores = logits[:, -1, :]
                if stochastic:
                    threshold = torch.topk(scores, 40).values[:, [-1]]
                    scores = scores.masked_fill(scores < threshold, float("-inf"))
                    next_token = torch.multinomial(torch.softmax(scores / 0.8, dim=-1), 1,
                                                   generator=generator)
                else:
                    next_token = scores.argmax(dim=-1, keepdim=True)
                sequence = torch.cat((sequence, next_token), dim=1)
            return sequence[0].tolist()

        for prompt in prompts:
            ids = tokenizer.encode(prompt)
            for stochastic, dest in ((False, greedy), (True, sampled)):
                a, b = generate(original, ids, stochastic), generate(restored, ids, stochastic)
                assert a == b
                dest.append(dict(prompt=prompt, generated_token_ids=a[len(ids):],
                                 text=tokenizer.decode(a), identical_tokens=True))

        validation = args.training_root / "dev/data/tinyshakespeare/tiny_shakespeare_val.bin"
        with validation.open("rb") as file:
            data_header = np.frombuffer(file.read(1024), dtype="<i4")
            tokens = np.frombuffer(file.read(), dtype="<u2")
        assert tuple(data_header[:2]) == (20240520, 1) and len(tokens) == data_header[2]
        loss_a, loss_b = [], []
        for batch in range(20):
            start = batch * 64
            x = torch.tensor(tokens[start:start+64].astype(np.int64), device="cuda").unsqueeze(0)
            y = torch.tensor(tokens[start+1:start+65].astype(np.int64), device="cuda").unsqueeze(0)
            a, la = original(x, y)
            b, lb = restored(x, y)
            assert torch.equal(a, b) and torch.equal(la, lb)
            loss_a.append(la.item()); loss_b.append(lb.item())
    report = dict(result="PASS", scope="Full-model inference with only the first 1 KiB weight slice replaced by RTL-recovered bytes",
                  checkpoint=str(checkpoint), checkpoint_bytes=checkpoint.stat().st_size,
                  checkpoint_sha256=original_hash, restored_serialization_sha256=restored_hash,
                  recovered_slice_sha256=hashlib.sha256(recovered).hexdigest(),
                  all_parameters_identical=True, device=torch.cuda.get_device_name(0),
                  torch_version=torch.__version__, precision="FP32; deterministic; TF32 disabled",
                  logits=comparisons, max_absolute_logit_difference=max_diff,
                  greedy_generations=greedy, seeded_generations=sampled,
                  new_tokens_per_generation=24, sampling_seed=20261006,
                  validation_batches=20, validation_tokens=1280,
                  validation_batch_losses_original=loss_a, validation_batch_losses_restored=loss_b,
                  validation_mean_loss_original=sum(loss_a)/20,
                  validation_mean_loss_restored=sum(loss_b)/20)
    (args.evidence / "model_report.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
