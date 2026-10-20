"""Collect frozen-source comparison and route receipts into reviewable evidence."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil


def read_route(path):
    raw=(path/'implementation.json').read_text().strip()
    data=json.loads(raw if raw.startswith('{') else '{'+raw+'}')
    util=(path/'utilization.txt').read_text()
    for label,key in [('Slice LUTs','luts'),('Slice Registers','registers')]:
        data[key]=int(re.search(r'\|\s*'+label+r'\*?\s*\|\s*(\d+)',util)[1])
    data['timing_closed']=data['setup_slack_ns']>=0 and data['hold_slack_ns']>=0
    data['source_directory']=str(path.resolve())
    return data


def copy_report(source, destination):
    # Review copies omit vendor trailing whitespace. Raw reports stay in build.
    if source.suffix in ['.txt', '.xdc']:
        clean = '\n'.join(line.rstrip() for line in source.read_text().splitlines()).rstrip() + '\n'
        destination.write_bytes(clean.encode())
    else:
        shutil.copy2(source, destination)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--baseline-comparison',type=Path,required=True)
    p.add_argument('--candidate-comparison',type=Path,required=True)
    p.add_argument('--baseline-route',type=Path,required=True)
    p.add_argument('--u3-route',type=Path,required=True)
    p.add_argument('--buffered-route',type=Path,required=True)
    p.add_argument('--board-route',type=Path)
    p.add_argument('--hardware',type=Path)
    p.add_argument('--output',type=Path,required=True)
    a=p.parse_args();a.output.mkdir(parents=True,exist_ok=False)
    baseline=json.loads((a.baseline_comparison/'report.json').read_text())
    candidates=json.loads((a.candidate_comparison/'report.json').read_text())
    result=dict(base_sha=baseline['base_sha'],payload=candidates['payload'],
        simulations=[r for r in baseline['variants'] if r['variant']=='baseline']+candidates['variants'],
        core_routes={},board_route=None,hardware=None,
        boundaries='Simulation cycles exclude host transfers. Core-only routes have unconstrained external I/O. Board route includes wrapper, generated clock and debug; asynchronous UI/indicator timing is excluded.')
    for n,d in [('baseline',a.baseline_route),('u3',a.u3_route),('u3-buffered',a.buffered_route)]:
        result['core_routes'][n]=read_route(d)
        dst=a.output/n;dst.mkdir()
        for f in ['timing.txt','utilization.txt','timing_checks.txt','setup_paths.txt','hold_paths.txt','constraints.xdc']:
            if (d/f).exists():copy_report(d/f,dst/f)
    if a.board_route:
        result['board_route']=read_route(a.board_route)
        dst=a.output/'board';dst.mkdir()
        for f in ['timing.txt','utilization.txt','timing_checks.txt','clocks.txt','constraints.xdc','source_sha256.json']:
            copy_report(a.board_route/f,dst/f)
        if (a.board_route/'selftest.bit').exists():
            result['board_route']['bitstream_sha256']=hashlib.sha256((a.board_route/'selftest.bit').read_bytes()).hexdigest()
    if a.hardware:
        result['hardware']=json.loads((a.hardware/'decoded.json').read_text())
        dst=a.output/'hardware';dst.mkdir()
        for f in ['capture.csv','device.txt','decoded.json']:copy_report(a.hardware/f,dst/f)
    shutil.copy2(a.candidate_comparison/'tensor_manifest.json',a.output/'tensor_manifest.json')
    (a.output/'report.json').write_text(json.dumps(result,indent=2)+'\n')
    print(a.output/'report.json')


if __name__=='__main__':main()
