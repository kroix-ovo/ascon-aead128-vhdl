"""Independently verify the saved small-LLaMA files from disk, without training."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import numpy as np
import torch

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--training-root', type=Path, required=True)
p.add_argument('--run', type=Path, required=True)
p.add_argument('--weights', type=Path, help='Optional recovered raw payload to verify against the trained checkpoint')
args = p.parse_args()
sys.path.insert(0, str(args.training_root))
from train_llama3 import LLaMA, LlamaConfig
report = json.loads((args.run/'report.json').read_text())
payload_path = args.weights or args.run/'trained_weights_fp32.bin'
payload = payload_path.read_bytes()
assert hashlib.sha256(payload).hexdigest() == report['weight_payload_sha256']
assert len(payload) == report['weight_payload_bytes']
assert hashlib.sha256((args.run/'trainer_used.py').read_bytes()).hexdigest() == report['trainer_sha256']
checkpoint = torch.load(args.run/'trained_state_dict.pt', map_location='cpu', weights_only=True)
decoded = {}
position = 0
for entry in report['tensor_manifest']:
    assert entry['byte_offset'] == position
    array = np.frombuffer(payload, dtype='<f4', count=entry['parameters'], offset=position).copy()
    decoded[entry['name']] = torch.from_numpy(array.reshape(entry['shape']))
    assert torch.equal(decoded[entry['name']], checkpoint[entry['name']])
    position += entry['byte_count']
assert position == len(payload) and set(decoded) == set(checkpoint)
torch.set_num_threads(4)
models = [LLaMA(LlamaConfig(**report['config'])).eval() for _ in range(2)]
models[0].load_state_dict(checkpoint, strict=True)
models[1].load_state_dict(decoded, strict=True)
text = Path(report['source']).read_text()[report['split_character_offset']:]
lookup = {c: i for i,c in enumerate(report['alphabet'])}
tokens = torch.tensor([[lookup[c] for c in text[:129]]])
with torch.inference_mode():
    a,la = models[0](tokens[:,:128], tokens[:,1:129])
    b,lb = models[1](tokens[:,:128], tokens[:,1:129])
assert torch.equal(a,b) and torch.equal(la,lb)
result = dict(scope='Fresh CPU models loaded from files on disk: state_dict versus raw FP32 payload',
    payload_path=str(payload_path),
    tensors_checked=len(decoded), values_checked=sum(t.numel() for t in decoded.values()),
    weight_mismatches=0, compared_logits=a.numel(), max_absolute_logit_error=float((a-b).abs().max()),
    absolute_loss_error=float((la-lb).abs()), trainer_snapshot_hash_matches=True,
    payload_sha256=hashlib.sha256(payload).hexdigest())
destination = payload_path.parent/'recovered_model_verification.json' if args.weights else args.run/'disk_verification.json'
destination.write_text(json.dumps(result, indent=2)+'\n')
print(json.dumps(result, indent=2))
