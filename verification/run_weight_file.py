"""Portable smoke check of the full-file bench with synthetic weight bytes.

This verifies the stream/file interface in CI without trained checkpoints or
licensed Vivado. It does not measure training or model behavior.
"""
import argparse
from pathlib import Path
import struct
import subprocess

from gpt2_weights_demo import ROOT, port_hex, encrypt, parse_kats


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ghdl", default="ghdl")
    args = parser.parse_args()
    vectors = list(parse_kats((ROOT / "verification/vectors/LWC_AEAD_KAT_128_128.txt").read_bytes()))
    assert len(vectors) == 1089
    for v in vectors:
        assert encrypt(v["key"], v["nonce"], v["ad"], v["pt"]) == (v["ct"], v["tag"])
    output = ROOT / "build/weight-file-ghdl"
    output.mkdir(parents=True, exist_ok=True)
    sources = [ROOT / "rtl" / name for name in
               ("ascon_pkg.vhd", "ascon_permutation.vhd", "ascon_aead128_core.vhd")]
    sources.append(ROOT / "verification/vhdl/tb_weight_file.vhd")
    subprocess.run([args.ghdl, "-a", "--std=08", *map(str, sources)], cwd=output, check=True)
    for size in (32, 1024):
        case = output / str(size)
        case.mkdir(exist_ok=True)
        # Deterministic FP32 bytes include zeros, signs and varying magnitudes.
        plain = b"".join(struct.pack("<f", ((i % 17) - 8) / 16) for i in range(size // 4))
        key, nonce = bytes(range(16)), size.to_bytes(16, "little")
        cipher, tag = encrypt(key, nonce, b"", plain)
        header = f"{size // 16} {port_hex(key)} {port_hex(nonce)} {port_hex(tag)}\n"
        for name, inputs, expected in (("encrypt_vectors.txt", plain, cipher),
                                       ("decrypt_vectors.txt", cipher, plain)):
            rows = [f"{port_hex(inputs[i:i+16])} {port_hex(expected[i:i+16])}"
                    for i in range(0, size, 16)]
            (case / name).write_text(header + "\n".join(rows) + "\n", encoding="ascii")
        subprocess.run([args.ghdl, "--elab-run", "--std=08", "tb_weight_file",
                        f"-gG_RUN_DIR={case.as_posix()}", "--assert-level=error"],
                       cwd=output, check=True, timeout=60)
        assert "checks=2 pass=2 fail=0" in (case / "simulation_results.txt").read_text()
        for name, expected in (("ciphertext_blocks.txt", cipher), ("recovered_blocks.txt", plain)):
            actual = b"".join(bytes.fromhex(row)[::-1] for row in (case / name).read_text().splitlines())
            assert actual == expected, f"{name} mismatch"
        assert bytes.fromhex((case / "rtl_tag.txt").read_text().strip())[::-1] == tag
        print(f"PASS: {size} synthetic weight bytes encrypted, authenticated and recovered")


if __name__ == "__main__":
    main()
