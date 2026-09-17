"""Unit tests for the independent software model.

These tests run without an HDL simulator.  They catch byte-order and padding
errors in the model before that model is used as the cocotb oracle.
"""

from pathlib import Path

from ascon_ref import decrypt, encrypt, permutation


def _records():
    path = Path(__file__).parents[1] / "vectors" / "LWC_AEAD_KAT_128_128.txt"
    record = {}
    for line in path.read_text().splitlines() + [""]:
        if not line:
            if record:
                combined = bytes.fromhex(record["CT"])
                yield (
                    bytes.fromhex(record["Key"]),
                    bytes.fromhex(record["Nonce"]),
                    bytes.fromhex(record["AD"]),
                    bytes.fromhex(record["PT"]),
                    combined[:-16],
                    combined[-16:],
                )
                record = {}
        else:
            name, value = line.split(" = ", 1)
            record[name] = value


def test_empty_official_vector():
    key, nonce, ad, plaintext, ciphertext, tag = next(_records())
    assert encrypt(key, nonce, ad, plaintext) == (ciphertext, tag)
    assert decrypt(key, nonce, ad, ciphertext, tag) == (plaintext, True)


def test_boundaries_against_official_vectors():
    wanted = {0, 1, 7, 8, 15, 16, 17, 31, 32}
    checked = 0
    for key, nonce, ad, plaintext, ciphertext, tag in _records():
        if len(ad) in wanted and len(plaintext) in wanted:
            assert encrypt(key, nonce, ad, plaintext) == (ciphertext, tag)
            assert decrypt(key, nonce, ad, ciphertext, tag) == (plaintext, True)
            checked += 1
    assert checked == len(wanted) ** 2


def test_corrupted_tag_is_rejected():
    key, nonce, ad, plaintext, ciphertext, tag = next(_records())
    bad_tag = bytes([tag[0] ^ 0x80]) + tag[1:]
    recovered, accepted = decrypt(key, nonce, ad, ciphertext, bad_tag)
    assert recovered == plaintext
    assert not accepted


def test_permutation_has_five_64_bit_words():
    result = permutation([0, 1, 2, 3, 4], 12)
    assert len(result) == 5
    assert all(0 <= word < 2**64 for word in result)
