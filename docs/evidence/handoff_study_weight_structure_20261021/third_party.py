"""Third-party float/byte-grouping codecs on the adapter payload (read-only, round-trip + SHA-256 verified)."""
import hashlib, json, sys, time, types
import numpy as np

EXPECT = 'c184175fc18d24373f009875c03698e630e8c36a5341146aab2bd13a98fff8eb'
path, man_path, out_path, which = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
payload = open(path, 'rb').read(); N = len(payload)
assert hashlib.sha256(payload).hexdigest() == EXPECT
man = json.load(open(man_path))
tens = {t['name']: (payload[t['payload_byte_offset']:t['payload_byte_offset'] + t['bytes']], t['shape']) for t in man['tensor_manifest']}
sha = lambda b: hashlib.sha256(b).hexdigest()
res = {}


def record(name, pieces_fn):
    try:
        total = 0; rec = []; tc = td = 0.0
        for p in pieces_fn():
            t0 = time.perf_counter(); c = p[0](); tc += time.perf_counter() - t0
            t0 = time.perf_counter(); d = p[1](c); td += time.perf_counter() - t0
            total += len(c); rec.append(d)
        h = sha(b''.join(rec)); assert h == EXPECT, 'round trip mismatch'
        res[name] = dict(bytes=total, ratio=total / N, saving_pct=100 * (1 - total / N), roundtrip_sha256=h,
                         sw_comp_MBps=N / tc / 1e6, sw_decomp_MBps=N / td / 1e6)
    except Exception as e:
        res[name] = dict(error=repr(e)[:400])
    print(name, res[name], flush=True)


if which == 'zipnn':
    class Any:
        def __getattr__(self, k):
            if k.startswith('__'): raise AttributeError(k)
            return Any()
        def __call__(self, *a, **k):
            if len(a) == 1 and callable(a[0]) and not k: return a[0]
            return Any()
    class Stub(types.ModuleType):
        def __getattr__(self, k):
            if k.startswith('__'): raise AttributeError(k)
            return Any()
    for m in ('torch', 'safetensors', 'safetensors.torch', 'torch.nn', 'torch.nn.modules', 'torch.serialization'):
        sys.modules[m] = Stub(m)
    import zipnn
    ver = 'unknown'
    try:
        from importlib.metadata import version; ver = version('zipnn')
    except Exception: pass
    res['zipnn_version'] = ver
    for th in (0,):
        for lvl in (3, 19):
            def mk(b, lvl=lvl):
                if ver.startswith('0.1'):
                    z = zipnn.ZipNN(method='zstd', input_type='byte', bg_partitions=4, zstd_level=lvl, zstd_threads=1)
                else:
                    z = zipnn.ZipNN(input_format='byte', bytearray_dtype='float32', zstd_level=lvl, threads=1)
                return (lambda: z.compress(b), lambda c: bytes(z.decompress(c)))
            record(f'zipnn_float32_zstd{lvl}_whole', lambda mk=mk: [mk(payload)])
            record(f'zipnn_float32_zstd{lvl}_per_tensor', lambda mk=mk: [mk(v[0]) for v in tens.values()])
    def mk_auto(b):
        z = zipnn.ZipNN(input_format='byte', bytearray_dtype='float32', method='HUFFMAN', threads=1)
        return (lambda: z.compress(b), lambda c: bytes(z.decompress(c)))
    record('zipnn_float32_HUFFMAN_whole', lambda: [mk_auto(payload)])
elif which == 'fpzip':
    import fpzip
    def mk(b, shape):
        a = np.frombuffer(b, '<f4').reshape(shape).copy()
        return (lambda: fpzip.compress(a, precision=0, order='C'),
                lambda c: fpzip.decompress(c, order='C').astype('<f4').reshape(-1).tobytes())
    record('fpzip_lossless_whole_1d', lambda: [mk(payload, (N // 4,))])
    record('fpzip_lossless_per_tensor_shaped', lambda: [mk(b, s) for b, s in tens.values()])
elif which == 'blosc2':
    import blosc2
    res['blosc2_version'] = blosc2.__version__
    for codec in ('ZSTD', 'LZ4', 'LZ4HC', 'ZLIB'):
        for filt in ('SHUFFLE', 'BITSHUFFLE', 'NOFILTER'):
            for clevel in ((5, 9) if codec in ('ZSTD', 'LZ4HC') else (5,)):
                def mk(b, codec=codec, filt=filt, clevel=clevel):
                    cp = dict(codec=getattr(blosc2.Codec, codec), clevel=clevel, filters=[getattr(blosc2.Filter, filt)], typesize=4, nthreads=1)
                    return (lambda: blosc2.compress2(b, **cp), lambda c: bytes(blosc2.decompress2(c)))
                record(f'blosc2_{codec}{clevel}_{filt}_whole', lambda mk=mk: [mk(payload)])
json.dump(res, open(out_path, 'w'), indent=1)
assert hashlib.sha256(open(path, 'rb').read()).hexdigest() == EXPECT
