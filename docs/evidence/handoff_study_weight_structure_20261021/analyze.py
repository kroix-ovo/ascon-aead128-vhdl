"""Read-only structure/statistics/lossless-compression study of the SAGE FP32 adapter payload.

Never writes to the artifact. All outputs go to the --out directory (must not exist).
Every codec result is round-tripped and the reconstructed whole payload is SHA-256 checked.
"""
import argparse, bz2, gzip, hashlib, heapq, json, lzma, math, os, struct, sys, time
from collections import Counter
from pathlib import Path
import numpy as np
import zstandard, lz4.frame
try:
    import brotli
except Exception:
    brotli = None

EXPECT_PAYLOAD = 'c184175fc18d24373f009875c03698e630e8c36a5341146aab2bd13a98fff8eb'
EXPECT_CKPT = '7c45c25b28ae54943c1fd4ee160001dcd9a68ee1f8430aee229f933545672de6'
FREQ_HZ = 100e6
# Cycle model derived from repository evidence (buffered 3-round core, see notes):
#   cycles(msg) = 6*F + 17 + 2*[payload ends in partial/empty-only final beat] + 6*P_ad
# F = full 16-byte payload blocks, P_ad = AD p8 permutations (= ceil((ad+1)/16) when ad>0, else 0).
BLK_CLK, FIXED_CLK, PARTIAL_CLK, AD_BLK_CLK = 6, 17, 2, 6
MEASURED_FULL = 899153


def sha(b): return hashlib.sha256(b).hexdigest()


def msg_cycles(n, ad=0):
    full, rem = divmod(n, 16)
    ad_perms = 0 if ad == 0 else ad // 16 + 1  # Ascon pads AD: a 16-byte AD needs 2 absorbs
    partial = 1 if (rem or n == 0) else 0
    return BLK_CLK*full + FIXED_CLK + PARTIAL_CLK*partial + AD_BLK_CLK*ad_perms


def entropy(counts):
    c = np.asarray([v for v in counts if v], dtype=np.float64)
    p = c / c.sum()
    return float(-(p*np.log2(p)).sum())


def huffman_lengths(counts):
    items = [(c, i, None) for i, c in counts.items() if c]
    if len(items) == 1:
        return {items[0][1]: 1}
    heap = [(c, n, [s]) for n, (c, s, _) in enumerate(items)]
    heapq.heapify(heap)
    lengths = Counter()
    n = len(heap)
    while len(heap) > 1:
        c1, _, s1 = heapq.heappop(heap); c2, _, s2 = heapq.heappop(heap)
        for s in s1 + s2: lengths[s] += 1
        n += 1
        heapq.heappush(heap, (c1+c2, n, s1+s2))
    return dict(lengths)


def canonical(lengths):
    code, prev, out = 0, 0, {}
    for s, l in sorted(lengths.items(), key=lambda kv: (kv[1], kv[0])):
        code <<= (l - prev); out[s] = (code, l); code += 1; prev = l
    return out


def huff_encode(sym):
    counts = Counter(sym.tolist())
    lens = huffman_lengths(counts)
    codes = canonical(lens)
    acc = 0; nb = 0; out = bytearray()
    for s in sym.tolist():
        c, l = codes[s]
        acc = (acc << l) | c; nb += l
        while nb >= 8:
            nb -= 8; out.append((acc >> nb) & 0xFF)
        acc &= (1 << nb) - 1
    if nb: out.append((acc << (8-nb)) & 0xFF)
    table = bytes(x for s, l in sorted(lens.items()) for x in (s, l))
    header = struct.pack('<IH', len(sym), len(lens)) + table
    return header + bytes(out), max(lens.values())


