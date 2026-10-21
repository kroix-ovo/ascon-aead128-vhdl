"""Simulate full weight-file encryption and decryption in Vivado XSim.

One message per direction, configurable unrolling/buffering, empty AD, 100 MHz
simulated clock. Fixed public demo key/nonce; this is an experiment runner.
Outputs are accepted only after ciphertext, tag, authentication, and recovery
checks pass. Core cycles exclude host file I/O and simulator wall time.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'verification/model'))
sys.path.insert(0, str(ROOT/'verification'))
from ascon_ref import encrypt, decrypt
from fetch_vectors import parse_kats
from gpt2_weights_demo import port_hex


def sha(data):
    return hashlib.sha256(data).hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('weights', type=Path)
    p.add_argument('--output', type=Path, required=True, help='New directory; existing evidence is preserved')
    p.add_argument('--vivado', type=Path, default=Path(r'C:\Xilinx\Vivado\2023.2\bin\vivado.bat'))
    p.add_argument('--rounds-per-cycle', type=int, default=1, choices=range(1,13))
    p.add_argument('--buffering', action='store_true')
    p.add_argument('--folded', action='store_true', help='G_FOLDED_ABSORB (needs --rounds-per-cycle 3 --buffering)')
    p.add_argument('--nonce-id', type=int, required=True, help='Unique independent-message nonce under the public test key')
    p.add_argument('--prepare-only', action='store_true')
    p.add_argument('--timeout', type=int, default=1800, help='Vivado wall-clock timeout in seconds')
    args = p.parse_args()
    weights, output = args.weights.resolve(), args.output.resolve()
    plaintext = weights.read_bytes()
    if len(plaintext) < 32 or len(plaintext) % 16:
        raise ValueError('This bench requires at least 32 bytes, with length a multiple of 16')
    if output.exists():
        raise FileExistsError('Use a new output directory to preserve prior evidence')
    if not args.prepare_only and not args.vivado.exists():
        raise FileNotFoundError(f'Vivado not found: {args.vivado}; supply --vivado')
    output.mkdir(parents=True)
    kats = list(parse_kats((ROOT/'verification/vectors/LWC_AEAD_KAT_128_128.txt').read_bytes()))
    for v in kats:
        assert encrypt(v['key'], v['nonce'], v['ad'], v['pt']) == (v['ct'], v['tag'])
        assert decrypt(v['key'], v['nonce'], v['ad'], v['ct'], v['tag']) == (v['pt'], True)
    assert len(kats) == 1089
    key, nonce = bytes(range(16)), args.nonce_id.to_bytes(16, 'little')
    print(f'Oracle passed 1089 KATs; preparing {len(plaintext):,} weight bytes', flush=True)
    started = time.perf_counter()
    expected, tag = encrypt(key, nonce, b'', plaintext)
    reference_encrypt_seconds = time.perf_counter()-started
    started = time.perf_counter()
    recovered, authenticated = decrypt(key, nonce, b'', expected, tag)
    reference_decrypt_seconds = time.perf_counter()-started
    assert authenticated and recovered == plaintext
    blocks = len(plaintext)//16
    header = f'{blocks} {port_hex(key)} {port_hex(nonce)} {port_hex(tag)}\n'
    for filename, inputs, outputs in [('encrypt_vectors.txt',plaintext,expected), ('decrypt_vectors.txt',expected,plaintext)]:
        with (output/filename).open('w', encoding='ascii') as f:
            f.write(header)
            for start in range(0,len(plaintext),16):
                f.write(f'{port_hex(inputs[start:start+16])} {port_hex(outputs[start:start+16])}\n')
    bench = ROOT/'verification/vhdl/tb_weight_file.vhd'
    shutil.copy2(bench, output/bench.name)
    # Custom simulation Tcl avoids waveform logging of millions of cycles.
    (output/'xsim_run.tcl').write_text('run all\nquit\n', encoding='ascii')
    tcl = '''set run_dir [file normalize [lindex $argv 0]]
set root [file normalize [lindex $argv 1]]
set rpc [lindex $argv 2]
set buffered [lindex $argv 3]
set folded [lindex $argv 4]
create_project weight_file [file join $run_dir project] -part xc7a100tcsg324-1
foreach name {ascon_pkg.vhd ascon_permutation.vhd ascon_aead128_core.vhd} {
  set source_file [file join $root rtl $name]
  add_files -norecurse $source_file
  set_property file_type {VHDL 2008} [get_files $source_file]
}
set_property top ascon_aead128_core [get_filesets sources_1]
set bench [file join $run_dir tb_weight_file.vhd]
add_files -fileset sim_1 -norecurse $bench
set_property file_type {VHDL 2008} [get_files $bench]
set_property top tb_weight_file [get_filesets sim_1]
set_property generic [list G_RUN_DIR=$run_dir G_ROUNDS_PER_CYCLE=$rpc G_BUFFERING_ENABLE=$buffered G_FOLDED_ABSORB=$folded] [get_filesets sim_1]
set_property xsim.simulate.custom_tcl [file join $run_dir xsim_run.tcl] [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
launch_simulation -simset sim_1 -mode behavioral
close_sim
close_project
'''
    (output/'run.tcl').write_text(tcl, encoding='ascii')
    metadata = dict(sample=str(weights), sample_sha256=sha(plaintext), plaintext_bytes=len(plaintext),
        blocks=blocks, key_hex=key.hex(), nonce_hex=nonce.hex(), key_scope='Public fixed simulation inputs only',
        associated_data_bytes=0, oracle_kats_passed=1089, tag_hex=tag.hex(), clock_hz=100_000_000,
        rounds_per_cycle=args.rounds_per_cycle, buffering=args.buffering, folded_absorb=args.folded, message_partition='Entire file in one AEAD message per direction',
        measurement='Behavioral RTL simulation, command offered to done; includes empty AD, stream handshakes, padding and tag; excludes host I/O',
        python_reference_wall_seconds=dict(encrypt=reference_encrypt_seconds,decrypt=reference_decrypt_seconds),
        source_sha256={str(path.relative_to(ROOT)):sha(path.read_bytes()) for path in
            [ROOT/'rtl/ascon_pkg.vhd',ROOT/'rtl/ascon_permutation.vhd',ROOT/'rtl/ascon_aead128_core.vhd',bench,Path(__file__),ROOT/'verification/model/ascon_ref.py']})
    (output/'inputs.json').write_text(json.dumps(metadata,indent=2)+'\n')
    if args.prepare_only:
        print(f'Prepared {output}; no RTL timing measured', flush=True)
        return
    command=[str(args.vivado.resolve()),'-mode','batch','-source',str(output/'run.tcl'),'-tclargs',str(output),str(ROOT),str(args.rounds_per_cycle),str(args.buffering).lower(),str(args.folded).lower()]
    print('Running XSim; progress is in vivado_console.log',flush=True)
    started=time.perf_counter()
    with (output/'vivado_console.log').open('w') as f:
        subprocess.run(command,cwd=output,stdout=f,stderr=subprocess.STDOUT,check=True,timeout=args.timeout)
    metadata['vivado_wall_seconds_including_compile']=time.perf_counter()-started
    records=(output/'simulation_results.txt').read_text()
    assert 'checks=2 pass=2 fail=0' in records
    measurements={}
    for mode in ['ENCRYPT','DECRYPT']:
        match=re.search(rf'^{mode} bytes=(\d+) cycles=(\d+) PASS$',records,re.MULTILINE)
        assert match and int(match[1])==len(plaintext), f'Missing {mode} full-file PASS'
        cycles=int(match[2])
        seconds=cycles/metadata['clock_hz']
        measurements[mode.lower()]=dict(cycles=cycles,seconds=seconds,milliseconds=seconds*1e3,
            microseconds=seconds*1e6,payload_mbps=len(plaintext)*8/seconds/1e6,
            payload_MB_per_second=len(plaintext)/seconds/1e6,cycles_per_byte=cycles/len(plaintext))
    def read_dump(name):
        lines=(output/name).read_text().splitlines()
        assert len(lines)==blocks and all(len(line)==32 for line in lines)
        return b''.join(bytes.fromhex(line)[::-1] for line in lines)
    actual=read_dump('ciphertext_blocks.txt')
    actual_recovered=read_dump('recovered_blocks.txt')
    actual_tag=bytes.fromhex((output/'rtl_tag.txt').read_text().strip())[::-1]
    assert actual==expected and actual_recovered==plaintext and actual_tag==tag
    # These final artifacts are saved only after the RTL authentication check.
    (output/'ciphertext.bin').write_bytes(actual)
    (output/'tag.bin').write_bytes(actual_tag)
    (output/'recovered_weights.bin').write_bytes(actual_recovered)
    metadata.update(result='PASS',measurements=measurements,recovered_sha256=sha(actual_recovered),
        ciphertext_sha256=sha(actual),mismatched_recovered_bytes=0,rtl_authenticated_and_committed=True)
    (output/'report.json').write_text(json.dumps(metadata,indent=2)+'\n')
    lines=['# Complete weight file encryption simulation','',
        f'Payload: {len(plaintext):,} bytes, one AEAD message, empty AD. All recovered bytes match.', '',
        '| Direction | Cycles | Simulated milliseconds | Payload Mb/s |', '|---|---:|---:|---:|']
    for mode,r in measurements.items():
        lines.append(f"| {mode} | {r['cycles']:,} | {r['milliseconds']:.5f} | {r['payload_mbps']:.3f} |")
    lines += ['',metadata['measurement']+'.', '',
        'Clock: assumed 100 MHz; configuration is recorded in report.json. These are behavioral simulation results, not measured FPGA performance or timing-closure proof.', '',
        'Python reference time and Vivado wall time are recorded separately in report.json; they are not RTL latency.', '',
        f'Original and recovered SHA-256: `{sha(plaintext)}`.', '',
        'Ciphertext and tag match the independently KAT-checked Python reference. RTL decryption authentication and commit were asserted by the testbench.', '',
        'Public fixed key/nonce are demonstration inputs. For real storage, use a protected key and a unique nonce per message.']
    (output/'report.md').write_text('\n'.join(lines)+'\n')
    print(json.dumps(metadata,indent=2),flush=True)


if __name__=='__main__':
    main()
