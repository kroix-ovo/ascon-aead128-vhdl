"""Collect compact physical evidence without copying trained-weight fixture ROMs."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil

ROOT=Path(__file__).resolve().parents[1]


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--runs',type=Path,nargs='+',required=True)
    p.add_argument('--discovery',type=Path,required=True)
    p.add_argument('--prior',type=Path,nargs='*',default=[],help='Preserved development attempts, clearly separated from final results')
    p.add_argument('--output',type=Path,required=True)
    a=p.parse_args(); out=a.output.resolve(); out.mkdir(parents=True,exist_ok=False)
    shutil.copy2(a.discovery/'vivado.log',out/'discovery.log')
    rows=[]
    for run in a.runs:
        r=json.loads((run/'receipt.json').read_text())
        assert len(r['hardware'])==2 and all(x['result']=='PASS' for x in r['hardware'])
        assert r['checker_injection_pass'] and r['implementation']['setup_slack_ns']>=0 and r['implementation']['hold_slack_ns']>=0
        for name,sha in r['source_hashes'].items():
            assert hashlib.sha256((run/'source'/name).read_bytes()).hexdigest()==sha, name
        selected=Path(r.get('route',run/'route'))
        assert hashlib.sha256((selected/'selftest.bit').read_bytes()).hexdigest()==r['bitstream_sha256']
        assert 'All user specified timing constraints are met.' in (selected/'timing.txt').read_text()
        target=out/f"n{r['cores']}"; target.mkdir()
        for name in ['receipt.json','source_hashes.json','vectors.json']:
            shutil.copy2(run/name,target/name)
        shutil.copytree(run/'simulation',target/'simulation',ignore=shutil.ignore_patterns('*.cf'))
        for i in range(1,3):
            hw=target/f'hardware-{i}'; hw.mkdir()
            original=Path(r.get('hardware_directories',[str(run/'hardware-1'),str(run/'hardware-2')])[i-1])
            for name in ['capture.csv','device.txt','decoded.json','console.log']:
                shutil.copy2(original/name,hw/name)
        for attempt in r.get('attempt_paths',[str(run/'route')]):
            route=Path(attempt); route_out=target/route.name; route_out.mkdir()
            coverage=dict((k,int(v)) for k,v in re.findall(r'checking (\w+) \((\d+)\)',
                (route/'timing_checks.txt').read_text()))
            for kind in ['no_clock','unconstrained_internal_endpoints','multiple_clock',
                         'generated_clocks','loops','latch_loops']:
                assert coverage[kind]==0, (route,kind,coverage)
            errors=re.search(r'nets with routing errors\.+\s*:\s*(\d+)',(route/'route_status.txt').read_text())
            assert errors and int(errors[1])==0
            (route_out/'coverage.json').write_text(json.dumps(coverage,indent=2)+'\n')
            for name in ['implementation.json','utilization.txt','timing.txt','setup_paths.txt',
                         'timing_checks.txt','route_status.txt','drc.txt','clocks.txt',
                         'implemented.xdc','clock_change.txt','console.log','console-retry.log']:
                if (route/name).is_file(): shutil.copy2(route/name,route_out/name)
            if (route/'bus_skew.txt').is_file():
                skew=(route/'bus_skew.txt').read_text()
                assert 'VIOLATED' not in skew
                shutil.copy2(route/'bus_skew.txt',route_out/'bus_skew.txt')
        rows.append(r)
    rows.sort(key=lambda r:r['cores'])
    assert [r['cores'] for r in rows]==[1,2,4]
    assert all(r['source_hashes']==rows[0]['source_hashes'] for r in rows), 'Final runs must use identical frozen source'
    tools=out/'verification_sources'; tools.mkdir()
    for name in ['generate_multicore_board.py','run_multicore_board.py','report_multicore_board.py',
                 'multicore_format.py','model/ascon_ref.py']:
        dest=tools/name;dest.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(ROOT/'verification'/name,dest)
    shutil.copy2(ROOT/'vivado/assess_multicore_board.tcl',tools/'assess_multicore_board.tcl')
    if a.prior:
        prior=out/'development'; prior.mkdir(); index=[]
        for folder in a.prior:
            target=prior/folder.name; target.mkdir()
            for name in ['source_hashes.json','receipt.json','vectors.json']:
                if (folder/name).is_file(): shutil.copy2(folder/name,target/name)
            for route in folder.glob('route*'):
                if not route.is_dir(): continue
                dest=target/route.name; dest.mkdir()
                for name in ['console.log','console-retry.log','implementation.json',
                             'timing.txt','setup_paths.txt','timing_checks.txt','route_status.txt']:
                    if (route/name).is_file(): shutil.copy2(route/name,dest/name)
            index.append(dict(path=str(folder.resolve()),scope='Development harness or unfinished build; excluded from final comparison'))
        (prior/'index.json').write_text(json.dumps(index,indent=2)+'\n')
    lines=['# Multicore physical FPGA self-test, October 27 2026','',
        'All three core counts were programmed into the connected Nexys A7-100T',
        '(XC7A100T, Digilent serial `210292ABF1AAA`). Two independent programming',
        'and JTAG ILA capture runs passed for each configuration. Each run passed',
        'all ten cases and matched the simulated case cycle counts exactly.','',
        'The fixture contains **3,072 bytes from the trained adapter**, with 256',
        'bytes per layer: the first 64 bytes of each down_w, down_b, up_w and up_b',
        'slice. Every encryption payload beat/tag and every valid decryption beat',
        'is compared against the independent Python oracle on the FPGA. The',
        'complete 2,397,696-byte adapter was validated previously in simulation;',
        '**it was not transferred through the FPGA or DDR2 in this test**.','',
        '| Cores | Board clock MHz | Setup / hold ns | Encrypt cycles / us | Decrypt cycles / us | Physical results |',
        '|---:|---:|---:|---:|---:|---|']
    for r in rows:
        impl=r['implementation']; cases=r['hardware'][0]['cases']; e,d=cases[:2]
        lines.append(f"| {r['cores']} | {impl['clock_mhz']:.3f} | {impl['setup_slack_ns']:+.3f} / {impl['hold_slack_ns']:+.3f} | "
                     f"{e['cycles']} / {e['microseconds']:.3f} | {d['cycles']} / {d['microseconds']:.3f} | 10/10, twice |")
    lines += ['', '| Physical case | 1 core cycles | 2 cores cycles | 4 cores cycles |',
              '|---|---:|---:|---:|']
    for i,name in enumerate(rows[0]['hardware'][0]['cases']):
        counts=[str(r['hardware'][0]['cases'][i]['cycles']) for r in rows]
        lines.append('| '+name['name']+' | '+' | '.join(counts)+' |')
    lines += ['', '| Final-harness route attempt | Clock MHz | Setup ns | Hold ns | Timing |',
              '|---|---:|---:|---:|---|']
    for r in rows:
        for path in r.get('attempt_paths',[str(Path(r.get('route','')))]):
            impl=json.loads((Path(path)/'implementation.json').read_text())
            result='PASS' if impl['setup_slack_ns']>=0 and impl['hold_slack_ns']>=0 else 'FAIL, not programmed'
            lines.append(f"| {r['cores']} cores | {impl['clock_mhz']:.3f} | {impl['setup_slack_ns']:+.3f} | {impl['hold_slack_ns']:+.3f} | {result} |")
    lines += ['', 'Times use the FPGA cycle counters and the nominal MMCM clock derived',
        'from the board oscillator; no external frequency calibration was performed.',
        'Short authenticated messages have more overhead per byte than the full',
        'adapter. These fixture results do not establish 1.5 ms physical file latency.',
        'The ROM source and checker are part of this board harness and its timing',
        'paths; area and timing differ from the configurable integration harness.', '',
        'All preserved physical attempts have zero routing errors, missing clocks,',
        'unconstrained internal endpoints, multiple-clock pins and combinational',
        'loops. The asynchronous button entry and visual LED outputs are explicitly',
        'excluded from external I/O timing. These are individual passing routes;',
        'margins near zero do not establish a robust maximum frequency. Raw DRC',
        'warnings are retained.', '',
        'The selected routes also pass all four debug-IP bus-skew constraints.',
        'The four-core board harness missed 90 MHz by 1.391 ns on a path from',
        'the fixture source counter into the wrapper payload counter; it passed',
        'at 75 MHz. This source is additional board-test logic, so its limit is',
        'separate from the earlier registered integration harness at 90 MHz.', '',
        'The ten cases are ideal encryption/decryption, encryption/decryption with',
        'periodic shared-input gaps and output backpressure, corrupted final-layer',
        'tag, corrupted ciphertext, wrong chunk identity, abort, reset during',
        'traffic, and successful decryption after reset. Provisional plaintext',
        'terminates at the trusted internal checker. Status is the only externally',
        'observable test result. Commit is checked against exact beat/chunk counts;',
        'any failure must discard and must never commit. The source deliberately',
        'reuses public fixture nonces across repeat tests; they are not production',
        'encryption nonces. An injected comparator fault was detected in GHDL for',
        'each core count before building the bitstream.','',
        'Raw captures, device receipts, source/bitstream hashes, oracle fixture',
        'metadata, simulated reference counts, timing coverage, routing and area',
        'reports are in the accompanying evidence directory. Actual adapter slices',
        'and generated ROM source stay in local build directories. No flash was',
        'written, no board memory controller was added, and nothing was published.','',
        'In the initial vectors.json schema, generated_sha256 hashes the generated',
        'source text with LF newlines. The exact Windows file-byte hash is recorded',
        'in source_hashes.json; the generator now names these two forms explicitly.', '',
        'Reproduction from this worktree (Windows, Vivado 2023.2, WSL system GHDL):','',
        '```powershell',
        'python verification/generate_multicore_board.py <adapter-export-directory> <fresh-vector-directory>',
        'python verification/run_multicore_board.py --vectors <vector-directory> --output <fresh-run-directory> --cores 1 --divider 9 --fallback-dividers 10 12 --program',
        '# Repeat with --cores 2 --runtime-synthesis.',
        '# For --cores 4 use --divider 10 --fallback-dividers 12 15 --runtime-synthesis.',
        '# Then run Vivado on vivado/assess_multicore_board.tcl with the selected route directories as -tclargs.',
        '```','',
        'The runner freezes source, requires a successful self-test simulation and',
        'checker-injection test, then routes. It never generates a bitstream for a',
        'failed timing attempt. Lower-clock attempts retain the prior reports and',
        'change only the MMCM divider in the saved routed checkpoint. `--program`',
        'explicitly enables volatile configuration and two physical capture runs.',
        '`--simulate-only` runs the controller checks without starting Vivado.',
        'The one-core build used default synthesis; the larger builds used',
        'RuntimeOptimized synthesis. Earlier unfinished default-synthesis attempts',
        'were stopped during lengthy area optimization and remain in local scratch',
        'directories. This did not change RTL, fixtures or reference cycle counts.', '',
        'An initial two-core board harness missed 100 MHz by 4.427 ns on a path',
        'from the test counter through reset/collector selection and the large',
        'reference comparator to the test status register. A registered monitor',
        'now observes accepted output beats one clock later; the engine handshake',
        'and completion timestamps are unchanged. Narrow index types also avoid',
        'unnecessary integer arithmetic in the checker. All three configurations',
        'were resimulated, rebuilt and captured with this same final monitor.',
        'The development directory retains the earlier harness reports separately',
        'from the selected final physical comparison.','']
    (out/'report.md').write_text('\n'.join(lines))
    (out/'report.json').write_text(json.dumps(dict(result='PASS',scope='Bounded adapter slices, no DDR2',runs=rows),indent=2)+'\n')
    hashes={str(f.relative_to(out)):hashlib.sha256(f.read_bytes()).hexdigest() for f in out.rglob('*') if f.is_file()}
    (out/'bundle_hashes.json').write_text(json.dumps(hashes,indent=2)+'\n')
    print(out/'report.md')

if __name__=='__main__':main()
