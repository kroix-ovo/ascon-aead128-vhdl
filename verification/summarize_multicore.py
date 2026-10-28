"""Build the comparison document from saved receipts, without rerunning tools."""
import argparse
import json
import re
from pathlib import Path


def load(path):
    return json.loads(Path(path).read_text())


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--default',type=Path,required=True)
    p.add_argument('--registered',type=Path,required=True)
    p.add_argument('--wholefile',type=Path,required=True)
    p.add_argument('--timing',type=Path,nargs='*',default=[])
    p.add_argument('--local-control',type=Path)
    p.add_argument('--output',type=Path,required=True)
    args=p.parse_args()
    normal,registered,whole=load(args.default),load(args.registered),load(args.wholefile)
    assert normal['result']==registered['result']=='PASS'
    lines=['# Folded Ascon multicore study','',
        'The 2,397,696-byte FP32 adapter was gathered into twelve 199,808-byte layer chunks. '
        'Every ciphertext beat and tag matched the independent Python reference. All decryption runs '
        'reconstructed both the original file and the original checkpoint exactly. No training, '
        'board programming, physical memory benchmark, or publication was performed.','',
        'The simulated clock is 10 ns. These cycle-derived throughputs do not establish a routed '
        'hardware clock. Routed internal timing and modeled memory service are reported separately.','',
        '## Always-ready simulation','',
        '| Boundary queues | Cores | Direction | Cycles | Time ms | Payload MB/s | First output cycles | Commit tail cycles | Chunk latency min–max |',
        '|---|---:|---|---:|---:|---:|---:|---:|---:|']
    for label,report in [('bypass',normal),('registered ready',registered)]:
        for row in report['runs']:
            if row['profile']!='ideal' or row['fault']: continue
            latency=row['per_chunk_latency']; m=row['metrics']
            lines.append(f"| {label} | {row['cores']} | {row['direction']} | {m['cycles']:,} | "
                f"{m['cycles']/100000:.5f} | {row['payload_MBps']:.3f} | {row['first_output_cycles']} | "
                f"{row['file_commit_tail_cycles']} | {min(latency):,}–{max(latency):,} |")
    lines += ['', 'Commit tail starts at the last accepted input payload beat. Output writes and tags '
        'can finish later; the JSON receipts also retain the final output-write timestamp. '
        'Every chunk has 96 bytes of authenticated metadata and its own nonce/tag.','',
        '## Scaling and historical baselines','',
        '| Configuration | Encrypt cycles | Decrypt cycles | Encrypt MB/s |',
        '|---|---:|---:|---:|']
    baselines={r['variant']:r for r in whole['variants'] if r['sample']=='full'}
    for name in ['baseline','u3-buffered','u3-fold']:
        r=baselines[name]; c=r['cycles']['ENCRYPT']
        lines.append(f"| Whole-file {name} | {c:,} | {r['cycles']['DECRYPT']:,} | {2397696/(c*1e-8)/1e6:.3f} |")
    ideal={r['cores']:r for r in normal['runs'] if r['profile']=='ideal' and r['direction']=='encrypt'}
    for n,r in ideal.items():
        lines.append(f"| Chunked folded ×{n} | {r['metrics']['cycles']:,} | "
            f"{next(x for x in normal['runs'] if x['cores']==n and x['profile']=='ideal' and x['direction']=='decrypt')['metrics']['cycles']:,} | {r['payload_MBps']:.3f} |")
    lines += ['',f"Two cores achieve {ideal[1]['metrics']['cycles']/ideal[2]['metrics']['cycles']:.5f}× "
        f"and four achieve {ideal[1]['metrics']['cycles']/ideal[4]['metrics']['cycles']:.5f}× versus one "
        'chunked folded core. Four cores approach the separate 128-bit buses’ 1,600 MB/s payload ceiling. '
        f"Relative to whole-file buffered u3, four cores achieve {baselines['u3-buffered']['cycles']['ENCRYPT']/ideal[4]['metrics']['cycles']:.5f}×; "
        f"relative to original u1, {baselines['baseline']['cycles']['ENCRYPT']/ideal[4]['metrics']['cycles']:.5f}×. "
        'Those denominators are intentionally different.','',
        'The source and collector each move at most one beat per clock. Two folded cores demand '
        'about 1,066.7 MB/s; four demand about 2,133.3 MB/s before bus contention. Equal chunk '
        'assignments balance work counts, while bus service still determines how often absorption can occur.','',
        '## Utilization and core waits','',
        'The table below uses registered-ready boundary queues and ideal service, encryption. '
        'Per-core lists are in lane order. Busy includes all time with an active command.','',
        '| Cores | Input total / payload % | Output total / payload % | Busy % per core | Internal starvation | Internal output block | Missed fold tails |',
        '|---:|---:|---:|---|---|---|---|']
    for row in registered['runs']:
        if row['profile']!='ideal' or row['direction']!='encrypt':continue
        n=row['cores']; m=row['metrics']
        seq=lambda prefix: '/'.join(str(m[f'{prefix}_{i}']) for i in range(n))
        lines.append(f"| {n} | {100*row['input_bus_utilization']:.3f} / {100*row['input_payload_utilization']:.3f} | "
            f"{100*row['output_bus_utilization']:.3f} / {100*row['output_payload_utilization']:.3f} | "
            f"{'/'.join(f'{v:.3f}' for v in row['per_core_busy_percent'])} | {seq('starved')} | {seq('blocked')} | {seq('missed_tail')} |")
    lines += ['', 'A missed fold tail is an unavailable absorb opportunity while the tail still performs '
        'rounds. The engine may absorb on the next clock without spending a clock waiting in its '
        'absorb-only state. Consequently a low starvation-state count does not imply an unlimited '
        'input bus. Do not add tail misses, busy clocks, interface waits and internal stalls together.','',
        'The receipts partition source waits into setup, input capacity, shared-memory service, and '
        'arbitration; collector waits distinguish external sink backpressure from arbitration. '
        'See [the interface and metric definitions](multicore_format.md).','',
        '## Memory-service model','',
        'These bandwidth values are assumptions, not measured DDR2 results. A shared token budget '
        'charges both reads and writes, including AD and tags. The table uses registered-ready boundaries.','',
        '| Cores | Budget GB/s | Encrypt ms | Decrypt ms | Encrypt payload MB/s |',
        '|---:|---:|---:|---:|---:|']
    for n in [1,2,4]:
        for profile,budget in [('memory_1GBps',1),('memory_1p3GBps',1.3)]:
            rows={r['direction']:r for r in registered['runs'] if r['cores']==n and r['profile']==profile}
            lines.append(f"| {n} | {budget} | {rows['encrypt']['metrics']['cycles']/100000:.5f} | "
                f"{rows['decrypt']['metrics']['cycles']/100000:.5f} | {rows['encrypt']['payload_MBps']:.3f} |")
    lines += ['', 'A read plus a write of the payload alone is 4,795,392 bytes: the bandwidth-only '
        'lower bound is 4.795392 ms at 1 GB/s or 3.688763 ms at 1.3 GB/s. Actual modeled times '
        'also include service scheduling and chunk overhead. A later release copy would add traffic; '
        'it is excluded here. No physical file-time result is available.','',
        'Two and four cores have almost the same file time under these aggregate memory budgets. '
        'Two folded cores already exceed the 0.5–0.65 GB/s payload ceiling imposed by a read plus '
        'a write at 1–1.3 GB/s aggregate service. Actual controller traffic measurements should '
        'therefore guide the eventual core-count choice.','',
        '## Routed timing and area','',
        'Target: xc7a100tcsg324-1, Vivado 2023.2, registered integration harness. '
        'Setup/hold below are register-to-register results, including shared control, dispatcher and '
        'collector paths. External OOC ports have no package placement; their nominal zero-delay '
        'I/O checks are retained in reports but cannot establish physical I/O timing.','',
        '| Cores | Attempt | MHz | Internal setup ns | Internal hold ns | LUTs | Registers | BRAM primitives | Pass |',
        '|---:|---|---:|---:|---:|---:|---:|---:|---|']
    timing=[]
    for path in args.timing:
        report=load(path);timing.append(report)
        for r in report['attempts']:
            lines.append(f"| {report['cores']} | {r['stage']} | {1000/r['period_ns']:.3f} | "
                f"{r['internal_setup_slack_ns']:+.3f} | {r['internal_hold_slack_ns']:+.3f} | "
                f"{r['luts']:,} | {r['register_count']:,} | {r['bram_primitives']} | {'yes' if r['timing_pass'] else 'no'} |")
    if not timing: lines += ['', '**Timing study is still running; no closure claim is made.**']
    if timing:
        lines += ['', '| Cores | Passing configuration | Routed MHz | Kernel encrypt ms | Kernel payload MB/s |',
                  '|---:|---|---:|---:|---:|']
        local_report=load(args.local_control) if args.local_control else None
        for report in timing:
            passed=[r for r in report['attempts'] if r['timing_pass']]
            if not passed:
                lines.append(f"| {report['cores']} | No attempted frequency passed | — | — | — |")
                continue
            r=passed[-1]
            sim=local_report if r['local_control'] else registered if r['registers'] else normal
            if sim is None:
                lines.append(f"| {report['cores']} | {r['stage']} (matching simulation pending) | {1000/r['period_ns']:.3f} | — | — |")
                continue
            row=next(x for x in sim['runs'] if x['cores']==report['cores'] and x['profile']=='ideal' and x['direction']=='encrypt')
            seconds=row['metrics']['cycles']*r['period_ns']*1e-9
            lines.append(f"| {report['cores']} | {r['stage']} | {1000/r['period_ns']:.3f} | {seconds*1000:.5f} | {row['bytes']/seconds/1e6:.3f} |")
        selected=[(path,report,next((r for r in reversed(report['attempts']) if r['timing_pass']),None))
                  for path,report in zip(args.timing,timing)]
        margins=[r['internal_setup_slack_ns'] for _,_,r in selected if r]
        if margins:
            lines += ['',f"Selected internal setup margins range from {min(margins):.3f} to {max(margins):.3f} ns. "
                      'These are single-route results.','',
                      '| Cores | Selected critical-path class | Logic levels |',
                      '|---:|---|---:|']
            for path,report,r in selected:
                if not r:continue
                text_path=path.parent/r['stage']/'internal_setup_paths.txt'
                if not text_path.exists():text_path=Path(r['path'])/'internal_setup_paths.txt'
                if not text_path.exists():continue
                text=text_path.read_text()
                source=re.search(r'Source:\s+([^\n]+)',text).group(1)
                destination=re.search(r'Destination:\s+([^\n]+)',text).group(1)
                levels=re.search(r'Logic Levels:\s+(\d+)',text).group(1)
                label='See internal setup report'
                if '.core/s_reg_reg' in source and '.core/s_reg_reg' in destination:label='Folded state-register feedback'
                elif '.rx_boundary/' in destination:label='Framing/control to core input boundary'
                lines.append(f"| {report['cores']} | {label} | {levels} |")
            lines += ['', 'Detailed endpoints and cell/net delays are in the saved internal setup reports.','']
    lines += ['', 'Mitigations are attempted in order: boundary queues, local control registers, '
        'separate core Pblocks, 90 MHz, then 83.333 MHz. Each attempt retains a source snapshot and '
        'reports. The table lists executed attempts; the runner stops at the first passing route. '
        'One passing route establishes feasibility for that run, not repeatable timing margin '
        'or physical board throughput. No bitstream was written or programmed.','',
        'The first prototype exposed a ready/selection combinational loop when an unselected tag '
        'candidate was zeroed. Candidate data is now independent of arbitration. Early timing then '
        'identified a long select/subtract/framing-check path. Final-beat geometry is now registered '
        'once and candidate checks run in parallel. Earlier prototype routes are superseded and '
        'must not be quoted as final-design timing.','',
        '## Reproduction and evidence','',
        'Run `verification/run_multicore.py --help` for the GHDL and compiled Verilator paths, '
        '`verification/route_multicore.py --help` for routing, and '
        '`verification/summarize_multicore.py --help` to regenerate this comparison. '
        'The full study uses the existing export; it performs no training or downloads. '
        'Output directories must be new; route resume uses its frozen source snapshot.','',
        'A shorter WSL/Linux entry point is '
        '`bash verification/benchmark_multicore.sh EXPORT_DIR NONCE_BASE FRESH_OUTPUT --registers`. '
        'It uses the existing export and checkpoint, and selects the compiled path when Verilator '
        'and the local OSS CAD Suite GHDL are available. `ASCON_SYNTH_GHDL` can override the synthesis tool path.','',
        'The full reports retain source/tool hashes, nonce ranges, commands, per-chunk timestamps, '
        'bus counts, and per-core waits. Fresh encryption ranges are required for new runs. '
        'All performance numbers are decimal MB/s. Reference artifacts remain in ignored build '
        'directories or WSL scratch; the compact evidence bundle excludes weight binaries.','']
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text('\n'.join(lines),encoding='utf-8')
    summary=dict(default_report=str(args.default),registered_report=str(args.registered),
        wholefile_report=str(args.wholefile),timing_reports=list(map(str,args.timing)),
        ideal_default={str(n):dict(cycles=r['metrics']['cycles'],payload_MBps=r['payload_MBps']) for n,r in ideal.items()})
    args.output.with_suffix('.json').write_text(json.dumps(summary,indent=2)+'\n')


if __name__=='__main__': main()
