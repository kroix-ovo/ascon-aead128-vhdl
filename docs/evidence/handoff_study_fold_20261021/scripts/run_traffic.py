#!/usr/bin/env python3
"""Traffic/phase scenarios on plain RTL for u1/u3/u3-buffered/u3-fold, checked against ascon_ref.

usage: run_traffic.py <out_root> <nonce_base> [comma-separated scenario filter]
Scenario list = the baseline study's (build/handoff_sim/scripts/run_traffic.py) plus AD 15/17,
ciphertext tamper, FIFO depth 1/1 and 3/3, and an AD framing probe. Every encryption message uses
a fresh nonce under its scenario key (nonce = nonce_base + scenario index). Cycle counts do not
depend on data, so they are comparable with the baseline study's evidence.
"""
import json, random, re, statistics, subprocess, sys
from pathlib import Path

S = Path.home() / 'ascon_fold_scratch'
W = S / 'wt'
root = Path(sys.argv[1]); base = int(sys.argv[2])
sys.path.insert(0, str(W / 'verification/model'))
from ascon_ref import encrypt, decrypt  # noqa: E402

CONFIGS = {'u1': (1, False, False), 'u3': (3, False, False), 'u3-buffered': (3, True, False), 'u3-fold': (3, True, True)}
rng = random.Random(20261021)


def ph(d): return d.ljust(16, b'\0')[::-1].hex().upper()


# name: (ad_bytes, pt_bytes, generics, tamper, configs, framing)
ALL = list(CONFIGS)
SCEN = {
    'min_empty_ad_empty_pt': (0, 0, {}, None, ALL, None),
    'pt1_empty_ad': (0, 1, {}, None, ALL, None),
    'pt16_empty_ad': (0, 16, {}, None, ALL, None),
    'pt1024_empty_ad': (0, 1024, {}, None, ALL, None),
    'pt1024_late_tag': (0, 1024, {'G_TAG_EARLY': 'false'}, None, ALL, None),
    'pt1000_partial_final': (0, 1000, {}, None, ALL, None),
    'ad27_pt1024': (27, 1024, {}, None, ALL, None),
    'ad16_pt1024_full_ad': (16, 1024, {}, None, ALL, None),
    'ad32_pt1024_full_ad': (32, 1024, {}, None, ALL, None),
    'ad27_pt1024_cocotb_gaps_stalls': (27, 1024, {'G_GAP_PERIOD': 5, 'G_GAP_LEN': 2, 'G_STALL_PERIOD': 53, 'G_STALL_LEN': 31}, None, ALL, None),
    'pt1024_source_1_per_2': (0, 1024, {'G_GAP_PERIOD': 2, 'G_GAP_LEN': 1}, None, ALL, None),
    'pt1024_source_1_per_4': (0, 1024, {'G_GAP_PERIOD': 4, 'G_GAP_LEN': 3}, None, ALL, None),
    'pt1024_source_1_per_6': (0, 1024, {'G_GAP_PERIOD': 6, 'G_GAP_LEN': 5}, None, ALL, None),
    'pt1024_source_1_per_8': (0, 1024, {'G_GAP_PERIOD': 8, 'G_GAP_LEN': 7}, None, ALL, None),
    'pt1024_sink_1_per_2': (0, 1024, {'G_STALL_PERIOD': 2, 'G_STALL_LEN': 1}, None, ALL, None),
    'pt1024_sink_1_per_4': (0, 1024, {'G_STALL_PERIOD': 4, 'G_STALL_LEN': 3}, None, ALL, None),
    'pt1024_sink_1_per_8': (0, 1024, {'G_STALL_PERIOD': 8, 'G_STALL_LEN': 7}, None, ALL, None),
    'pt1024_sink_burst_32_of_64': (0, 1024, {'G_STALL_PERIOD': 64, 'G_STALL_LEN': 32}, None, ALL, None),
    'pt64_bad_tag': (0, 64, {}, 'tag', ALL, None),
    # Added in the fold study.
    'ad15_pt17': (15, 17, {}, None, ALL, None),
    'ad17_pt1024': (17, 1024, {}, None, ALL, None),
    'ad15_pt1024_gaps_stalls': (15, 1024, {'G_GAP_PERIOD': 5, 'G_GAP_LEN': 2, 'G_STALL_PERIOD': 53, 'G_STALL_LEN': 31}, None, ALL, None),
    'ad0_pt33': (0, 33, {}, None, ALL, None),
    'pt64_bad_ct_first_bit': (0, 64, {}, 'ct0', ALL, None),
    'ad17_pt40_bad_ct_last_byte': (17, 40, {'G_STALL_PERIOD': 4, 'G_STALL_LEN': 1}, 'ctlast', ALL, None),
    'ad17_pt40_bad_tag_stalls': (17, 40, {'G_STALL_PERIOD': 4, 'G_STALL_LEN': 1}, 'tag', ALL, None),
    'pt1024_depth1_1': (0, 1024, {'G_IN_DEPTH': 1, 'G_OUT_DEPTH': 1}, None, ['u3-buffered', 'u3-fold'], None),
    'pt1024_depth1_1_gaps_stalls': (27, 1024, {'G_IN_DEPTH': 1, 'G_OUT_DEPTH': 1, 'G_GAP_PERIOD': 5, 'G_GAP_LEN': 2, 'G_STALL_PERIOD': 53, 'G_STALL_LEN': 31}, None, ['u3-buffered', 'u3-fold'], None),
    'pt1024_depth3_3_sink_burst': (0, 1024, {'G_IN_DEPTH': 3, 'G_OUT_DEPTH': 3, 'G_STALL_PERIOD': 64, 'G_STALL_LEN': 32}, None, ['u3-buffered', 'u3-fold'], None),
    'pt1024_depth1_1_sink_1_per_2': (0, 1024, {'G_IN_DEPTH': 1, 'G_OUT_DEPTH': 1, 'G_STALL_PERIOD': 2, 'G_STALL_LEN': 1}, None, ['u3-buffered', 'u3-fold'], None),
    # Framing probe: 16 AD bytes sent as a full NON-last beat followed by an empty last beat;
    # payload sent as a full non-last beat followed by an empty last beat. Standard Ascon
    # (SP 800-232) treats both as length-16 inputs. Recorded, not asserted (see notes).
    'framing_ad16_split_pt16_split': (16, 16, {}, None, ALL, 'split'),
    'framing_ad16_split_only': (16, 16, {}, None, ALL, 'split_ad'),
    'framing_pt16_split_only': (16, 16, {}, None, ALL, 'split_pt'),
}
ONLY = sys.argv[3].split(',') if len(sys.argv) > 3 else None


