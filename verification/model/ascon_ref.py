"""Small, readable NIST SP 800-232 Ascon-AEAD128 reference model.

This model is deliberately independent from the VHDL control logic.  It uses
ordinary Python byte strings, validates against the official KAT file, and is
then used by cocotb to create randomized differential tests.
"""

MASK64 = (1 << 64) - 1
IV = 0x00001000808C0001
RC = (0xF0, 0xE1, 0xD2, 0xC3, 0xB4, 0xA5, 0x96, 0x87, 0x78, 0x69, 0x5A, 0x4B)


def _ror(x: int, n: int) -> int:
    return ((x >> n) | ((x << (64 - n)) & MASK64)) & MASK64


def _round(s: list[int], c: int) -> None:
    x0, x1, x2, x3, x4 = s
    x2 ^= c
    x0 ^= x4
    x4 ^= x3
    x2 ^= x1
    t0 = x0 ^ ((~x1 & MASK64) & x2)
    t1 = x1 ^ ((~x2 & MASK64) & x3)
    t2 = x2 ^ ((~x3 & MASK64) & x4)
    t3 = x3 ^ ((~x4 & MASK64) & x0)
    t4 = x4 ^ ((~x0 & MASK64) & x1)
    t1 ^= t0
    t0 ^= t4
    t3 ^= t2
    t2 = ~t2 & MASK64
    s[0] = t0 ^ _ror(t0, 19) ^ _ror(t0, 28)
    s[1] = t1 ^ _ror(t1, 61) ^ _ror(t1, 39)
    s[2] = t2 ^ _ror(t2, 1) ^ _ror(t2, 6)
    s[3] = t3 ^ _ror(t3, 10) ^ _ror(t3, 17)
    s[4] = t4 ^ _ror(t4, 7) ^ _ror(t4, 41)
    for i in range(5):
        s[i] &= MASK64


def permutation(words: list[int], rounds: int) -> list[int]:
    s = list(words)
    for c in RC[12 - rounds :]:
        _round(s, c)
    return s


def permutation_trace(words: list[int], rounds: int) -> list[list[int]]:
    """Return the state after every round of p[rounds].

    Keeping this trace in the independent model lets the hardware test find
    the first incorrect round.  A final-state comparison alone can only say
    that the complete permutation is wrong.
    """
    s = list(words)
    trace = []
    for c in RC[12 - rounds :]:
        _round(s, c)
        trace.append(list(s))
    return trace


def _load(block: bytes) -> int:
    return int.from_bytes(block, "little")


def _store(word: int, n: int = 8) -> bytes:
    return word.to_bytes(8, "little")[:n]


def encrypt(key: bytes, nonce: bytes, ad: bytes, plaintext: bytes) -> tuple[bytes, bytes]:
    assert len(key) == 16 and len(nonce) == 16
    k0, k1 = _load(key[:8]), _load(key[8:])
    s = [IV, k0, k1, _load(nonce[:8]), _load(nonce[8:])]
    s = permutation(s, 12)
    s[3] ^= k0
    s[4] ^= k1

    if ad:
        offset = 0
        while len(ad) - offset >= 16:
            s[0] ^= _load(ad[offset : offset + 8])
            s[1] ^= _load(ad[offset + 8 : offset + 16])
            s = permutation(s, 8)
            offset += 16
        tail = ad[offset:]
        if len(tail) >= 8:
            s[0] ^= _load(tail[:8])
            s[1] ^= _load(tail[8:])
            s[1] ^= 1 << (8 * (len(tail) - 8))
        else:
            s[0] ^= _load(tail)
            s[0] ^= 1 << (8 * len(tail))
        s = permutation(s, 8)

    s[4] ^= 0x8000000000000000
    ciphertext = bytearray()
    offset = 0
    while len(plaintext) - offset >= 16:
        s[0] ^= _load(plaintext[offset : offset + 8])
        s[1] ^= _load(plaintext[offset + 8 : offset + 16])
        ciphertext += _store(s[0]) + _store(s[1])
        s = permutation(s, 8)
        offset += 16
    tail = plaintext[offset:]
    if len(tail) >= 8:
        s[0] ^= _load(tail[:8])
        s[1] ^= _load(tail[8:])
        ciphertext += _store(s[0]) + _store(s[1], len(tail) - 8)
        s[1] ^= 1 << (8 * (len(tail) - 8))
    else:
        s[0] ^= _load(tail)
        ciphertext += _store(s[0], len(tail))
        s[0] ^= 1 << (8 * len(tail))

    s[2] ^= k0
    s[3] ^= k1
    s = permutation(s, 12)
    s[3] ^= k0
    s[4] ^= k1
    return bytes(ciphertext), _store(s[3]) + _store(s[4])


def decrypt(
    key: bytes, nonce: bytes, ad: bytes, ciphertext: bytes, tag: bytes
) -> tuple[bytes, bool]:
    # The reference decryption is expressed directly here so randomized tests
    # also check the ciphertext-insertion rule used by the VHDL controller.
    k0, k1 = _load(key[:8]), _load(key[8:])
    s = [IV, k0, k1, _load(nonce[:8]), _load(nonce[8:])]
    s = permutation(s, 12)
    s[3] ^= k0
    s[4] ^= k1

    if ad:
        offset = 0
        while len(ad) - offset >= 16:
            s[0] ^= _load(ad[offset : offset + 8])
            s[1] ^= _load(ad[offset + 8 : offset + 16])
            s = permutation(s, 8)
            offset += 16
        tail = ad[offset:]
        if len(tail) >= 8:
            s[0] ^= _load(tail[:8])
            s[1] ^= _load(tail[8:])
            s[1] ^= 1 << (8 * (len(tail) - 8))
        else:
            s[0] ^= _load(tail)
            s[0] ^= 1 << (8 * len(tail))
        s = permutation(s, 8)
    s[4] ^= 0x8000000000000000

    plaintext = bytearray()
    offset = 0
    while len(ciphertext) - offset >= 16:
        c0 = _load(ciphertext[offset : offset + 8])
        c1 = _load(ciphertext[offset + 8 : offset + 16])
        plaintext += _store(s[0] ^ c0) + _store(s[1] ^ c1)
        s[0], s[1] = c0, c1
        s = permutation(s, 8)
        offset += 16
    tail = ciphertext[offset:]
    if len(tail) >= 8:
        c0 = _load(tail[:8])
        c1 = _load(tail[8:])
        plaintext += _store(s[0] ^ c0) + _store(s[1] ^ c1, len(tail) - 8)
        s[0] = c0
        n = len(tail) - 8
        keep = (1 << (8 * n)) - 1 if n else 0
        s[1] = (s[1] & ~keep) | c1
        s[1] ^= 1 << (8 * n)
    else:
        c0 = _load(tail)
        plaintext += _store(s[0] ^ c0, len(tail))
        keep = (1 << (8 * len(tail))) - 1 if tail else 0
        s[0] = (s[0] & ~keep) | c0
        s[0] ^= 1 << (8 * len(tail))

    s[2] ^= k0
    s[3] ^= k1
    s = permutation(s, 12)
    s[3] ^= k0
    s[4] ^= k1
    expected = _store(s[3]) + _store(s[4])
    return bytes(plaintext), expected == tag
