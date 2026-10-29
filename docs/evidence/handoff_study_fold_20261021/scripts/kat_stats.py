#!/usr/bin/env python3
"""KAT TextIO cycle statistics; per-case identity check against the earlier baseline study.

Compares every CASE line (outputs, tag, auth, cycles) of this study's runs with the
baseline study's runs in ~/ascon_handoff_scratch (same bench, same vector file),
excluding only the new G_FOLDED_ABSORB configuration which has no baseline.
"""
import re, statistics
from pathlib import Path
S = Path.home() / 'ascon_fold_scratch/runs/kat_textio'
B = Path.home() / 'ascon_handoff_scratch/runs/kat_textio'
rx = r'CASE (\d+) (ENCRYPT|DECRYPT) ad_len=(\d+) msg_len=(\d+).*?cycles=(\d+) (PASS|FAIL)'
for cfg in ['u1', 'u3', 'u3-buffered', 'u3-fold']:
    p = S / cfg / 'simulation_results.txt'
    if not p.exists():
        continue
    txt = p.read_text()
    rows = re.findall(rx, txt)
    cyc = [int(r[4]) for r in rows]
    p32 = [int(r[4]) for r in rows if r[3] == '32' and r[1] == 'ENCRYPT']
    e00 = [int(r[4]) for r in rows if r[2] == '0' and r[3] == '0']
    print(cfg, 'checks', len(rows), 'pass', sum(r[5] == 'PASS' for r in rows), 'min', min(cyc), 'max', max(cyc),
          'mean %.3f' % statistics.mean(cyc), 'enc msg32 mean %.3f' % statistics.mean(p32),
          'empty/empty', sorted(set(e00)))
    print('  ', txt.strip().splitlines()[-1])
    bp = B / cfg / 'simulation_vectors.txt'
    if bp.exists():
        a = (S / cfg / 'simulation_vectors.txt').read_text()
        b = bp.read_text()
        print('   identical machine-readable results (outputs, tags, auth, cycles) vs baseline study:', a == b)