def beats(ad, pt, framing):
    def phase(kind, data):
        chunks = [data[i:i+16] for i in range(0, len(data), 16)] or [b'']
        split = framing == 'split' or (framing == 'split_ad' and kind == 0) or (framing == 'split_pt' and kind == 1)
        if split and data and len(data) % 16 == 0:
            return [(kind, 0xFFFF, 0, c) for c in chunks] + [(kind, 0, 1, b'')]
        return [(kind, (1 << len(c)) - 1, int(i == len(chunks) - 1), c) for i, c in enumerate(chunks)]
    return phase(0, ad) + phase(1, pt)


results = []
for si, (name, (adn, ptn, gen, tamper, cfgs, framing)) in enumerate(SCEN.items()):
    if ONLY and name not in ONLY:
        continue
    key = rng.randbytes(16); ad = rng.randbytes(adn); pt = rng.randbytes(ptn)
    nonce = (base + si).to_bytes(16, 'little')
    ct, tag = encrypt(key, nonce, ad, pt)
    txs = [(0, key, nonce, tag, ad, pt, True), (1, key, nonce, tag, ad, ct, True)]
    if tamper == 'tag':
        txs.append((1, key, nonce, bytes([tag[0] ^ 1]) + tag[1:], ad, ct, False))
    elif tamper == 'ct0':
        txs.append((1, key, nonce, tag, ad, bytes([ct[0] ^ 1]) + ct[1:], False))
    elif tamper == 'ctlast':
        txs.append((1, key, nonce, tag, ad, ct[:-1] + bytes([ct[-1] ^ 0x80]), False))
    lines = [str(len(txs))]
    for dec, k, n, tg, a, data, ok in txs:
        bs = beats(a, data, framing)
        lines.append(f'{dec} {ph(k)} {ph(n)} {ph(tg)} {len(bs)}')
        lines += [f'{kind} {keep:04X} {last} {ph(c)}' for kind, keep, last, c in bs]
    for cfg in cfgs:
        rpc, buf, fold = CONFIGS[cfg]
        d = root / name / cfg
        d.mkdir(parents=True, exist_ok=True)
        (d / 'traffic_in.txt').write_text('\n'.join(lines) + '\n')
        work = d / 'work'; work.mkdir(exist_ok=True)
        files = [W / 'rtl/ascon_pkg.vhd', W / 'rtl/ascon_permutation.vhd', W / 'rtl/ascon_aead128_core.vhd', W / 'scripts/tb_fold_traffic.vhd']
        subprocess.run(['ghdl', '-a', '--std=08', f'--workdir={work}', *map(str, files)], cwd=d, check=True)
        cmd = ['ghdl', '--elab-run', '--std=08', f'--workdir={work}', 'tb_fold_traffic', f'-gG_RUN_DIR={d}',
               f'-gG_ROUNDS_PER_CYCLE={rpc}', f'-gG_BUFFERING_ENABLE={str(buf).lower()}',
               f'-gG_FOLDED_ABSORB={str(fold).lower()}'] + [f'-g{k}={v}' for k, v in gen.items()] + ['--assert-level=error']
        with (d / 'ghdl.log').open('w') as log:
            subprocess.run(cmd, cwd=d, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=600)
        out = (d / 'traffic_out.txt').read_text().splitlines()
        assert out[-1] == 'END'
        chunks, cur = [], []
        for ln in out[:-1]:
            cur.append(ln)
            if ln.startswith('TX '):
                chunks.append(cur); cur = []
        assert len(chunks) == len(txs)
        for (dec, k, n, tg, a, data, ok), ch in zip(txs, chunks):
            got = b''; outt = []
            for ln in ch:
                if ln.startswith('OUT '):
                    _, keep, last, hexd, t = ln.split()
                    got += bytes.fromhex(hexd)[::-1][:bin(int(keep, 16)).count('1')]
                    outt.append(int(t))
            ev = {w: [int(ln.split()[1]) for ln in ch if ln.startswith(w + ' ')] for w in ('TAGIN', 'COMMIT', 'DISCARD', 'ERROR')}
            tx = {kk: int(vv) for kk, vv in re.findall(r'(\w+)=(-?\d+)', ch[-1])}
            if dec == 0:
                tline = [ln for ln in ch if ln.startswith('TAGOUT')][0]
                got_tag = bytes.fromhex(tline.split()[1])[::-1]
                correct = got == ct and got_tag == tag and tx['error'] == 0
                tagout_t = int(tline.split()[2])
            else:
                exp_pt = decrypt(k, n, a, data, tg)[0]
                if ok:
                    correct = got == pt and tx['auth'] == 1 and tx['auth_ok'] == 1 and tx['commit'] == 1 and tx['discard'] == 0
                else:
                    correct = got == exp_pt and tx['auth'] == 1 and tx['auth_ok'] == 0 and tx['commit'] == 0 and tx['discard'] == 1
                tagout_t = None
            if framing is None:
                assert correct, f'{name} {cfg} dec={dec} ok={ok} FAILED'
            ivals = [b - a_ for a_, b in zip(outt, outt[1:])]
            row = dict(scenario=name, config=cfg, ad_bytes=adn, pt_bytes=ptn, generics=gen, framing=framing,
                       direction='DECRYPT' if dec else 'ENCRYPT', tag_ok_expected=ok,
                       checked='PASS' if correct else 'MISMATCH_VS_SP800_232',
                       steady_interval_median=statistics.median(ivals) if ivals else None,
                       interval_hist={str(v): ivals.count(v) for v in sorted(set(ivals))},
                       tagout_t=tagout_t, tagin_t=ev['TAGIN'][0] if ev['TAGIN'] else None,
                       commit_t=ev['COMMIT'][0] if ev['COMMIT'] else None,
                       discard_t=ev['DISCARD'][0] if ev['DISCARD'] else None,
                       error_t=ev['ERROR'][0] if ev['ERROR'] else None, **tx)
            results.append(row)
            print(json.dumps({k_: row[k_] for k_ in ('scenario', 'config', 'direction', 'checked', 'cycles', 'first_out', 'last_out', 'in_stall', 'out_stall', 'steady_interval_median')}), flush=True)
(root / 'results.json').write_text(json.dumps(results, indent=1) + '\n')