def huff_decode(blob):
    n, ns = struct.unpack('<IH', blob[:6])
    lens = {blob[6+2*i]: blob[7+2*i] for i in range(ns)}
    codes = canonical(lens)
    lookup = {(l, c): s for s, (c, l) in codes.items()}
    data = blob[6+2*ns:]
    out = bytearray(); acc = 0; l = 0
    bitl = np.unpackbits(np.frombuffer(data, np.uint8)).tolist(); pos = 0
    while len(out) < n:
        acc = (acc << 1) | bitl[pos]; pos += 1; l += 1
        s = lookup.get((l, acc))
        if s is not None:
            out.append(s); acc = 0; l = 0
    return bytes(out)


class BW:
    def __init__(self): self.acc = 0; self.nb = 0; self.out = bytearray()
    def w(self, v, n):
        self.acc = (self.acc << n) | v; self.nb += n
        while self.nb >= 8:
            self.nb -= 8; self.out.append((self.acc >> self.nb) & 0xFF)
        self.acc &= (1 << self.nb) - 1
    def done(self):
        if self.nb: self.out.append((self.acc << (8-self.nb)) & 0xFF)
        return bytes(self.out)


def gorilla_encode(u32):
    vals = u32.tolist(); bw = BW(); bw.w(len(vals), 32)
    if not vals: return bw.done()
    prev = vals[0]; bw.w(prev, 32); plz, ptz = 33, 33
    for v in vals[1:]:
        x = v ^ prev; prev = v
        if x == 0: bw.w(0, 1); continue
        lz = 32 - x.bit_length(); tz = (x & -x).bit_length() - 1
        if lz > 31: lz = 31
        if plz <= 32 and lz >= plz and tz >= ptz:
            bw.w(0b10, 2); m = 32 - plz - ptz; bw.w(x >> ptz, m)
        else:
            m = 32 - lz - tz
            bw.w(0b11, 2); bw.w(lz, 5); bw.w(m-1, 5); bw.w(x >> tz, m); plz, ptz = lz, tz
    return bw.done()


def gorilla_decode(blob):
    data = bytes(blob) + bytes(16); pos = 0
    def r(n):
        nonlocal pos
        q, o = divmod(pos, 8); pos += n
        w = int.from_bytes(data[q:q+9], 'big')
        return (w >> (72 - o - n)) & ((1 << n) - 1)
    n = r(32); out = []
    if n == 0: return np.zeros(0, '<u4')
    prev = r(32); out.append(prev); plz = ptz = None
    for _ in range(n-1):
        if r(1) == 0: out.append(prev); continue
        if r(1) == 0:
            m = 32 - plz - ptz; x = r(m) << ptz
        else:
            lz = r(5); m = r(5)+1; tz = 32 - lz - m; x = r(m) << tz; plz, ptz = lz, tz
        prev ^= x; out.append(prev)
    return np.array(out, dtype='<u4')


# ---- reversible transforms on raw little-endian FP32 bytes ----
def t_raw(b): return b
def i_raw(b): return b
def t_byteshuf(b): return np.frombuffer(b, np.uint8).reshape(-1, 4).T.copy().tobytes()
def i_byteshuf(b): return np.frombuffer(b, np.uint8).reshape(4, -1).T.copy().tobytes()
def t_bitshuf(b):
    a = np.frombuffer(b, '<u4').astype('>u4').view(np.uint8).reshape(-1, 4)
    bits = np.unpackbits(a, axis=1)            # (N,32), MSB(sign) first
    return np.packbits(bits.T.copy(), axis=1).tobytes()  # N must be multiple of 8
def i_bitshuf(b, n):
    planes = np.unpackbits(np.frombuffer(b, np.uint8).reshape(32, -1), axis=1)[:, :n]
    return np.packbits(planes.T.copy(), axis=1).view('>u4').astype('<u4').tobytes()
def t_xorprev_bs(b):
    u = np.frombuffer(b, '<u4'); x = u.copy(); x[1:] ^= u[:-1]
    return t_byteshuf(x.tobytes())
def i_xorprev_bs(b):
    x = np.frombuffer(i_byteshuf(b), '<u4'); return np.bitwise_xor.accumulate(x).astype('<u4').tobytes()
