"""Synthetic metadata guards for the full saved-adapter simulation runner."""
import hashlib
import json
from pathlib import Path
import struct
import tempfile
import unittest

from simulate_adapter import validate


class AdapterExportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.weights, self.manifest, self.checkpoint = [root/n for n in ['weights.bin','manifest.json','checkpoint.bin']]
        # Clearly synthetic, never described as trained model weights.
        payload = struct.pack('<f', 0.25)*1024
        self.weights.write_bytes(payload)
        raw = struct.pack('<5i', 2, 8, 16, 3, 64)+payload
        self.checkpoint.write_bytes(raw)
        tensors, offset = [], 0
        for name, shape in [('down_w',[8,3,16]),('down_b',[8,3]),('up_w',[8,16,3]),('up_b',[8,16])]:
            size = 4
            for dim in shape: size *= dim
            tensors.append(dict(name=name, shape=shape, bytes=size, payload_byte_offset=offset))
            offset += size
        # 384+24+384+128 = 920 floats, so use the precise complete body.
        payload = payload[:offset]
        self.weights.write_bytes(payload)
        raw = raw[:20]+payload
        self.checkpoint.write_bytes(raw)
        self.data = dict(dtype='float32', padding_bytes=0, original_payload_bytes=len(payload),
                         original_payload_sha256=hashlib.sha256(payload).hexdigest(),
                         checkpoint_sha256=hashlib.sha256(raw).hexdigest(), batch=2, layers=8,
                         channels=16, rank=3, sequence_length=64, tensor_manifest=tensors)
        self.save()

    def save(self):
        self.manifest.write_text(json.dumps(self.data))

    def test_complete_export(self):
        tensors, digest = validate(self.weights, self.manifest, self.checkpoint)
        self.assertEqual(sum(t['byte_count'] for t in tensors), self.weights.stat().st_size)
        self.assertEqual(digest, self.data['original_payload_sha256'])

    def test_corrupted_weights(self):
        self.weights.write_bytes(b'\0'+self.weights.read_bytes()[1:-1])
        with self.assertRaises(ValueError): validate(self.weights, self.manifest)

    def test_wrong_offsets(self):
        self.data['tensor_manifest'][1]['payload_byte_offset'] += 16
        self.save()
        with self.assertRaises(ValueError): validate(self.weights, self.manifest)

    def test_wrong_tensor_identity(self):
        self.data['tensor_manifest'][0]['name'] = 'other'
        self.save()
        with self.assertRaises(ValueError): validate(self.weights, self.manifest)

    def test_wrong_checkpoint_header(self):
        self.checkpoint.write_bytes(struct.pack('<i',3)+self.checkpoint.read_bytes()[4:])
        with self.assertRaises(ValueError): validate(self.weights, self.manifest, self.checkpoint)

    def test_wrong_checkpoint_body(self):
        raw = bytearray(self.checkpoint.read_bytes())
        raw[-1] ^= 1
        self.checkpoint.write_bytes(raw)
        with self.assertRaises(ValueError): validate(self.weights, self.manifest, self.checkpoint)


if __name__ == '__main__':
    unittest.main()
