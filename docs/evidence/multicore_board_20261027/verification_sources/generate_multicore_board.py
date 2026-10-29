"""Create bounded, real-adapter hardware fixtures; never retrain or publish weights."""
import argparse
import hashlib
import json
from pathlib import Path
import sys

from multicore_format import KEY, associated_data, gather, manifest_digest
sys.path.insert(0, str(Path(__file__).parent / 'model'))
from ascon_ref import encrypt, decrypt


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('export', type=Path)
    p.add_argument('output', type=Path)
    a = p.parse_args()
    a.output.mkdir(parents=True, exist_ok=False)
    manifest = json.loads((a.export / 'manifest.json').read_text())
    payload = (a.export / 'adapter_weights.bin').read_bytes()
    chunks, mapping = gather(payload, manifest)
    model = hashlib.sha256(payload).digest()
    md = manifest_digest(manifest)
    base = 0x20261027000000000000000000001000  # public, fixture-only nonce range
    # Four tensor slices per layer; all 12 layers participate. No full weights ROM.
    chosen = []
    for layer in range(12):
        parts = [part for part in mapping if part['layer'] == layer]
        chosen.append(b''.join(chunks[layer][x['chunk_offset']:x['chunk_offset']+64] for x in parts))
    plain, cipher, tags = [], [], []
    for layer, data in enumerate(chosen):
        ad = associated_data(model, md, layer, 12, len(data), base)
        ct, tag = encrypt(KEY, (base+layer).to_bytes(16, 'little'), ad, data)
        assert decrypt(KEY, (base+layer).to_bytes(16, 'little'), ad, ct, tag) == (data, True)
        plain.extend(data[i:i+16] for i in range(0,256,16))
        cipher.extend(ct[i:i+16] for i in range(0,256,16))
        tags.append(tag)
    def h(value):
        return 'x"'+value[::-1].hex()+'"'
    def array(name, data):
        return f'  constant {name} : words_t(0 to {len(data)-1}) := (\n'+',\n'.join(
            f'    {i} => {h(word)}' for i,word in enumerate(data))+'\n  );\n'
    source = ('library ieee; use ieee.std_logic_1164.all;\npackage multicore_board_vectors is\n'
              '  type words_t is array(natural range <>) of std_logic_vector(127 downto 0);\n'
              f'  constant TEST_KEY : std_logic_vector(127 downto 0) := {h(KEY)};\n'
              f'  constant TEST_NONCE : std_logic_vector(127 downto 0) := {h(base.to_bytes(16,"little"))};\n'
              f'  constant TEST_MODEL : std_logic_vector(255 downto 0) := {h(model)};\n'
              f'  constant TEST_MANIFEST : std_logic_vector(255 downto 0) := {h(md)};\n'
              + array('PLAIN',plain)+array('CIPHER',cipher)+array('TAGS',tags)+'end package;\n')
    (a.output/'multicore_board_vectors.vhd').write_text(source)
    receipt = dict(adapter_sha256=model.hex(), adapter_bytes=len(payload), manifest_digest=md.hex(),
        bytes_per_layer=256, fixture_bytes=3072, layers=12, nonce_base=hex(base),
        nonce_scope='Public test fixtures only; never reuse for production encryption',
        selection='First 64 bytes of down_w, down_b, up_w, up_b in each gathered layer',
        mapping=mapping, plain_sha256=hashlib.sha256(b''.join(plain)).hexdigest(),
        cipher_sha256=hashlib.sha256(b''.join(cipher)).hexdigest(),
        tag_hex=[t.hex() for t in tags], independent_oracle_roundtrip=True,
        generated_source_lf_sha256=hashlib.sha256(source.encode()).hexdigest(),
        generated_file_sha256=hashlib.sha256((a.output/'multicore_board_vectors.vhd').read_bytes()).hexdigest())
    (a.output/'vectors.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print(json.dumps({k:receipt[k] for k in ['adapter_bytes','fixture_bytes','layers','independent_oracle_roundtrip']}))

if __name__ == '__main__':
    main()