def ee_split(b):
    """ZipNN-style exponent extraction: stream0 = 8-bit exponent; streams1..3 = sign|mant[22:16], mant[15:8], mant[7:0]."""
    u = np.frombuffer(b, '<u4')
    e = ((u >> 23) & 0xFF).astype(np.uint8)
    s0 = (((u >> 31) << 7) | ((u >> 16) & 0x7F)).astype(np.uint8)
    return [e.tobytes(), s0.tobytes(), ((u >> 8) & 0xFF).astype(np.uint8).tobytes(), (u & 0xFF).astype(np.uint8).tobytes()]
def ee_join(streams):
    e, s0, m1, m0 = (np.frombuffer(s, np.uint8).astype(np.uint32) for s in streams)
    u = ((s0 >> 7) << 31) | (e << 23) | ((s0 & 0x7F) << 16) | (m1 << 8) | m0
    return u.astype('<u4').tobytes()


CODECS = {
    'zstd-1': (lambda d: zstandard.ZstdCompressor(level=1).compress(d), lambda d: zstandard.ZstdDecompressor().decompress(d)),
    'zstd-3': (lambda d: zstandard.ZstdCompressor(level=3).compress(d), lambda d: zstandard.ZstdDecompressor().decompress(d)),
    'zstd-19': (lambda d: zstandard.ZstdCompressor(level=19).compress(d), lambda d: zstandard.ZstdDecompressor().decompress(d)),
    'zstd-22': (lambda d: zstandard.ZstdCompressor(level=22).compress(d), lambda d: zstandard.ZstdDecompressor().decompress(d)),
    'lz4': (lambda d: lz4.frame.compress(d), lz4.frame.decompress),
    'lz4hc-12': (lambda d: lz4.frame.compress(d, compression_level=12), lz4.frame.decompress),
    'gzip-6': (lambda d: gzip.compress(d, 6, mtime=0), gzip.decompress),
    'gzip-9': (lambda d: gzip.compress(d, 9, mtime=0), gzip.decompress),
    'xz-6': (lambda d: lzma.compress(d, preset=6), lzma.decompress),
    'xz-9e': (lambda d: lzma.compress(d, preset=9 | lzma.PRESET_EXTREME), lzma.decompress),
    'bz2-9': (lambda d: bz2.compress(d, 9), bz2.decompress),
}
if brotli:
    CODECS['brotli-11'] = (lambda d: brotli.compress(d, quality=11), brotli.decompress)


def run_codec(name, transform, pieces):
    """pieces: list of raw byte strings (one per independent compression unit). Returns size and verified sha."""
    comp, dec = CODECS[name]
    total = 0; rec = []; tc = td = 0.0
    for p in pieces:
        n = len(p)//4
        if transform == 'ee_split':
            streams = ee_split(p); t0 = time.perf_counter(); cs = [comp(s) for s in streams]; tc += time.perf_counter()-t0
            total += sum(len(c) for c in cs) + 4*4  # 4 stream-length fields
            t0 = time.perf_counter(); r = ee_join([dec(c) for c in cs]); td += time.perf_counter()-t0
        else:
            f, inv = dict(raw=(t_raw, i_raw), byteshuffle=(t_byteshuf, i_byteshuf), xorprev_byteshuffle=(t_xorprev_bs, i_xorprev_bs),
                          bitshuffle=(t_bitshuf, lambda b: i_bitshuf(b, n)))[transform]
            t = f(p); t0 = time.perf_counter(); c = comp(t); tc += time.perf_counter()-t0
            total += len(c)
            t0 = time.perf_counter(); r = inv(dec(c)); td += time.perf_counter()-t0
        assert r == p, (name, transform)
        rec.append(r)
    return total, sha(b''.join(rec)), tc, td


