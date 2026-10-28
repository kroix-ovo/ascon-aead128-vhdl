"""Route one core count, applying the agreed mitigations in order. Windows/Linux."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import time

ROOT=Path(__file__).resolve().parents[1]


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--cores',type=int,choices=[1,2,4],required=True)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--vivado',default='vivado')
    p.add_argument('--initial-result',type=Path,help='Existing completed base route; retain in place')
    p.add_argument('--resume',action='store_true',help='Resume completed attempts in this frozen source snapshot')
    p.add_argument('--scratch',type=Path,help='Short working path for Vivado synthesis helpers on Windows')
    args=p.parse_args()
    out=args.output.resolve(); out.mkdir(parents=True,exist_ok=args.resume)
    frozen=out/'source'
    if not args.resume:
        (frozen/'rtl').mkdir(parents=True); (frozen/'vivado').mkdir()
        for src in list((ROOT/'rtl').glob('*.vhd'))+[ROOT/'vivado/route_multicore.tcl']:
            shutil.copy2(src,frozen/src.relative_to(ROOT))
    shutil.copy2(ROOT/'vivado/assess_multicore.tcl',frozen/'vivado/assess_multicore.tcl')
    hashes={str(path.relative_to(frozen)):hashlib.sha256(path.read_bytes()).hexdigest()
            for path in frozen.rglob('*') if path.is_file()}
    results=[]; synth=None
    stages=[('base',False,False,False,10),('boundary',True,False,False,10),
        ('local_control',True,True,False,10),('pblocks',True,True,True,10),
        ('90MHz',True,True,True,100/9),('83MHz',True,True,True,12)]
    for name,reg,local,pblock,period in stages:
        destination=out/name
        scratch=(args.scratch.resolve()/name) if args.scratch else destination
        if name=='base' and args.initial_result:
            destination=args.initial_result.resolve()
            info=json.loads((destination/'implementation.json').read_text())
            command=None
        elif args.resume and (destination/'implementation.json').exists():
            info=json.loads((destination/'implementation.json').read_text());command=None
        else:
            destination.mkdir(exist_ok=args.resume)
            scratch.mkdir(parents=True,exist_ok=True)
            command=[args.vivado,'-mode','batch','-nojournal','-nolog','-source',str(frozen/'vivado/route_multicore.tcl'),
                '-tclargs',str(destination),str(frozen),str(args.cores),str(reg).lower(),str(local).lower(),
                str(pblock).lower(),str(period)]
            if synth and name in ['pblocks','90MHz','83MHz']:
                command.append(str(synth))
            print(f'ROUTE cores={args.cores} stage={name} period={period}',flush=True)
            started=time.monotonic()
            with (destination/'console.txt').open('w') as log:
                result=subprocess.run(command,cwd=scratch,stdout=log,stderr=subprocess.STDOUT)
            if result.returncode or not (destination/'implementation.json').exists():
                original_log=(destination/'console.txt').read_text(errors='replace')
                if "couldn't read file" in original_log and ('/scripts/rt/' in original_log or '/.Xil/' in original_log):
                    # Some pinned Windows installations transiently fail a
                    # synthesis-helper Tcl read. Preserve the failure, warm the
                    # exact named file, and retry this same configuration once.
                    import re
                    for path in re.findall(r'"([^"\n]+\.tcl)"',original_log):
                        target=Path(path)
                        if target.is_file(): target.read_bytes()
                    shutil.copy2(destination/'console.txt',destination/'console_attempt1.txt')
                    with (destination/'console.txt').open('w') as log:
                        result=subprocess.run(command,cwd=scratch,stdout=log,stderr=subprocess.STDOUT)
                if result.returncode or not (destination/'implementation.json').exists():
                    raise RuntimeError(f'Vivado failed; see {destination / "console.txt"}')
            info=json.loads((destination/'implementation.json').read_text())
            info['wall_seconds']=round(time.monotonic()-started,3)
        if name=='local_control': synth=destination/'synthesized.dcp'
        info.update(stage=name,path=str(destination),command=command)
        if not (destination/'internal_timing.json').exists():
            with (destination/'assessment_console.txt').open('w') as log:
                subprocess.run([args.vivado,'-mode','batch','-nojournal','-nolog','-source',
                    str(frozen/'vivado/assess_multicore.tcl'),'-tclargs',str(destination)],
                    cwd=destination,stdout=log,stderr=subprocess.STDOUT,check=True)
        info.update(json.loads((destination/'internal_timing.json').read_text()))
        # OOC package I/O routes are not physical pins. Only synchronous
        # register-to-register timing determines the integration frequency.
        passed=info['internal_setup_slack_ns']>=0 and info['internal_hold_slack_ns']>=0
        info['timing_pass']=passed
        results.append(info)
        report=dict(cores=args.cores,part='xc7a100tcsg324-1',source_sha256=hashes,
                    attempts=results,result='PASS' if passed else 'TIMING_NOT_MET')
        (out/'report.json').write_text(json.dumps(report,indent=2)+'\n')
        print(json.dumps(info),flush=True)
        if passed: break


if __name__=='__main__': main()
