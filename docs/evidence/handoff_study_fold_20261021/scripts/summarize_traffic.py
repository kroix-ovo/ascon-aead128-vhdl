#!/usr/bin/env python3
"""Summarize fold-study traffic results; compare existing configs with the baseline study's evidence.

usage: summarize_traffic.py <results.json> <baseline traffic_results.json>
"""
import json, sys
rows = json.load(open(sys.argv[1]))
base = json.load(open(sys.argv[2]))
fields = ('cycles', 'first_in', 'first_out', 'last_out', 'n_out', 'in_stall', 'out_stall', 'auth', 'auth_ok', 'commit', 'discard', 'error')
bmap = {(r['scenario'], r['config'], r['direction'], r['tag_ok_expected']): r for r in base}
same = diff = 0
for r in rows:
    b = bmap.get((r['scenario'], r['config'], r['direction'], r['tag_ok_expected']))
    if b is None:
        continue
    if all(r[f] == b[f] for f in fields):
        same += 1
    else:
        diff += 1
        print('DIFF vs baseline', r['scenario'], r['config'], r['direction'], {f: (b[f], r[f]) for f in fields if r[f] != b[f]})
print(f'existing configs vs baseline-study evidence: {same} rows identical in {fields}, {diff} differ')
print(f"checked: {sum(r['checked'] == 'PASS' for r in rows)} PASS, "
      f"{sum(r['checked'] != 'PASS' for r in rows)} not PASS ({sorted(set((r['scenario'], r['config']) for r in rows if r['checked'] != 'PASS'))})")
print()
hdr = f"{'scenario':34s} {'dir':4s} {'ok':2s} " + ' '.join(f'{c:>22s}' for c in ('u1', 'u3', 'u3-buffered', 'u3-fold'))
print('cycles / first_out / last_out / in_stall / out_stall / median output interval   (command clock = offset 0; cycles = done-visible offset)')
print(hdr)
key = {}
for r in rows:
    key.setdefault((r['scenario'], r['direction'], r['tag_ok_expected']), {})[r['config']] = r
for (sc, d, ok), cs in key.items():
    cells = []
    for c in ('u1', 'u3', 'u3-buffered', 'u3-fold'):
        r = cs.get(c)
        cells.append('-' if r is None else f"{r['cycles']}/{r['first_out']}/{r['last_out']}/{r['in_stall']}/{r['out_stall']}/{r['steady_interval_median']}")
    print(f"{sc:34s} {d[:3]:4s} {'y' if ok else 'n':2s} " + ' '.join(f'{x:>22s}' for x in cells))
print()
print('Tail after the last output handshake (clocks): encrypt tag-out / done ; decrypt tag-in / commit-or-discard / done')
for (sc, d, ok), cs in key.items():
    if not sc.startswith(('pt1024_empty_ad', 'pt1024_late_tag', 'pt64_bad', 'ad27_pt1024', 'pt1000')):
        continue
    cells = []
    for c in ('u3-buffered', 'u3-fold'):
        r = cs.get(c)
        if r is None:
            continue
        lo = r['last_out']
        if d == 'ENCRYPT':
            cells.append(f"{c}: tag+{r['tagout_t'] - lo} done+{r['cycles'] - lo}")
        else:
            ev = r['commit_t'] if r['commit_t'] is not None else r['discard_t']
            cells.append(f"{c}: tagin+{r['tagin_t'] - lo} {'commit' if r['commit_t'] is not None else 'discard'}+{ev - lo} done+{r['cycles'] - lo}")
    print(f"{sc:34s} {d[:3]:4s} {'y' if ok else 'n':2s} " + ' | '.join(cells))
