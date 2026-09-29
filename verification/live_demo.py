#!/usr/bin/env python3
"""Run a short ASCII phrase through the VHDL core in Vivado XSim.

Usage: python verification/live_demo.py "Hello, professor!"
The displayed ciphertext and tag use normal byte order for web comparison.
"""

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "verification" / "model"))
from ascon_ref import encrypt  # noqa: E402

KEY = bytes.fromhex("000102030405060708090A0B0C0D0E0F")
NONCE = bytes.fromhex("101112131415161718191A1B1C1D1E1F")
DEMO_CASE = 67


def port_hex(data: bytes) -> str:
    """Pack one rate block into the core's 128-bit little-endian port."""
    return data.ljust(16, b"\x00")[::-1].hex().upper()


def find_vivado() -> str:
    found = shutil.which("vivado.bat") or shutil.which("vivado")
    if found:
        return found
    installed = Path(r"C:\Xilinx\Vivado\2023.2\bin\vivado.bat")
    if installed.exists():
        return str(installed)
    raise SystemExit("Vivado not found; install Vivado 2023.2 or put vivado on PATH")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plaintext", help="1 to 32 ASCII characters")
    args = parser.parse_args()
    try:
        plaintext = args.plaintext.encode("ascii")
    except UnicodeEncodeError as exc:
        parser.error(f"plaintext must contain ASCII only: {exc}")
    if not 1 <= len(plaintext) <= 32:
        parser.error("plaintext must be 1 to 32 ASCII bytes")

    ciphertext, tag = encrypt(KEY, NONCE, b"", plaintext)
    input_file = ROOT / "verification" / "vectors" / "xsim_vectors.txt"
    records = input_file.read_text(encoding="ascii").splitlines()
    if len(records) != 1089 or not records[DEMO_CASE - 1].startswith("67 "):
        raise SystemExit("Expected the unchanged 1,089-case compact vector file")

    record = [
        str(DEMO_CASE), "0", str(len(plaintext)), port_hex(KEY), port_hex(NONCE),
        port_hex(b""), port_hex(b""), port_hex(plaintext[:16]),
        port_hex(plaintext[16:]), port_hex(ciphertext[:16]),
        port_hex(ciphertext[16:]), port_hex(tag),
    ]
    records[DEMO_CASE - 1] = " ".join(record)
    output_dir = ROOT / "build" / "live_demo"
    output_dir.mkdir(parents=True, exist_ok=True)
    vector_file = output_dir / "vectors.txt"
    vector_file.write_text("\n".join(records) + "\n", encoding="ascii")

    print(f"Plaintext ASCII: {args.plaintext!r}", flush=True)
    print(f"Plaintext hex:   {plaintext.hex().upper()}", flush=True)
    print(f"Key:             {KEY.hex().upper()}", flush=True)
    print(f"Nonce:           {NONCE.hex().upper()}", flush=True)
    print("Associated data: (empty)", flush=True)
    print("Running Vivado XSim; this may take about a minute...", flush=True)
    command = [
        find_vivado(), "-mode", "batch", "-source", str(ROOT / "vivado" / "run_live_demo.tcl"),
        "-nolog", "-nojournal", "-tclargs", str(vector_file),
    ]
    log_file = output_dir / "vivado.log"
    with log_file.open("w", encoding="utf-8", errors="replace") as log:
        try:
            completed = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                                       timeout=240, check=False)
        except subprocess.TimeoutExpired:
            raise SystemExit(f"Vivado timed out; inspect {log_file}") from None
    if completed.returncode:
        raise SystemExit(f"Vivado failed (exit {completed.returncode}); inspect {log_file}")

    results = output_dir / "simulation_vectors.txt"
    case_lines = [line for line in results.read_text(encoding="ascii").splitlines()
                  if line.startswith(f"CASE|{DEMO_CASE}|MODE|ENC|")]
    if len(case_lines) != 1:
        raise SystemExit(f"Could not find live-demo case {DEMO_CASE} in {results}")
    fields = case_lines[0].split("|")
    observed = dict(zip(fields[::2], fields[1::2]))
    actual_ciphertext = (bytes.fromhex(observed["OUTPUT0"])[::-1]
                         + bytes.fromhex(observed["OUTPUT1"])[::-1])[:len(plaintext)]
    actual_tag = bytes.fromhex(observed["TAG"])[::-1]
    passed = (observed["RESULT"] == "PASS" and actual_ciphertext == ciphertext
              and actual_tag == tag)
    print(f"Core ciphertext: {actual_ciphertext.hex().upper()}")
    print(f"Core tag:        {actual_tag.hex().upper()}")
    print(f"Reference CT:    {ciphertext.hex().upper()}")
    print(f"Reference tag:   {tag.hex().upper()}")
    print(f"Match:           {'PASS' if passed else 'FAIL'}")
    print(f"XSim evidence:   {results}")
    if not passed:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
