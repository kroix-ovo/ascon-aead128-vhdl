#!/usr/bin/env python3
"""Run one tb_weight_file case with WSL system GHDL; check it like compare_stream.py.

usage: run_weight_case.py <variant> <weights.bin> <sample:1KiB|full> <nonce_id> <outdir> [--keep-dumps]
variant: u1 | u3 | u3-buffered | u3-fold   (sources: ~/ascon_fold_scratch/wt, synced from the worktree)
Checks: RTL ciphertext == Python oracle, RTL tag == oracle, RTL decrypt authenticated and
committed (bench asserts), recovered bytes == input, SHA-256 recorded.
"""
import hashlib, json, re, subprocess, sys, time
from pathlib import Path

S = Path.home() / 'ascon_fold_scratch'
W = S / 'wt'
variant, weights, sample, nonce_id, out = sys.argv[1], Path(sys.argv[2]), sys.argv[3], int(sys.argv[4]), Path(sys.argv[5])
keep = '--keep-dumps' in sys.argv
sys.path.insert(0, str(W / 'verification/model'))
from ascon_ref import encrypt, decrypt  # noqa: E402

CFG = {'u1': (1, False, False), 'u3': (3, False, False), 'u3-buffered': (3, True, False), 'u3-fold': (3, True, True)}
rpc, buf, fold = CFG[variant]


def sha(b): return hashlib.sha256(b).hexdigest()
def port_hex(d): return d.ljust(16, b'\0')[::-1].hex().upper()


payload = weights.read_bytes()
if sample == '1KiB':
    payload = payload[:1024]
assert len(payload) % 16 == 0 and len(payload) >= 32
out.mkdir(parents=True, exist_ok=False)
key, nonce = bytes(range(16)), nonce_id.to_bytes(16, 'little')
ct, tag = encrypt(key, nonce, b'', payload)
pt, ok = decrypt(key, nonce, b'', ct, tag)
assert ok and pt == payload
blocks = len(payload) // 16
hdr = f'{blocks} {port_hex(key)} {port_hex(nonce)} {port_hex(tag)}\n'
for name, a, b in (('encrypt_vectors.txt', payload, ct), ('decrypt_vectors.txt', ct, payload)):
    with (out / name).open('w') as f:
        f.write(hdr)
        for i in range(0, len(payload), 16):
            f.write(f'{port_hex(a[i:i+16])} {port_hex(b[i:i+16])}\n')
work = out / 'work'; work.mkdir()
files = [W / 'rtl' / n for n in ('ascon_pkg.vhd', 'ascon_permutation.vhd', 'ascon_aead128_core.vhd')] + \
        [W / 'verification/vhdl/tb_weight_file.vhd']
subprocess.run(['ghdl', '-a', '--std=08', f'--workdir={work}', *map(str, files)], cwd=out, check=True)
cmd = ['ghdl', '--elab-run', '--std=08', f'--workdir={work}', 'tb_weight_file', f'-gG_RUN_DIR={out}',
       f'-gG_ROUNDS_PER_CYCLE={rpc}', f'-gG_BUFFERING_ENABLE={str(buf).lower()}',
       f'-gG_FOLDED_ABSORB={str(fold).lower()}', '--assert-level=error']
t1 = time.time()
with (out / 'ghdl.log').open('w') as log:
    subprocess.run(cmd, cwd=out, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=7200)
sim_s = time.time() - t1
rec = (out / 'simulation_results.txt').read_text()
assert 'checks=2 pass=2 fail=0' in rec
cycles = {m: int(c) for m, c in re.findall(r'^(ENCRYPT|DECRYPT) bytes=\d+ cycles=(\d+) PASS$', rec, re.M)}
assert len(cycles) == 2


def dump(name):
    return b''.join(bytes.fromhex(x)[::-1] for x in (out / name).read_text().splitlines())


actual_ct = dump('ciphertext_blocks.txt'); actual_pt = dump('recovered_blocks.txt')
actual_tag = bytes.fromhex((out / 'rtl_tag.txt').read_text().strip())[::-1]
assert actual_ct == ct, 'ciphertext mismatch'
assert actual_tag == tag, 'tag mismatch'
assert actual_pt == payload, 'recovery mismatch'
row = dict(variant=variant, sample=sample, bytes=len(payload), blocks=blocks, rounds_per_cycle=rpc,
           buffering=buf, folded_absorb=fold, nonce_id=nonce_id, cycles=cycles,
           payload_sha256=sha(payload), recovered_sha256=sha(actual_pt), ciphertext_sha256=sha(actual_ct),
           tag_hex=actual_tag.hex(), mismatched_recovered_bytes=sum(a != b for a, b in zip(actual_pt, payload)),
           ciphertext_matches_oracle=True, tag_matches_oracle=True, rtl_auth_and_commit=True,
           source_sha256_lf={f.name: sha(f.read_bytes()) for f in files}, ghdl_command=' '.join(cmd),
           sim_wall_seconds=round(sim_s, 1), result='PASS')
(out / 'result.json').write_text(json.dumps(row, indent=2) + '\n')
if keep:
    (out / 'recovered.bin').write_bytes(actual_pt)
if sample == 'full':
    for n in ('encrypt_vectors.txt', 'decrypt_vectors.txt', 'ciphertext_blocks.txt', 'recovered_blocks.txt'):
        (out / n).unlink()
print(json.dumps({k: row[k] for k in ('variant', 'sample', 'bytes', 'cycles', 'recovered_sha256', 'tag_hex', 'sim_wall_seconds')}), flush=True)
