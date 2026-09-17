#!/usr/bin/env python3
"""Fetch the pinned KAT file and derive the compact VHDL TextIO input."""

import argparse
import hashlib
from pathlib import Path
import ssl
from urllib.request import urlopen

import certifi

REVISION = "446347f21b209f3921c65ece70027c366cbe1693"
URL = (
    "https://raw.githubusercontent.com/ascon/ascon-c/"
    f"{REVISION}/crypto_aead/asconaead128/LWC_AEAD_KAT_128_128.txt"
)
EXPECTED_PREFIX = b"Count = 1\nKey = 000102030405060708090A0B0C0D0E0F\n"
EXPECTED_SHA256 = "bbbc34692fe05e5fda0a3b025585622ab3e3747495e5e3655b29aae8c2a4bd33"


def parse_kats(data: bytes):
    record = {}
    for raw_line in data.decode("ascii").splitlines() + [""]:
        if raw_line:
            key, value = raw_line.split(" = ", 1)
            record[key] = value
        elif record:
            combined = bytes.fromhex(record["CT"])
            yield {
                "count": int(record["Count"]),
                "key": bytes.fromhex(record["Key"]),
                "nonce": bytes.fromhex(record["Nonce"]),
                "ad": bytes.fromhex(record["AD"]),
                "pt": bytes.fromhex(record["PT"]),
                "ct": combined[:-16],
                "tag": combined[-16:],
            }
            record = {}


def port_value(data: bytes) -> str:
    """Write bytes in the numeric order shown by a 128-bit VHDL vector."""
    return data.ljust(16, b"\x00")[::-1].hex().upper()


def two_blocks(data: bytes) -> tuple[str, str]:
    if len(data) > 32:
        raise ValueError("the official XSim compact format supports at most 32 bytes")
    return port_value(data[:16]), port_value(data[16:32])


def write_xsim_vectors(data: bytes, output: Path) -> int:
    lines = []
    for vector in parse_kats(data):
        ad0, ad1 = two_blocks(vector["ad"])
        pt0, pt1 = two_blocks(vector["pt"])
        ct0, ct1 = two_blocks(vector["ct"])
        lines.append(
            " ".join(
                [
                    str(vector["count"]),
                    str(len(vector["ad"])),
                    str(len(vector["pt"])),
                    port_value(vector["key"]),
                    port_value(vector["nonce"]),
                    ad0,
                    ad1,
                    pt0,
                    pt1,
                    ct0,
                    ct1,
                    port_value(vector["tag"]),
                ]
            )
        )
    if len(lines) != 1089:
        raise SystemExit(f"expected 1089 KAT records, found {len(lines)}")
    output.write_text("\n".join(lines) + "\n", encoding="ascii")
    return len(lines)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--refresh", action="store_true", help="download the pinned source even if it exists"
    )
    args = parser.parse_args()

    vector_dir = Path(__file__).resolve().parent / "vectors"
    output = vector_dir / "LWC_AEAD_KAT_128_128.txt"
    compact_output = vector_dir / "xsim_vectors.txt"
    output.parent.mkdir(parents=True, exist_ok=True)
    if args.refresh or not output.exists():
        tls_context = ssl.create_default_context(cafile=certifi.where())
        data = urlopen(URL, timeout=30, context=tls_context).read()
        output.write_bytes(data)
        source = f"ascon-c revision {REVISION}"
    else:
        data = output.read_bytes()
        source = "the existing pinned KAT file"

    digest = hashlib.sha256(data).hexdigest()
    if (
        not data.startswith(EXPECTED_PREFIX)
        or len(data) < 100_000
        or digest != EXPECTED_SHA256
    ):
        raise SystemExit("official KAT file failed its prefix, size, or SHA-256 check")
    count = write_xsim_vectors(data, compact_output)
    print(f"validated {output} from {source}")
    print(f"wrote {compact_output} with {count} compact TextIO records")


if __name__ == "__main__":
    main()
