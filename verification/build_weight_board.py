"""Build a frozen Nexys A7 three-round candidate; optionally program and capture it."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[1]


def run_vivado(exe,script,args,directory):
    directory.mkdir(parents=True,exist_ok=True)
    with (directory/'console.log').open('w') as log:
        subprocess.run([str(exe),'-mode','batch','-log',str(directory/'vivado.log'),
            '-journal',str(directory/'vivado.jou'),'-source',str(script),'-tclargs',*map(str,args)],
            cwd=directory,stdout=log,stderr=subprocess.STDOUT,check=True)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output',type=Path,required=True,help='New directory; prior evidence is never overwritten')
    p.add_argument('--clock-divide',type=int,choices=range(10,129),default=12,metavar='DIVIDER',
                   help='1000 MHz MMCM VCO divider: 10=100 MHz, 12=83.333 MHz')
    p.add_argument('--vivado',type=Path,default=Path(shutil.which('vivado') or r'C:\Xilinx\Vivado\2023.2\bin\vivado.bat'))
    p.add_argument('--program',action='store_true',help='After timing closure, program volatile FPGA configuration and capture both self-tests')
    a=p.parse_args();out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
    src=out/'source';(src/'rtl').mkdir(parents=True);(src/'vivado').mkdir()
    for f in (ROOT/'rtl').iterdir():
        if f.suffix in ['.vhd','.v']:shutil.copy2(f,src/'rtl'/f.name)
    shutil.copy2(ROOT/'vivado/nexys_a7_100t.xdc',src/'vivado/nexys_a7_100t.xdc')
    (out/'source_sha256.json').write_text(json.dumps({str(f.relative_to(src)):hashlib.sha256(f.read_bytes()).hexdigest() for f in src.rglob('*') if f.is_file()},indent=2))
    route=out/'route_used.tcl';shutil.copy2(ROOT/'vivado/route_weight_board.tcl',route)
    run_vivado(a.vivado.resolve(),route,[out,src,a.clock_divide],out)
    impl=json.loads((out/'implementation.json').read_text())
    assert impl['setup_slack_ns']>=0 and impl['hold_slack_ns']>=0
    assert (out/'selftest.bit').exists()
    receipt=dict(result='TIMING PASS',implementation=impl,
                 bitstream_sha256=hashlib.sha256((out/'selftest.bit').read_bytes()).hexdigest())
    if a.program:
        script=out/'program_used.tcl';shutil.copy2(ROOT/'vivado/program_weight_board.tcl',script)
        hw=out/'hardware'
        run_vivado(a.vivado.resolve(),script,[out,hw],hw)
        subprocess.run([sys.executable,str(ROOT/'verification/decode_weight_capture.py'),str(hw),
                        '--period-ns',str(a.clock_divide)],check=True)
        receipt['hardware']=json.loads((hw/'decoded.json').read_text())
    (out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print(out/'receipt.json')


if __name__=='__main__':main()
