#!/usr/bin/env python3
"""Closed-form cycle model of the G_FOLDED_ABSORB core (always-ready source/sink, bench convention:
command clock = offset 0 .. done visible), checked against every measured always-ready run, plus the
baseline study's model (existing controller) and its predictions for comparison.

usage: fold_cycle_model.py <traffic results.json> <weight_runs.json>
"""
import json, math, sys


def fold(ad, pt):
    # cmd 1 + p12 4 + one absorb-only clock (first AD block, or first payload block when AD is empty;
    # the empty-AD beat itself is consumed during p12) + 3 per p8 (tail folds the next absorb,
    # DSEP, final padding and the finalization key) + p12 4 + tag 1 + zeroize 1 + done 1.
    nb_ad = (ad // 16 + 1) if ad else 0
    return 13 + 3 * (nb_ad + pt // 16)


def existing(ad, pt, R, buffered):  # baseline study's validated model (cycle_model.py, current())
    G8, G12 = math.ceil(8 / R), math.ceil(12 / R)
    t = 1 + 1 + G12 + 1
    if ad == 0:
        t += 1
    else:
        nb = math.ceil(ad / 16)
        t += nb * (1 + 1 + G8 + 1)
        if ad % 16 == 0:
            t += 1 + G8 + 1
    nfull, rem = divmod(pt, 16)
    t += nfull * ((1 + 1 + G8 + 1) if buffered else (1 + 1 + 1 + G8 + 1))
    t += 2 if rem else (1 if pt == 0 else 0)
    t += 1 + G12 + 1 + 1 + 2
    return t


PRED = {  # baseline study predictions (INFERRED there), adapter / 1 KiB, R=3, empty AD
    'P1+P2 (4 clk/block)': (599442, 274), 'P3_tail_fold': (449587, 211),
    'P3+fixed_fusions': (449583, 207), 'floor_rounds_only': (449578, 202)}

if __name__ == '__main__':
    traffic = json.load(open(sys.argv[1])); weights = json.load(open(sys.argv[2]))
    cfg = {'u1': (1, False), 'u3': (3, False), 'u3-buffered': (3, True)}
    ok = bad = 0
    for r in traffic:
        if r['generics'] or r.get('framing'):
            continue
        m = fold(r['ad_bytes'], r['pt_bytes']) if r['config'] == 'u3-fold' else existing(r['ad_bytes'], r['pt_bytes'], *cfg[r['config']])
        if m == r['cycles']:
            ok += 1
        else:
            bad += 1; print('MISMATCH', r['scenario'], r['config'], r['direction'], 'model', m, 'measured', r['cycles'])
    for r in weights:
        m = fold(0, r['bytes']) if r['variant'] == 'u3-fold' else existing(0, r['bytes'], *cfg[r['variant']])
        for d, c in r['cycles'].items():
            if m == c: ok += 1
            else: bad += 1; print('MISMATCH', r['variant'], r['sample'], d, m, c)
    print(f'model check: {ok} measured always-ready rows reproduced exactly, {bad} mismatches')
    print()
    N = 2397696 // 16
    print('Adapter (2,397,696 B, N=149,856) and 1 KiB (N=64), R=3, empty AD:')
    print(f"  measured u3-buffered            {existing(0, 2397696, 3, True):>9,d}  {existing(0, 1024, 3, True):>5d}  (6 clk/block)")
    for k, (a, b) in PRED.items():
        print(f"  predicted {k:22s}{a:>9,d}  {b:>5d}")
    print(f"  MEASURED u3-fold (model 3N+13)  {fold(0, 2397696):>9,d}  {fold(0, 1024):>5d}  (3 clk/block)")
