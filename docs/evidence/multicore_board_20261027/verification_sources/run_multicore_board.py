"""Freeze, simulate, route and optionally physically test multicore adapter slices.

Windows runner, with system GHDL in WSL. Each run gets a fresh output directory.
No DDR2 controller, full-adapter transfer or physical-memory throughput claim.
"""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
CASES = ['encrypt_ideal','decrypt_ideal','encrypt_bus_gaps_and_sink_stalls',
         'decrypt_bus_gaps_and_sink_stalls','reject_last_layer_tag','reject_ciphertext_tamper',
         'reject_chunk_identity','abort','reset_during_traffic','decrypt_after_reset']
VHDL = ['ascon_pkg','ascon_permutation','ascon_aead128_core','ascon_elastic_stage',
        'ascon_multicore','multicore_board_vectors','ascon_multicore_selftest']


def run(cmd, directory, filename):
    with (directory/filename).open('w') as f:
        result = subprocess.run(list(map(str,cmd)),cwd=directory,stdout=f,stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f'Command failed; see {directory/filename}')


def vivado(exe, script, args, directory):
    directory.mkdir(parents=True,exist_ok=False)
    for attempt in range(2):
        suffix='' if attempt==0 else '-retry'
        try:
            run([exe,'-mode','batch','-source',script,'-log',directory/f'vivado{suffix}.log',
                 '-journal',directory/f'vivado{suffix}.jou','-tclargs',*args],directory,f'console{suffix}.log')
            return
        except RuntimeError:
            log=(directory/f'console{suffix}.log').read_text(errors='replace')
            missing=re.findall(r'couldn.t read file "([^"]+)"',log)
            if attempt or not missing or not all(Path(f).is_file() for f in missing):
                raise
            # Work around the observed Windows helper file-open failure only.
            # Preserve the failed log; HDL/timing errors are never retried here.
            for f in missing:
                Path(f).read_bytes()
            print('Retrying Vivado helper-file read failure; first log preserved',flush=True)


def wsl_path(path):
    path = str(path.resolve()).replace('\\','/')
    assert path[1:3] == ':/'
    return '/mnt/'+path[0].lower()+path[2:]


def decode(directory, expected, impl):
    capture=directory/'capture.csv'
    with capture.open(newline='') as f:
        reader=csv.DictReader(f); radix=next(reader)
        names=['test_done','test_pass','test_fail','test_case[3:0]',
               'failure_code[7:0]','passed_mask[9:0]','case_cycles[319:0]']
        assert all(radix[n]=='HEX' for n in names), radix
        records=[{n:int(row[n],16) for n in names} for row in reader]
    assert len(records)==1024 and all(r==records[0] for r in records), 'Unstable capture'
    r=records[0]
    assert r['test_done']==1 and r['test_pass']==1 and r['test_fail']==0, r
    assert r['test_case[3:0]']==9 and r['failure_code[7:0]']==0 and r['passed_mask[9:0]']==1023, r
    measured=[(r['case_cycles[319:0]']>>(i*32)) & 0xffffffff for i in range(10)]
    assert measured==expected, (measured,expected)
    result=dict(result='PASS',origin='Physical FPGA ILA capture over JTAG',samples=len(records),
        clock_mhz=impl['clock_mhz'],cases=[dict(name=n,cycles=c,microseconds=c/impl['clock_mhz'])
            for n,c in zip(CASES,measured)],
        bytes_per_file=3072,layers=12,full_adapter_tested_on_board=False,ddr2_used=False,
        exact_cycle_match_with_simulation=True,capture_sha256=hashlib.sha256(capture.read_bytes()).hexdigest(),
        device_receipt=(directory/'device.txt').read_text(),raw={k:v for k,v in r.items() if k!='case_cycles[319:0]'})
    (directory/'decoded.json').write_text(json.dumps(result,indent=2)+'\n')
    return result


