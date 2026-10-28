"""Decrypt one saved encrypted file on every core count; reuse compiled study RTL."""
import argparse
import hashlib
import json
from pathlib import Path
from multicore_format import scatter, digest
from run_multicore import ROOT, execute


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('study',type=Path,help='Completed Verilator full-file run directory')
    p.add_argument('--output',type=Path,required=True)
    args=p.parse_args();study=args.study.resolve();out=args.output.resolve()
    reference=json.loads((study/'report.json').read_text());assert reference['result']=='PASS'
    for name,value in reference['source_sha256'].items():
        if name.startswith('rtl/'):
            assert digest((ROOT/name).read_bytes())==value, f'RTL differs from compiled study: {name}'
    out.mkdir(parents=True,exist_ok=False)
    source=study/'n1_ideal_enc_f0'; lines=iter((source/'vectors.txt').read_text().splitlines())
    key,nonce,model,manifest=[bytes.fromhex(next(lines))[::-1] for _ in range(4)]
    size=reference['chunk_bytes'][0];blocks=(size+15)//16;records=[]
    for layer in range(12):
        tag=bytes.fromhex(next(lines))[::-1];plain=[];cipher=[]
        for _ in range(blocks):
            a,b=next(lines).split();plain.append(bytes.fromhex(a)[::-1]);cipher.append(bytes.fromhex(b)[::-1])
        records.append((b''.join(plain)[:size],b''.join(cipher)[:size],tag))
    actual=b''.join(bytes.fromhex(line)[::-1] for line in (source/'output.txt').read_text().splitlines())
    assert actual==b''.join(r[1] for r in records), 'Saved RTL ciphertext does not match vectors'
    base=int.from_bytes(nonce,'little')
    first=next(r for r in reference['runs'] if r['cores']==1 and r['direction']=='encrypt' and r['profile']=='ideal')
    mapping=json.loads((study/'chunk_map.json').read_text())
    receipt=dict(reference_report_sha256=digest((study/'report.json').read_bytes()),
        ciphertext_sha256=digest(actual),nonce_base=base,scope='One ciphertext/tag set, decryption only',runs=[])
    for cores in [1,2,4]:
        row=execute(out/f'n{cores}',study/'work',records,model,manifest,base,cores,
            first['boundary_registers'],first['local_control'],True,0,
            executable=study/f'verilator-n{cores}/obj/Vascon_multicore')
        chunks=row.pop('recovered_chunks')
        restored=scatter(chunks,mapping,reference['runs'][0]['bytes'])
        assert digest(restored)==reference['original_file_sha256']
        row['original_file_reconstructed_exactly']=True;receipt['runs'].append(row)
    receipt['result']='PASS';(out/'report.json').write_text(json.dumps(receipt,indent=2)+'\n')


if __name__=='__main__': main()