def main():
    ap = argparse.ArgumentParser(); ap.add_argument('payload'); ap.add_argument('manifest'); ap.add_argument('checkpoint')
    ap.add_argument('--initial'); ap.add_argument('--out', required=True); ap.add_argument('--quick', action='store_true')
    a = ap.parse_args()
    out = Path(a.out); out.mkdir(parents=True, exist_ok=False)
    payload = open(a.payload, 'rb').read(); ckpt = open(a.checkpoint, 'rb').read()
    man = json.load(open(a.manifest))
    assert sha(payload) == EXPECT_PAYLOAD and sha(ckpt) == EXPECT_CKPT and ckpt[20:] == payload
    hdr = struct.unpack('<5i', ckpt[:20])
    res = dict(payload_sha256=sha(payload), checkpoint_sha256=sha(ckpt), header=hdr, bytes=len(payload))
    L, C, r = man['layers'], man['channels'], man['rank']
    tens = {}
    for t in man['tensor_manifest']:
        tens[t['name']] = payload[t['payload_byte_offset']:t['payload_byte_offset']+t['bytes']]
    assert b''.join(tens.values()) == payload

    # ---------------- 1. structure / AEAD message plans ----------------
    per_layer = {k: len(v)//L for k, v in tens.items()}
    struct_info = dict(tensors={k: dict(bytes=len(v), mod16=len(v) % 16, blocks16=len(v)/16, per_layer_bytes=per_layer[k],
                                          per_layer_mod16=per_layer[k] % 16) for k, v in tens.items()},
                       total_mod16=len(payload) % 16, total_blocks16=len(payload)/16,
                       layer_bundle_bytes=sum(per_layer.values()))
    plans = {}
    def plan(name, sizes, ad=0, nonce_stored=False):
        cyc = sum(msg_cycles(s, ad) for s in sizes)
        partial = sum(1 for s in sizes if s % 16)
        tags = 16*len(sizes); nonces = 16*len(sizes) if nonce_stored else 0
        plans[name] = dict(messages=len(sizes), partial_final_blocks=partial, ad_bytes_per_msg=ad,
                           payload_blocks=sum(-(-s//16) for s in sizes), cycles=cyc,
                           fixed_overhead_cycles=cyc - BLK_CLK*sum(s//16 for s in sizes),
                           overhead_vs_single_pct=None, us_at_100MHz=cyc/FREQ_HZ*1e6,
                           payload_MBps=len(payload)/(cyc/FREQ_HZ)/1e6, tag_bytes=tags,
                           tag_overhead_pct=100*tags/len(payload), nonce_bytes_if_stored=16*len(sizes),
                           min_size=min(sizes), max_size=max(sizes))
    N = len(payload)
    plan('single_message', [N])
    plan('per_tensor_4', [len(v) for v in tens.values()])
    plan('per_layer_per_tensor_48', [per_layer[k] for k in tens for _ in range(L)])
    plan('per_layer_bundle_12', [sum(per_layer.values())]*L)
    for cs in (512, 1024, 4096, 16384, 65536, 262144, 1 << 20):
        sizes = [cs]*(N//cs) + ([N % cs] if N % cs else [])
        plan(f'chunk_{cs}', sizes)
        plan(f'chunk_{cs}_ad8', sizes, ad=8)
        plan(f'chunk_{cs}_ad16', sizes, ad=16)
    for k in plans: plans[k]['overhead_vs_single_pct'] = 100*(plans[k]['cycles']/plans['single_message']['cycles']-1)
    res['structure'] = struct_info; res['aead_plans'] = plans
    res['cycle_model'] = dict(formula='6*F + 17 + 2*[partial-or-empty final beat] + 6*AD_perms', single_message_model=msg_cycles(N),
                              single_message_measured=MEASURED_FULL)

    # ---------------- 2. statistics ----------------
    stats = {}
    for name, b in list(tens.items()) + [('ALL', payload)]:
        u = np.frombuffer(b, '<u4'); f = np.frombuffer(b, '<f4')
        bp = np.frombuffer(b, np.uint8).reshape(-1, 4)
        exp = (u >> 23) & 0xFF; sign = u >> 31; mant = u & 0x7FFFFF
        uniq, cnt = np.unique(u, return_counts=True)
        top = np.argsort(cnt)[::-1][:5]
        bitp = [float(((u >> k) & 1).mean()) for k in range(32)]
        bitH = [0.0 if p in (0, 1) else float(-(p*math.log2(p)+(1-p)*math.log2(1-p))) for p in bitp]
        ec = Counter(exp.tolist())
        stats[name] = dict(
            n=int(u.size), min=float(f.min()), max=float(f.max()), mean=float(f.mean()), std=float(f.std()),
            absmax=float(np.abs(f).max()), median_abs=float(np.median(np.abs(f))),
            pos_zero=int((u == 0).sum()), neg_zero=int((u == 0x80000000).sum()), subnormal=int(((exp == 0) & (mant != 0)).sum()),
            nonfinite=int((~np.isfinite(f)).sum()), negative=int(sign.sum()),
            unique_values=int(uniq.size), unique_frac=float(uniq.size/u.size),
            values_in_repeated_groups=int(cnt[cnt > 1].sum()), top_repeats=[[float(np.frombuffer(np.uint32(uniq[i]).tobytes(), '<f4')[0]), int(cnt[i])] for i in top],
            byte_plane_entropy_bits=[entropy(np.bincount(bp[:, k], minlength=256)) for k in range(4)],
            sign_entropy=entropy(np.bincount(sign, minlength=2)), exponent_entropy=entropy(list(ec.values())),
            exponent_distinct=len(ec), exponent_range=[int(exp.min()), int(exp.max())],
            exponent_top=sorted(((int(k), int(v)) for k, v in ec.items()), key=lambda kv: -kv[1])[:8],
            mantissa_hi7_entropy=entropy(np.bincount((mant >> 16), minlength=128)),
            mantissa_mid8_entropy=entropy(np.bincount((mant >> 8) & 0xFF, minlength=256)),
            mantissa_lo8_entropy=entropy(np.bincount(mant & 0xFF, minlength=256)),
            trailing_zero_mantissa_bits_mean=float(np.where(mant == 0, 23, np.log2((mant & -mant.astype(np.int64)).clip(1)).astype(np.int64)).mean()),
            bit_plane_p1_lsb0=bitp, bit_plane_entropy_lsb0=bitH,
        )
        stats[name]['order0_bound_bytes_byteplanes'] = float(sum(stats[name]['byte_plane_entropy_bits'])*u.size/8)
        stats[name]['order0_bound_bytes_fields'] = float((stats[name]['sign_entropy']+stats[name]['exponent_entropy']+stats[name]['mantissa_hi7_entropy']
                                                         + stats[name]['mantissa_mid8_entropy']+stats[name]['mantissa_lo8_entropy'])*u.size/8)
    res['stats'] = stats
    if a.initial:
        ini = open(a.initial, 'rb').read()
        res['initial_sha256'] = sha(ini)
        if len(ini) == len(ckpt):
            iu = np.frombuffer(ini[20:], '<u4'); pu = np.frombuffer(payload, '<u4')
            res['vs_initial'] = dict(identical_values=int((iu == pu).sum()), per_tensor={})
            for t in man['tensor_manifest']:
                s, e = t['payload_byte_offset']//4, (t['payload_byte_offset']+t['bytes'])//4
                res['vs_initial']['per_tensor'][t['name']] = int((iu[s:e] == pu[s:e]).sum())
            x = (iu ^ pu).astype('<u4').tobytes()
            c = zstandard.ZstdCompressor(level=19).compress(t_byteshuf(x))
            r2 = (np.frombuffer(i_byteshuf(zstandard.ZstdDecompressor().decompress(c)), '<u4') ^ iu).astype('<u4').tobytes()
            assert r2 == payload
            res['vs_initial']['xor_initial_byteshuffle_zstd19_bytes'] = len(c)
            res['vs_initial']['note'] = 'requires initial checkpoint at the decoder; reference only'

    # ---------------- 3. compression ----------------
    scopes = dict(whole=[payload], per_tensor=list(tens.values()),
                  per_layer_tensor=[v[i*per_layer[k]:(i+1)*per_layer[k]] for k, v in tens.items() for i in range(L)])
    transforms = ['raw', 'byteshuffle', 'bitshuffle', 'xorprev_byteshuffle', 'ee_split']
    comp = []
    codecs = list(CODECS) if not a.quick else ['zstd-3', 'lz4']
    for scope, pieces in scopes.items():
        for codec in codecs:
            if scope == 'per_layer_tensor' and codec in ('xz-9e', 'zstd-22', 'brotli-11'): continue
            for tr in transforms:
                size, h, tc, td = run_codec(codec, tr, pieces)
                assert h == EXPECT_PAYLOAD
                comp.append(dict(scope=scope, units=len(pieces), codec=codec, transform=tr, bytes=size, ratio=size/N,
                                 saving_pct=100*(1-size/N), roundtrip_sha256=h, sw_comp_MBps=N/tc/1e6, sw_decomp_MBps=N/td/1e6))
                print(scope, codec, tr, size, f'{size/N:.4f}', flush=True)
    # Exponent Huffman (hardware-friendly: 8-bit symbol Huffman + raw 3 mantissa bytes); per tensor & whole
    huff = {}
    for scope, pieces in (('whole', [payload]), ('per_tensor', list(tens.values()))):
        total = 0; maxlen = 0; rec = []
        for p in pieces:
            st = ee_split(p); blob, ml = huff_encode(np.frombuffer(st[0], np.uint8)); maxlen = max(maxlen, ml)
            total += len(blob) + 3*len(p)//4 + 8
            assert huff_decode(blob) == st[0]
            rec.append(ee_join([huff_decode(blob)] + st[1:]))
        h = sha(b''.join(rec)); assert h == EXPECT_PAYLOAD
        huff[scope] = dict(bytes=total, ratio=total/N, saving_pct=100*(1-total/N), max_code_len=maxlen, roundtrip_sha256=h)
    res['exponent_huffman_raw_mantissa'] = huff
    # Gorilla XOR codec (float32 variant), whole + per-tensor, verified
    gor = {}
    for scope, pieces in (('whole', [payload]), ('per_tensor', list(tens.values()))):
        total = 0; rec = []
        for p in pieces:
            g = gorilla_encode(np.frombuffer(p, '<u4')); total += len(g); rec.append(gorilla_decode(g).tobytes())
        h = sha(b''.join(rec)); assert h == EXPECT_PAYLOAD
        gor[scope] = dict(bytes=total, ratio=total/N, saving_pct=100*(1-total/N), roundtrip_sha256=h)
    res['gorilla_xor'] = gor
    # chunked random-access compression (independent frames)
    chunked = []
    for cs in (4096, 65536, 1 << 20):
        for codec, tr in (('zstd-3', 'byteshuffle'), ('zstd-3', 'ee_split'), ('lz4', 'byteshuffle'), ('zstd-19', 'byteshuffle')):
            pieces = [payload[i:i+cs] for i in range(0, N, cs)]
            size, h, tc, td = run_codec(codec, tr, pieces)
            assert h == EXPECT_PAYLOAD
            chunked.append(dict(chunk=cs, chunks=len(pieces), codec=codec, transform=tr, bytes=size, ratio=size/N,
                                length_index_bytes=4*len(pieces), roundtrip_sha256=h))
    res['chunked_compression'] = chunked
    res['compression'] = comp

    # optional third-party float codecs
    extra = {}
    try:
        import zipnn
        for mode in ('float32',):
            z = zipnn.ZipNN(input_format='byte', bytearray_dtype=mode)
            t0 = time.perf_counter(); c = z.compress(payload); tc = time.perf_counter()-t0
            t0 = time.perf_counter(); d = bytes(z.decompress(c)); td = time.perf_counter()-t0
            assert sha(d) == EXPECT_PAYLOAD
            extra['zipnn_'+mode] = dict(version=getattr(zipnn, '__version__', '?'), bytes=len(c), ratio=len(c)/N, roundtrip_sha256=sha(d),
                                        sw_comp_MBps=N/tc/1e6, sw_decomp_MBps=N/td/1e6)
    except Exception as e:
        extra['zipnn_error'] = repr(e)[:300]
    try:
        import fpzip
        f = np.frombuffer(payload, '<f4').copy()
        c = fpzip.compress(f, precision=0, order='C'); d = fpzip.decompress(c, order='C').astype('<f4').reshape(-1).tobytes()
        assert sha(d) == EXPECT_PAYLOAD
        extra['fpzip_lossless'] = dict(bytes=len(c), ratio=len(c)/N, roundtrip_sha256=sha(d))
        tsz = 0; rec = []
        for t in man['tensor_manifest']:
            arr = np.frombuffer(tens[t['name']], '<f4').reshape(t['shape']).copy()
            c = fpzip.compress(arr, precision=0, order='C'); tsz += len(c)
            rec.append(fpzip.decompress(c, order='C').astype('<f4').reshape(-1).tobytes())
        assert sha(b''.join(rec)) == EXPECT_PAYLOAD
        extra['fpzip_lossless_per_tensor_shaped'] = dict(bytes=tsz, ratio=tsz/N, roundtrip_sha256=sha(b''.join(rec)))
    except Exception as e:
        extra['fpzip_error'] = repr(e)[:300]
    res['third_party'] = extra

    # ---------------- crypto-cycle translation ----------------
    best = min(comp, key=lambda d: d['bytes'])
    trans = []
    def add(label, cbytes, msgs=1, index_bytes=0):
        wire = cbytes + index_bytes
        per = [wire // msgs]*msgs; per[-1] += wire - sum(per)
        cyc = sum(msg_cycles(s) for s in per)
        trans.append(dict(label=label, compressed_plus_index_bytes=wire, messages=msgs, cycles=cyc, cycles_vs_measured_pct=100*(cyc/MEASURED_FULL-1),
                          effective_plaintext_MBps_if_decoder_keeps_up=N/(cyc/FREQ_HZ)/1e6, tag_bytes=16*msgs,
                          bytes_on_wire_incl_tags=wire+16*msgs, wire_saving_pct=100*(1-(wire+16*msgs)/(N+16))))
    add('uncompressed single message', N)
    for d in comp:
        if d['scope'] == 'whole' and d['transform'] in ('raw', 'byteshuffle', 'ee_split') and d['codec'] in ('zstd-3', 'zstd-19', 'lz4', 'xz-9e'):
            add(f"{d['codec']}+{d['transform']} whole", d['bytes'])
    add('exponent-Huffman + raw mantissa (whole)', huff['whole']['bytes'])
    add(f"best: {best['codec']}+{best['transform']} {best['scope']}", best['bytes'])
    for c in chunked:
        add(f"chunked {c['chunk']} {c['codec']}+{c['transform']} (per-chunk AEAD)", c['bytes'], c['chunks'], c['length_index_bytes'])
    res['crypto_translation'] = trans
    res['best_overall'] = best

    assert sha(open(a.payload, 'rb').read()) == EXPECT_PAYLOAD and sha(open(a.checkpoint, 'rb').read()) == EXPECT_CKPT
    res['post_run_hash_check'] = 'PASS'
    (out/'results.json').write_text(json.dumps(res, indent=1))
    print('DONE', out)


if __name__ == '__main__':
    main()