def capture_existing(a):
    """Resume JTAG capture after a transport failure without rebuilding the RTL."""
    out=a.output.resolve(); source=out/'source'
    hashes=json.loads((out/'source_hashes.json').read_text())
    for name,sha in hashes.items():
        assert hashlib.sha256((source/name).read_bytes()).hexdigest()==sha
    log=(out/'simulation/simulation.txt').read_text()
    assert 'BOARD_SELFTEST_SIM_PASS' in log
    assert 'CHECKER_INJECTION_PASS' in (out/'simulation/checker_injection.txt').read_text()
    expected=[int(c) for _,c in re.findall(r'CASE (\d+) CYCLES (\d+)',log)]
    assert len(expected)==10
    candidates=[]; attempts=[]
    for route in out.glob('route*'):
        if (route/'implementation.json').is_file():
            attempts.append(str(route)); info=json.loads((route/'implementation.json').read_text())
            if info['setup_slack_ns']>=0 and info['hold_slack_ns']>=0 and (route/'selftest.bit').is_file():
                candidates.append((info['clock_mhz'],route,info))
    assert candidates, 'No completed passing bitstream exists; capture cannot proceed'
    _,route,impl=max(candidates,key=lambda x:x[0]); assert impl['cores']==a.cores
    receipt=dict(cores=a.cores,implementation=impl,simulation_cycles=expected,
        checker_injection_pass=True,source_hashes=hashes,route=str(route),attempt_paths=attempts,
        synthesis_directive='RuntimeOptimized' if a.runtime_synthesis else 'Default',
        bitstream_sha256=hashlib.sha256((route/'selftest.bit').read_bytes()).hexdigest(),
        hardware=[],hardware_directories=[])
    for repeat in range(1,3):
        hw=out/f'hardware-{repeat}'
        if (hw/'decoded.json').is_file():
            result=decode(hw,expected,impl)
        else:
            if hw.exists():
                retry=1
                while (out/f'hardware-{repeat}-retry-{retry}').exists(): retry+=1
                hw=out/f'hardware-{repeat}-retry-{retry}'
            vivado(a.vivado,source/'program_multicore_board.tcl',[route,hw,a.serial],hw)
            result=decode(hw,expected,impl)
        receipt['hardware'].append(result);receipt['hardware_directories'].append(str(hw))
        print(f'PHYSICAL PASS {a.cores} cores, capture {repeat}',flush=True)
    (out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print(out/'receipt.json',flush=True)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--vectors',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--cores',type=int,choices=[1,2,4],required=True)
    p.add_argument('--divider',type=int,default=10,help='900 MHz VCO divider; 9=100 MHz,10=90 MHz,12=75 MHz')
    p.add_argument('--fallback-dividers',type=int,nargs='*',default=[])
    p.add_argument('--program',action='store_true')
    p.add_argument('--simulate-only',action='store_true')
    p.add_argument('--runtime-synthesis',action='store_true')
    p.add_argument('--capture-existing',action='store_true',help='Resume physical captures of an already simulated and timing-passing frozen build')
    p.add_argument('--serial',default='210292ABF1AAA')
    p.add_argument('--vivado',default=r'C:\Xilinx\Vivado\2023.2\bin\vivado.bat')
    a=p.parse_args()
    if a.program and a.simulate_only:
        raise ValueError('--program and --simulate-only are mutually exclusive')
    if a.capture_existing:
        if not a.program: raise ValueError('--capture-existing requires --program')
        capture_existing(a); return
    out=a.output.resolve(); out.mkdir(parents=True,exist_ok=False)
    source=out/'source'; (source/'rtl').mkdir(parents=True);(source/'verification/vhdl').mkdir(parents=True)
    for name in VHDL:
        origin=(a.vectors/'multicore_board_vectors.vhd') if name=='multicore_board_vectors' else ROOT/'rtl'/f'{name}.vhd'
        shutil.copy2(origin,source/'rtl'/f'{name}.vhd')
    shutil.copy2(ROOT/'rtl/ascon_multicore_board_top.v',source/'rtl/ascon_multicore_board_top.v')
    shutil.copy2(ROOT/'verification/vhdl/tb_multicore_selftest.vhd',source/'verification/vhdl/tb_multicore_selftest.vhd')
    for name in ['build_multicore_board.tcl','retime_multicore_board.tcl','program_multicore_board.tcl']:
        shutil.copy2(ROOT/'vivado'/name,source/name)
    shutil.copy2(a.vectors/'vectors.json',out/'vectors.json')
    hashes={str(f.relative_to(source)):hashlib.sha256(f.read_bytes()).hexdigest() for f in source.rglob('*') if f.is_file()}
    (out/'source_hashes.json').write_text(json.dumps(hashes,indent=2)+'\n')
    sim=out/'simulation'; sim.mkdir()
    # --cd is a wsl option, avoiding shell interpolation of Windows paths.
    command=['wsl','-d','Ubuntu-22.04','--cd',wsl_path(sim),'--','ghdl']
    paths=[wsl_path(source/'rtl'/f'{name}.vhd') for name in VHDL]
    paths.append(wsl_path(source/'verification/vhdl/tb_multicore_selftest.vhd'))
    run(command+['-a','--std=08',*paths],sim,'compile.log')
    run(command+['--elab-run','--std=08','tb_multicore_selftest',f'-gG_CORES={a.cores}',
        '--assert-level=error'],sim,'simulation.txt')
    log=(sim/'simulation.txt').read_text()
    assert 'BOARD_SELFTEST_SIM_PASS' in log
    expected=[int(c) for _,c in re.findall(r'CASE (\d+) CYCLES (\d+)',log)]
    assert len(expected)==10
    run(command+['--elab-run','--std=08','tb_multicore_selftest',f'-gG_CORES={a.cores}',
        '-gG_INJECT_FAILURE=true','--assert-level=error'],sim,'checker_injection.txt')
    assert 'CHECKER_INJECTION_PASS' in (sim/'checker_injection.txt').read_text()
    print(f'Simulation and checker injection PASS: {a.cores} cores, {expected}',flush=True)
    if a.simulate_only:
        (out/'receipt.json').write_text(json.dumps(dict(cores=a.cores,simulation_cycles=expected,
            simulation_pass=True,checker_injection_pass=True,source_hashes=hashes),indent=2)+'\n')
        return
    route=out/'route'; attempt_paths=[]
    for index,divider in enumerate([a.divider]+a.fallback_dividers):
        previous=route
        if index: route=out/f'route-divider-{divider}'
        attempt_paths.append(str(route))
        try:
            if index:
                vivado(a.vivado,source/'retime_multicore_board.tcl',
                    [previous/'routed.dcp',route,a.cores,divider],route)
            else:
                vivado(a.vivado,source/'build_multicore_board.tcl',
                    [source,route,a.cores,divider,'RuntimeOptimized' if a.runtime_synthesis else 'Default'],route)
            break
        except RuntimeError:
            if not (route/'implementation.json').exists() or not (route/'routed.dcp').exists():
                raise
            failed=json.loads((route/'implementation.json').read_text())
            if failed['setup_slack_ns']>=0 and failed['hold_slack_ns']>=0:
                raise
            print(f'Board timing failed at divider {divider}; reports preserved: {failed}',flush=True)
            if index==len(a.fallback_dividers):
                raise
    impl=json.loads((route/'implementation.json').read_text())
    assert impl['setup_slack_ns']>=0 and impl['hold_slack_ns']>=0
    receipt=dict(cores=a.cores,implementation=impl,simulation_cycles=expected,
        synthesis_directive='RuntimeOptimized' if a.runtime_synthesis else 'Default',
        checker_injection_pass=True,source_hashes=hashes,
        route=str(route),attempt_paths=attempt_paths,
        bitstream_sha256=hashlib.sha256((route/'selftest.bit').read_bytes()).hexdigest())
    if a.program:
        receipt['hardware']=[]
        for repeat in range(2):
            hw=out/f'hardware-{repeat+1}'
            vivado(a.vivado,source/'program_multicore_board.tcl',[route,hw,a.serial],hw)
            receipt['hardware'].append(decode(hw,expected,impl))
            print(f'PHYSICAL PASS {a.cores} cores, programming repeat {repeat+1}',flush=True)
    (out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print(out/'receipt.json',flush=True)


if __name__=='__main__':
    main()
