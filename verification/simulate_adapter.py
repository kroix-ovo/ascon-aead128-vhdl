"""Compare complete FP32 adapter weights at a 10 ns simulated clock.

Uses existing artifacts only. No training, synthesis, programming, or download.
The export manifest identifies four contiguous tensor groups. A supplied original
checkpoint must contain the exact export after its 20-byte format header.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def validate(weights, manifest, checkpoint=None):
    payload = weights.read_bytes()
    metadata = json.loads(manifest.read_text())
    if metadata['dtype'] != 'float32' or metadata['padding_bytes'] != 0:
        raise ValueError('Expected an unpadded FP32 adapter export')
    digest = hashlib.sha256(payload).hexdigest()
    if digest != metadata['original_payload_sha256'] or len(payload) != metadata['original_payload_bytes']:
        raise ValueError('Weight export does not match manifest')
    tensors, offset = [], 0
    layers, channels, rank = (metadata[k] for k in ['layers', 'channels', 'rank'])
    expected_shapes = [('down_w', [layers, rank, channels]), ('down_b', [layers, rank]),
                       ('up_w', [layers, channels, rank]), ('up_b', [layers, channels])]
    if [(t['name'], t['shape']) for t in metadata['tensor_manifest']] != expected_shapes:
        raise ValueError('Unexpected adapter group names, order or dimensions')
    for entry in metadata['tensor_manifest']:
        size = math.prod(entry['shape']) * 4
        if entry['bytes'] != size or entry['payload_byte_offset'] != offset:
            raise ValueError('Noncontiguous or incorrectly sized tensor group')
        tensors.append(dict(name=entry['name'], shape=entry['shape'], dtype='float32-le',
                            byte_offset=offset, byte_count=size))
        offset += size
    if offset != len(payload) or len(payload) < 1024 or len(payload) % 16:
        raise ValueError('Payload must contain all tensor groups and full 16-byte blocks')
    if checkpoint:
        raw = checkpoint.read_bytes()
        header = tuple(metadata[k] for k in ['batch','layers','channels','rank','sequence_length'])
        if raw[20:] != payload or struct.unpack('<5i', raw[:20]) != header:
            raise ValueError('Checkpoint header/body does not match adapter export')
        if hashlib.sha256(raw).hexdigest() != metadata['checkpoint_sha256']:
            raise ValueError('Checkpoint hash does not match manifest')
    return tensors, digest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('weights', type=Path)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--checkpoint', type=Path)
    parser.add_argument('--output', type=Path, required=True, help='Fresh evidence directory')
    parser.add_argument('--nonce-base', type=int, required=True, help='Unused public test nonce range (four messages)')
    parser.add_argument('--candidate', choices=['u3-buffered', 'u3-fold'], default='u3-buffered',
                        help='Accelerated configuration compared with the baseline (u3-fold = G_FOLDED_ABSORB)')
    args = parser.parse_args()
    tensors, digest = validate(args.weights, args.manifest, args.checkpoint)
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    tensor_manifest = out/'tensor_manifest.json'
    tensor_manifest.write_text(json.dumps(tensors, indent=2)+'\n')
    subprocess.run([sys.executable, str(ROOT/'verification/compare_stream.py'), str(args.weights.resolve()),
                    '--manifest', str(tensor_manifest), '--output', str(out/'runs'),
                    '--variants', 'baseline', args.candidate, '--nonce-base', str(args.nonce_base)], check=True)
    result = json.loads((out/'runs/report.json').read_text())
    full = {r['variant']: r for r in result['variants'] if r['sample']=='full'}
    for variant in ['baseline', args.candidate]:
        row = full[variant]
        assert row['result']=='PASS' and row['recovered_sha256']==digest
        # compare_stream checks reference ciphertext/tag and the bench requires
        # authentication and commit before reporting PASS. Publish only now.
        recovered = b''.join(bytes.fromhex(line)[::-1] for line in
                             (out/'runs'/variant/'full/recovered_blocks.txt').read_text().splitlines())
        assert recovered == args.weights.read_bytes()
        (out/f'{variant}_recovered_weights.bin').write_bytes(recovered)
        if args.checkpoint:
            restored = args.checkpoint.read_bytes()[:20] + recovered
            assert restored == args.checkpoint.read_bytes()
            (out/f'{variant}_reconstructed_checkpoint.bin').write_bytes(restored)
    baseline = full['baseline']['cycles']['ENCRYPT']
    candidate = full[args.candidate]['cycles']['ENCRYPT']
    for row in full.values():
        assert row['cycles']['ENCRYPT'] == row['cycles']['DECRYPT']
    result.update(clock_hz=100_000_000, result='PASS', payload_sha256=digest, candidate=args.candidate,
                  speedup=baseline/candidate, cycle_reduction_percent=(1-candidate/baseline)*100,
                  checkpoint_reconstructed_exactly=bool(args.checkpoint), training_performed=False,
                  scope='Behavioral RTL simulation, command through done; no physical timing claim')
    (out/'report.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
