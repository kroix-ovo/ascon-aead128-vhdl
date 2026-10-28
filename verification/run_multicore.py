"""Reproducible GHDL multicore study; never trains, programs, or publishes.

Run on Linux/WSL. All output directories are fresh. Full RTL runs compare every
payload beat and encryption tag against the independent Python oracle.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import shutil
import sys
import time

from multicore_format import KEY, associated_data, digest, gather, scatter, manifest_digest
sys.path.insert(0,str(Path(__file__).resolve().parent/'model'))
from ascon_ref import encrypt

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ['rtl/ascon_pkg.vhd','rtl/ascon_permutation.vhd','rtl/ascon_aead128_core.vhd',
           'rtl/ascon_elastic_stage.vhd','rtl/ascon_multicore.vhd','verification/vhdl/tb_multicore.vhd']
PROFILES = ['ideal','source_gaps','sink_stalls','seeded_bursts','memory_1GBps','memory_1p3GBps','skewed_lanes']


def run(command, log=None, cwd=ROOT):
    if command[0] == 'git' and sys.platform == 'linux' and shutil.which('git.exe'):
        # Managed Windows worktrees contain absolute Windows gitdir paths.
        command = ['git.exe']+command[1:]
    result = subprocess.run(list(map(str,command)), cwd=cwd, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if log:
        Path(log).write_text(result.stdout)
    if result.returncode:
        raise RuntimeError(f'Command failed: {command}\n{result.stdout[-4000:]}')
    return result.stdout.strip()


def hexword(data, size=16):
    return data.ljust(size,b'\0')[::-1].hex()


def vectors(chunks, model, manifest, base):
    result = []
    for layer, chunk in enumerate(chunks):
        ad = associated_data(model,manifest,layer,12,len(chunk),base)
        ciphertext, tag = encrypt(KEY,(base+layer).to_bytes(16,'little'),ad,chunk)
        result.append((chunk,ciphertext,tag))
    return result


def write_vectors(path, records, model, manifest, base, decrypt, fault):
    if fault == 10:
        model = bytes([model[0]^1])+model[1:]
    if fault == 13:
        manifest = bytes([manifest[0]^1])+manifest[1:]
    if fault == 14:
        base += 12
    if fault == 12:
        base = (1 << 128)-11
    with path.open('w') as f:
        for data in (KEY, base.to_bytes(16,'little'),model,manifest):
            f.write(hexword(data,len(data))+'\n')
        for layer,(plain,cipher,tag) in enumerate(records):
            if fault == 15 and layer in [0,1]:
                cipher,tag=records[1-layer][1:]
            if layer == 0 and fault == 1:
                tag = bytes([tag[0]^1])+tag[1:]
            if layer == 11 and fault == 17:
                tag = bytes([tag[0]^1])+tag[1:]
            if layer == 0 and fault == 11:
                tag = records[1][2]
            f.write(hexword(tag)+'\n')
            src, expected = (cipher,plain) if decrypt else (plain,cipher)
            if layer == 0 and fault == 2:
                src = bytes([src[0]^1])+src[1:]
            for offset in range(0,len(src),16):
                f.write(hexword(src[offset:offset+16])+' '+hexword(expected[offset:offset+16])+'\n')


def execute(case, work, records, model, manifest, base, cores, registers, local, decrypt, profile, fault=0, executable=None):
    case.mkdir(parents=True,exist_ok=False)
    write_vectors(case/'vectors.txt',records,model,manifest,base,decrypt,fault)
    command = ['ghdl','--elab-run','--std=08',f'--workdir={work}','tb_multicore',
        f'-gG_CORES={cores}',f'-gG_BYTES={len(records[0][0])}',
        f'-gG_REGISTERS={str(registers).lower()}',f'-gG_LOCAL_CONTROL={str(local).lower()}',
        f'-gG_DECRYPT={str(decrypt).lower()}',f'-gG_PROFILE={profile}',f'-gG_FAULT={fault}',
        f'-gG_DIR={case}','--assert-level=error','--max-stack-alloc=0']
    if executable:
        command=[str(executable),str(case),str(cores),str(len(records[0][0])),str(int(decrypt)),str(profile),str(fault)]
    started = time.monotonic()
    simulation_log=run(command,case/'simulation.txt',cwd=work)
    if 'stop-delta' in simulation_log:
        raise RuntimeError('Simulator stopped on a combinational delta-cycle limit')
    metrics = dict(line.split() for line in (case/'metrics.txt').read_text().splitlines())
    metrics = {k:int(v) for k,v in metrics.items()}
    receipt = dict(cores=cores, boundary_registers=registers, local_control=local,
        direction='decrypt' if decrypt else 'encrypt',profile=PROFILES[profile],fault=fault,
        simulator='verilator' if executable else 'ghdl',
        model_id=model.hex(),manifest_id=manifest.hex(),
        chunk_tags_hex=[r[2].hex() for r in records],
        nonce_base=base,clock_ns=10,bytes=sum(len(r[0]) for r in records),
        simulation_wall_seconds=round(time.monotonic()-started,3),metrics=metrics,command=command)
    if fault:
        assert metrics.get('discard_pass') == 1 or metrics.get('reset_flush_pass') == 1
    else:
        assert 'MULTICORE_PASS' in simulation_log, 'Missing successful bench completion'
        rows = (case/'output.txt').read_text().splitlines()
        blocks = (len(records[0][0])+15)//16
        actual = [b''.join(bytes.fromhex(x)[::-1] for x in rows[i*blocks:(i+1)*blocks])[:len(records[i][0])]
                  for i in range(12)]
        wanted = [r[0 if decrypt else 1] for r in records]
        assert actual == wanted
        cycles = metrics['cycles']
        receipt.update(payload_MBps=receipt['bytes']/(cycles*10e-9)/1e6,
            first_output_cycles=metrics['first_output'],
            file_commit_tail_cycles=cycles-metrics['last_input'],
            input_bus_utilization=metrics['bus_input']/cycles,
            output_bus_utilization=metrics['bus_output']/cycles,
            input_payload_utilization=metrics['bus_payload']/cycles,
            output_payload_utilization=metrics['bus_output_payload']/cycles,
            per_chunk_latency=[metrics[f'chunk_end_{i}']-metrics[f'chunk_start_{i}'] for i in range(12)],
            per_core_busy_percent=[100*metrics[f'busy_{i}']/cycles for i in range(cores)],
            output_sha256=digest(b''.join(actual)),exact_oracle_match=True)
        assert metrics['bus_payload'] == 12*blocks
        assert metrics['bus_input'] == 12*(blocks+6+int(decrypt))
        assert metrics['bus_output'] == 12*(blocks+int(not decrypt))
        assert all(metrics[f'chunks_{i}'] == 12//cores for i in range(cores))
        for i in range(cores):
            assert sum(metrics[f'input_{kind}_wait_{i}'] for kind in ['arbitration','capacity','setup','bandwidth']) == metrics[f'source_wait_{i}']
        receipt['recovered_chunks'] = actual if decrypt else None
    receipt['result'] = 'PASS'
    serial = {k:v for k,v in receipt.items() if k != 'recovered_chunks'}
    (case/'report.json').write_text(json.dumps(serial,indent=2)+'\n')
    print(json.dumps({k:serial[k] for k in ['cores','boundary_registers','local_control','direction','profile','fault','result']}
                     | {'cycles':metrics.get('cycles'),'MBps':serial.get('payload_MBps')}),flush=True)
    return receipt


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--weights',type=Path)
    p.add_argument('--manifest',type=Path)
    p.add_argument('--checkpoint',type=Path)
    p.add_argument('--nonce-base',type=lambda x:int(x,0),required=True)
    p.add_argument('--cores',type=int,nargs='+',default=[1,2,4],choices=[1,2,4])
    p.add_argument('--profiles',nargs='+',choices=PROFILES,default=PROFILES[:6])
    p.add_argument('--registers',action='store_true')
    p.add_argument('--local-control',action='store_true')
    p.add_argument('--security',action='store_true')
    p.add_argument('--edge-cases',action='store_true',help='Also test 1/15/16/17/31/32/33-byte chunks with skewed lanes')
    p.add_argument('--sim',choices=['ghdl','verilator'],default='ghdl')
    p.add_argument('--synth-ghdl',default='ghdl',help='GHDL executable with Verilog synthesis support')
    p.add_argument('--synthetic-bytes',type=int,default=256)
    args = p.parse_args()
    out = args.output.resolve(); out.mkdir(parents=True,exist_ok=False)
    work = out/'work'; work.mkdir()
    # Freeze simulator inputs: editing the workspace during a long study must
    # neither invalidate later elaborations nor silently mix source versions.
    frozen=out/'source'
    for name in SOURCES+['verification/run_multicore.py','verification/multicore_format.py','verification/multicore_sim.cpp']:
        target=frozen/name; target.parent.mkdir(parents=True,exist_ok=True)
        target.write_bytes((ROOT/name).read_bytes())
    executables={}
    if args.sim=='ghdl':
        run(['ghdl','-a','--std=08',f'--workdir={work}']+[frozen/n for n in SOURCES],out/'compile.txt',cwd=work)
    else:
        for cores in args.cores:
            build=out/f'verilator-n{cores}'; build.mkdir()
            netlist=build/'ascon_multicore.v'
            command=[args.synth_ghdl,'--synth','--std=08','--out=verilog',f'-gG_CORES={cores}',
                f'-gG_BOUNDARY_REGISTERS={str(args.registers).lower()}',f'-gG_LOCAL_CONTROL={str(args.local_control).lower()}']
            command += [str(frozen/n) for n in SOURCES if not n.startswith('verification/')]
            command += ['-e','ascon_multicore']
            with netlist.open('w') as target, (build/'synthesis.txt').open('w') as errors:
                subprocess.run(command,cwd=build,stdout=target,stderr=errors,check=True)
            run(['verilator','--cc','--exe','--build','-j','2','-Wno-fatal','--top-module','ascon_multicore',
                 '--Mdir',str(build/'obj'),'-CFLAGS','-std=c++17 -O2',str(netlist),
                 str(frozen/'verification/multicore_sim.cpp')],build/'compile.txt',cwd=build)
            executables[cores]=build/'obj/Vascon_multicore'
    payload, mapping, checkpoint = None,None,None
    if args.weights:
        if not args.manifest: p.error('--manifest required with --weights')
        payload = args.weights.read_bytes(); metadata = json.loads(args.manifest.read_text())
        chunks,mapping = gather(payload,metadata)
        model,manifest = hashlib.sha256(payload).digest(),manifest_digest(metadata)
        if args.checkpoint:
            checkpoint = args.checkpoint.read_bytes()
            if checkpoint[20:] != payload or digest(checkpoint) != metadata['checkpoint_sha256']:
                raise ValueError('Checkpoint mismatch')
        (out/'chunk_map.json').write_text(json.dumps(mapping,indent=2)+'\n')
    else:
        chunks = [bytes((j*29+i*17)%256 for j in range(args.synthetic_bytes)) for i in range(12)]
        model,manifest = hashlib.sha256(b''.join(chunks)).digest(),hashlib.sha256(b'synthetic-v1').digest()
    if (args.security or args.edge_cases) and args.weights: p.error('Run security/edge cases on small synthetic payloads')
    receipt = dict(base_sha=run(['git','rev-parse','HEAD']),clock_ns=10,
        source_sha256={n:digest((frozen/n).read_bytes()) for n in SOURCES},
        runner_sha256={n:digest((frozen/n).read_bytes()) for n in ['verification/run_multicore.py','verification/multicore_format.py','verification/multicore_sim.cpp']},
        tools={'ghdl':run(['ghdl','--version']), 'python':sys.version,
               'verilator':run(['verilator','--version']) if args.sim=='verilator' else None,
               'synthesis_ghdl':run([args.synth_ghdl,'--version']) if args.sim=='verilator' else None},
        payload_sha256=digest(b''.join(chunks)), original_file_sha256=digest(payload) if payload else None,
        chunk_bytes=list(map(len,chunks)),nonce_ranges=[],runs=[])
    base=args.nonce_base
    for cores in args.cores:
        jobs = [(PROFILES.index(profile),decrypt,0) for profile in args.profiles for decrypt in [False,True]]
        if args.security:
            jobs += [(3,True,fault) for fault in range(1,18)]
        # A direction pair decrypts exactly the ciphertext just encrypted with
        # that range. Distinct profiles/core configurations use fresh ranges.
        records = None
        for profile,decrypt,fault in jobs:
            if not decrypt or fault:
                records=vectors(chunks,model,manifest,base)
                receipt['nonce_ranges'].append([base,base+11]); base+=12
            nonce_base=base-12
            case=out/f'n{cores}_{PROFILES[profile]}_{"dec" if decrypt else "enc"}_f{fault}'
            row=execute(case,work,records,model,manifest,nonce_base,cores,args.registers,args.local_control,decrypt,profile,fault,
                        executable=executables.get(cores))
            actual=row.pop('recovered_chunks',None)
            if actual is not None and mapping:
                restored=scatter(actual,mapping,len(payload)); assert restored == payload
                row['original_file_reconstructed_exactly']=True
                (case/'recovered_weights.bin').write_bytes(restored)
                if checkpoint:
                    rebuilt=checkpoint[:20]+restored; assert rebuilt == checkpoint
                    row['checkpoint_reconstructed_exactly']=True
                    (case/'reconstructed_checkpoint.bin').write_bytes(rebuilt)
            receipt['runs'].append(row)
            (out/'report.json').write_text(json.dumps(receipt,indent=2)+'\n')
        if args.edge_cases:
            for size in [1,15,16,17,31,32,33]:
                edge_chunks=[bytes((j*29+i*17)%256 for j in range(size)) for i in range(12)]
                edge_model=hashlib.sha256(b''.join(edge_chunks)).digest()
                edge_records=vectors(edge_chunks,edge_model,manifest,base)
                receipt['nonce_ranges'].append([base,base+11]);base+=12
                for decrypt in [False,True]:
                    case=out/f'n{cores}_edge{size}_{"dec" if decrypt else "enc"}'
                    row=execute(case,work,edge_records,edge_model,manifest,base-12,cores,args.registers,args.local_control,
                                decrypt,6,executable=executables.get(cores))
                    row.pop('recovered_chunks',None);receipt['runs'].append(row)
                    (out/'report.json').write_text(json.dumps(receipt,indent=2)+'\n')
    receipt['result']='PASS'
    (out/'report.json').write_text(json.dumps(receipt,indent=2)+'\n')


if __name__ == '__main__':
    main()
