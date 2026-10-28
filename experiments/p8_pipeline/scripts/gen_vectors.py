#!/usr/bin/env python3
"""Generate fixed-seed reference vectors for the p8 pipelining benches.

Both files come from verification/model/ascon_ref.py, which is independent of
the VHDL.  Nothing here knows how many clocks a round takes; the benches use
the expected values only at completed-round and transaction boundaries.

perm_vectors.txt   one permutation per line:
                   ROUNDS RESET_AT INPUT_STATE STATE_AFTER_ROUND_1 ... _N
                   RESET_AT is 0 for none, or the busy clock at which the
                   bench pulses reset before re-running the same vector.

core_vectors.txt   one token-led record per line:
                   C DECRYPT KEY NONCE EXPECT_AUTH RESET_AT LABEL
                   A DATA KEEP LAST                      associated data beat
                   M DATA KEEP LAST EXPECTED_OUT          payload beat
                   T TAG                                   expected / supplied tag
                   E                                       end of transaction
"""

import argparse
import random
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "verification" / "model"))
import ascon_ref  # noqa: E402

SEED = 0x5A8E_2026
MASK64 = (1 << 64) - 1


def state_hex(words):
    # state_t(319 downto 0) holds word i in bits 64*i+63 downto 64*i.
    return "".join(f"{w:016X}" for w in reversed(words))


def port_hex(data: bytes) -> str:
    return data.ljust(16, b"\x00")[::-1].hex().upper()


def keep_hex(n: int) -> str:
    return f"{(1 << n) - 1:04X}"


def beats(data: bytes):
    """Split a stream into 16-byte beats; an empty stream is one empty beat."""
    if not data:
        return [(b"", 0, 1)]
    out = []
    for off in range(0, len(data), 16):
        chunk = data[off : off + 16]
        out.append((chunk, len(chunk), 1 if off + 16 >= len(data) else 0))
    return out


def perm_vectors(rng: random.Random, count: int):
    lines = []
    specials = [[0] * 5, [MASK64] * 5]
    for i in range(count):
        rounds = 8 if i % 2 == 0 else 12
        words = specials[i] if i < len(specials) else [rng.getrandbits(64) for _ in range(5)]
        trace = ascon_ref.permutation_trace(words, rounds)
        # Every fifth vector is interrupted by reset at a varying busy clock,
        # which lands on both round phases of a multi-stage engine.
        reset_at = (i % 23) + 1 if i % 5 == 4 else 0
        lines.append(" ".join([str(rounds), str(reset_at), state_hex(words)] + [state_hex(s) for s in trace]))
    return lines


def transaction(key, nonce, ad, pt, decrypt, corrupt_tag, reset_at, label):
    ct, tag = ascon_ref.encrypt(key, nonce, ad, pt)
    lines = []
    expect_auth = 0 if corrupt_tag else 1
    lines.append(f"C {int(decrypt)} {port_hex(key)} {port_hex(nonce)} {expect_auth} {reset_at} {label}")
    for chunk, n, last in beats(ad):
        lines.append(f"A {port_hex(chunk)} {keep_hex(n)} {last}")
    src, dst = (ct, pt) if decrypt else (pt, ct)
    for (chunk, n, last), (out_chunk, _, _) in zip(beats(src), beats(dst)):
        lines.append(f"M {port_hex(chunk)} {keep_hex(n)} {last} {port_hex(out_chunk)}")
    if decrypt:
        recovered, ok = ascon_ref.decrypt(key, nonce, ad, ct, tag)
        assert ok and recovered == pt
        supplied = bytearray(tag)
        if corrupt_tag:
            supplied[rng_flip(label) % 16] ^= 1 << (rng_flip(label) % 8)
        lines.append(f"T {port_hex(bytes(supplied))}")
    else:
        lines.append(f"T {port_hex(tag)}")
    lines.append("E")
    return lines


def rng_flip(label: str) -> int:
    return sum(label.encode()) * 2654435761 % 4093


def core_vectors(rng: random.Random):
    lines = []
    key = bytes(range(16))
    nonce = bytes(range(16, 32))
    # Fixed benchmark workloads: AD length 0 and 16, payloads used for the
    # latency tables.  These come first so their cycle counts are easy to find.
    for ad_len in (0, 16):
        for msg_len in (0, 16, 32, 1024, 4096):
            ad = bytes((i * 7) & 0xFF for i in range(ad_len))
            pt = bytes((i * 13 + 5) & 0xFF for i in range(msg_len))
            for dec in (0, 1):
                lines += transaction(key, nonce, ad, pt, dec, False, 0,
                                     f"bench_ad{ad_len}_msg{msg_len}_{'dec' if dec else 'enc'}")
    # Edge lengths around the rate boundary for both streams.
    for ad_len in (0, 1, 8, 15, 16, 17, 31, 32, 33, 48):
        for msg_len in (0, 1, 8, 15, 16, 17, 31, 32, 33, 48):
            k = rng.randbytes(16)
            n = rng.randbytes(16)
            ad = rng.randbytes(ad_len)
            pt = rng.randbytes(msg_len)
            for dec in (0, 1):
                lines += transaction(k, n, ad, pt, dec, False, 0, f"edge_ad{ad_len}_msg{msg_len}_{dec}")
    # Randomized differential messages, authentication rejection, and reset
    # injection at many points of a transaction.
    for i in range(300):
        k = rng.randbytes(16)
        n = rng.randbytes(16)
        ad = rng.randbytes(rng.choice([0, rng.randrange(1, 80)]))
        pt = rng.randbytes(rng.choice([0, rng.randrange(1, 200)]))
        dec = rng.randrange(2)
        corrupt = dec == 1 and i % 4 == 1
        reset_at = rng.randrange(1, 90) if i % 6 == 3 else 0
        lines += transaction(k, n, ad, pt, dec, corrupt, reset_at, f"rand{i}")
    return lines


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    rng = random.Random(SEED)
    (args.out / "perm_vectors.txt").write_text("\n".join(perm_vectors(rng, 400)) + "\n")
    (args.out / "core_vectors.txt").write_text("\n".join(core_vectors(rng)) + "\n")
    print(f"seed={SEED:#x} wrote {args.out}")


if __name__ == "__main__":
    main()
