"""Fresh three-way GHDL comparison, including the unchanged origin/main RTL.

Run on Windows with WSL GHDL, or on Linux with GHDL on PATH. No training.
Every independent encryption uses a distinct nonce. Dumps remain provisional
until the VHDL bench authenticates and this runner verifies the complete bytes.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ['ascon_pkg.vhd', 'ascon_permutation.vhd', 'ascon_aead128_core.vhd']
GIT = 'git.exe' if os.name != 'nt' and shutil.which('git.exe') else 'git'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def unix(path):
    path = path.resolve()
    if os.name != 'nt': return str(path)
    return '/mnt/' + path.drive[0].lower() + path.as_posix()[2:]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('weights', type=Path)
    p.add_argument('--manifest', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--variants', nargs='+', choices=['baseline','u3','u3-buffered','u3-fold'], default=['baseline','u3','u3-buffered'])
    p.add_argument('--nonce-base', type=int, default=0x53545245414D0000)
    p.add_argument('--baseline-ref', default='origin/main', help='Pin the historical baseline source')
    args = p.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    weight = args.weights.resolve()
    manifest = json.loads(args.manifest.read_text())
    payload = weight.read_bytes()
    assert sum(t['byte_count'] for t in manifest) == len(payload)
    assert all(t['dtype']=='float32-le' for t in manifest)
    offset = 0
    for tensor in manifest:
        assert tensor['byte_offset'] == offset
        assert math.prod(tensor['shape'])*4 == tensor['byte_count']
        offset += tensor['byte_count']
    assert offset == len(payload)
    (out/'tensor_manifest.json').write_text(json.dumps(manifest,indent=2))
    (out/'slice_1KiB.bin').write_bytes(payload[:1024])
    receipt = dict(base_sha=subprocess.check_output([GIT,'rev-parse',args.baseline_ref],cwd=ROOT,text=True).strip(),
        payload=dict(path=str(weight),bytes=len(payload),format='float32-le',sha256=sha(payload),
                     tensor_manifest_sha256=sha(args.manifest.read_bytes())),variants=[])
    for variant,rpc,buffered in [('baseline',1,False),('u3',3,False),('u3-buffered',3,True),('u3-fold',3,True)]:
        if variant not in args.variants: continue
        folded = variant=='u3-fold'  # G_FOLDED_ABSORB single-state-register core
        src=out/variant/'source';src.mkdir(parents=True)
        for n in SOURCES:
            data = subprocess.check_output([GIT,'show',args.baseline_ref+':rtl/'+n],cwd=ROOT) if variant=='baseline' else (ROOT/'rtl'/n).read_bytes()
            (src/n).write_bytes(data)
        bench=(ROOT/'verification/vhdl/tb_weight_file.vhd').read_text()
        if variant=='baseline':
            bench=re.sub(r'    generic map \(G_ROUNDS_PER_CYCLE.*?\)\n', '', bench, count=1,flags=re.S)
        (src/'tb_weight_file.vhd').write_text(bench)
        for sample,weights in [('1KiB',out/'slice_1KiB.bin'),('full',weight)]:
            case=out/variant/sample
            nonce=args.nonce_base+len(receipt['variants'])
            command=[sys.executable,str(ROOT/'verification/simulate_weight_file.py'),str(weights),'--output',str(case),'--prepare-only','--nonce-id',str(nonce),'--rounds-per-cycle',str(rpc)]
            if buffered:command+=['--buffering']
            if folded:command+=['--folded']
            subprocess.run(command,check=True)
            # Compile frozen sources. All GHDL arguments live in a short script.
            script=case/'run_ghdl.sh'
            paths=[src/n for n in SOURCES]+[src/'tb_weight_file.vhd']
            script.write_bytes(('set -eu\ncd "'+unix(case)+'"\nghdl -a --std=08 '+' '.join('"'+unix(n)+'"' for n in paths)+'\nghdl --elab-run --std=08 tb_weight_file -gG_RUN_DIR="'+unix(case)+'" -gG_ROUNDS_PER_CYCLE='+str(rpc)+' -gG_BUFFERING_ENABLE='+str(buffered).lower()+(' -gG_FOLDED_ABSORB=true' if folded else '')+' --assert-level=error\n').encode())
            with (case/'ghdl.log').open('w') as log:
                subprocess.run(['wsl','-d','Ubuntu-22.04','--','bash',unix(script)] if os.name=='nt' else ['bash',str(script)],stdout=log,stderr=subprocess.STDOUT,check=True,timeout=1800)
            records=(case/'simulation_results.txt').read_text()
            assert 'checks=2 pass=2 fail=0' in records
            actual=b''.join(bytes.fromhex(x)[::-1] for x in (case/'recovered_blocks.txt').read_text().splitlines())
            assert actual==weights.read_bytes()
            expected_rows=(case/'encrypt_vectors.txt').read_text().splitlines()
            expected_ct=b''.join(bytes.fromhex(x.split()[1])[::-1] for x in expected_rows[1:])
            actual_ct=b''.join(bytes.fromhex(x)[::-1] for x in (case/'ciphertext_blocks.txt').read_text().splitlines())
            assert actual_ct==expected_ct
            expected_tag=bytes.fromhex(expected_rows[0].split()[3])[::-1]
            actual_tag=bytes.fromhex((case/'rtl_tag.txt').read_text().strip())[::-1]
            assert actual_tag==expected_tag
            cycles={m:int(c) for m,c in re.findall(r'^(ENCRYPT|DECRYPT) bytes=\d+ cycles=(\d+) PASS$',records,re.M)}
            assert len(cycles)==2
            row=dict(variant=variant,sample=sample,bytes=len(actual),rounds_per_cycle=rpc,buffering=buffered,folded_absorb=folded,nonce_id=nonce,
                cycles=cycles,recovered_sha256=sha(actual),ciphertext_sha256=sha(actual_ct),tag_hex=actual_tag.hex(),
                source_sha256={n.name:sha(n.read_bytes()) for n in paths},result='PASS')
            receipt['variants'].append(row)
            (out/'report.json').write_text(json.dumps(receipt,indent=2))
            print(json.dumps(row),flush=True)


if __name__=='__main__':main()
