#!/usr/bin/env python3
"""Encrypt a short ASCII phrase with the VHDL core in Vivado XSim.

Usage: python verification/live_demo.py "Hello, professor!"

The script first calculates the expected answer with the Python reference
model. It then gives the same inputs to the VHDL testbench and compares the
core's answer with that expected answer. The printed hex uses normal byte
order, so it can be compared with a web implementation.

The key and nonce below are fixed demo values. Associated data is empty. A
web comparison must use those same inputs; associated data changes the result.
"""

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys

# Find the project folder from this file's location, regardless of the folder
# from which the user runs the command.
ROOT = Path(__file__).resolve().parents[1]
# The reference model is a sibling of this script. Add its folder to Python's
# import search path before importing encrypt.
sys.path.insert(0, str(ROOT / "verification" / "model"))
from ascon_ref import encrypt  # noqa: E402

# These public demo inputs are 16 bytes each. Reusing a nonce with the same key
# is unsafe for real encryption; the fixed pair is only for this test vector.
KEY = bytes.fromhex("000102030405060708090A0B0C0D0E0F")
NONCE = bytes.fromhex("101112131415161718191A1B1C1D1E1F")
# The testbench expects 1,089 numbered vectors. We replace case 67 in a copy,
# leaving the checked-in vector file alone.
DEMO_CASE = 67


def port_hex(data: bytes) -> str:
    """Turn up to 16 ordinary bytes into one testbench port value.

    The port is 128 bits (16 bytes). Pad a short block with zero bytes, then
    reverse its byte order because the testbench writes the port as one hex
    number with the first input byte at the least significant end.
    """
    return data.ljust(16, b"\x00")[::-1].hex().upper()


def find_vivado() -> str:
    """Find Vivado on PATH or at the expected local installation path."""
    found = shutil.which("vivado.bat") or shutil.which("vivado")
    if found:
        return found
    installed = Path(r"C:\Xilinx\Vivado\2023.2\bin\vivado.bat")
    if installed.exists():
        return str(installed)
    raise SystemExit("Vivado not found; install Vivado 2023.2 or put vivado on PATH")


def main() -> None:
    # An ASCII limit makes one typed character equal one byte in the vector.
    # The testbench has room for at most two 16-byte plaintext blocks.
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plaintext", help="1 to 32 ASCII characters")
    args = parser.parse_args()
    try:
        plaintext = args.plaintext.encode("ascii")
    except UnicodeEncodeError as exc:
        parser.error(f"plaintext must contain ASCII only: {exc}")
    if not 1 <= len(plaintext) <= 32:
        parser.error("plaintext must be 1 to 32 ASCII bytes")

    # The Python model supplies the expected ciphertext and authentication
    # tag. The VHDL result is checked against these values after simulation.
    # b"" means there is no associated data in this demo.
    ciphertext, tag = encrypt(KEY, NONCE, b"", plaintext)

    # Keep every original test case except the reserved demo case. Checking
    # the count and case number catches an unexpected vector-file version.
    input_file = ROOT / "verification" / "vectors" / "xsim_vectors.txt"
    records = input_file.read_text(encoding="ascii").splitlines()
    if len(records) != 1089 or not records[DEMO_CASE - 1].startswith("67 "):
        raise SystemExit("Expected the unchanged 1,089-case compact vector file")

    # One vector line holds the case number, associated-data length, message
    # length, key, nonce, two AD blocks, two plaintext blocks, two expected
    # ciphertext blocks, and the expected tag. Zero-length AD still needs
    # two zero-filled port fields in the file.
    record = [
        str(DEMO_CASE), "0", str(len(plaintext)), port_hex(KEY), port_hex(NONCE),
        port_hex(b""), port_hex(b""), port_hex(plaintext[:16]),
        port_hex(plaintext[16:]), port_hex(ciphertext[:16]),
        port_hex(ciphertext[16:]), port_hex(tag),
    ]
    records[DEMO_CASE - 1] = " ".join(record)
    # Write the changed vector file under build/ so a demo run does not edit
    # the source vectors. The Tcl script passes this path to the testbench.
    output_dir = ROOT / "build" / "live_demo"
    output_dir.mkdir(parents=True, exist_ok=True)
    vector_file = output_dir / "vectors.txt"
    vector_file.write_text("\n".join(records) + "\n", encoding="ascii")

    # Show all inputs used in the comparison. repr() adds quotes to the
    # printed string for clarity; those quotes are not encrypted.
    print(f"Plaintext ASCII: {args.plaintext!r}", flush=True)
    print(f"Plaintext hex:   {plaintext.hex().upper()}", flush=True)
    print(f"Key:             {KEY.hex().upper()}", flush=True)
    print(f"Nonce:           {NONCE.hex().upper()}", flush=True)
    print("Associated data: (empty)", flush=True)
    print("Running Vivado XSim; this may take about a minute...", flush=True)
    # Vivado runs the existing self-checking VHDL testbench. -tclargs gives
    # the Tcl script the path to our modified vector file.
    command = [
        find_vivado(), "-mode", "batch", "-source", str(ROOT / "vivado" / "run_live_demo.tcl"),
        "-nolog", "-nojournal", "-tclargs", str(vector_file),
    ]
    log_file = output_dir / "vivado.log"
    # Capture Vivado's detailed output in a file while the terminal shows
    # only the inputs and final comparison. Stop if the process takes too long.
    with log_file.open("w", encoding="utf-8", errors="replace") as log:
        try:
            completed = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                                       timeout=240, check=False)
        except subprocess.TimeoutExpired:
            raise SystemExit(f"Vivado timed out; inspect {log_file}") from None
    if completed.returncode:
        raise SystemExit(f"Vivado failed (exit {completed.returncode}); inspect {log_file}")

    # The Tcl script copies the testbench's machine-readable results here.
    # Each encryption result is one pipe-separated line such as
    # CASE|67|MODE|ENC|...|OUTPUT0|...|TAG|...|RESULT|PASS.
    results = output_dir / "simulation_vectors.txt"
    case_lines = [line for line in results.read_text(encoding="ascii").splitlines()
                  if line.startswith(f"CASE|{DEMO_CASE}|MODE|ENC|")]
    if len(case_lines) != 1:
        raise SystemExit(f"Could not find live-demo case {DEMO_CASE} in {results}")
    # Split alternating field names and values into a dictionary, so fields
    # can be read by name instead of by their position in the line.
    fields = case_lines[0].split("|")
    observed = dict(zip(fields[::2], fields[1::2]))
    # OUTPUT0 and OUTPUT1 are 16-byte port values. Reverse each block back
    # into normal byte order, join them, then remove zero padding beyond the
    # original plaintext length. The tag uses the same port byte order.
    actual_ciphertext = (bytes.fromhex(observed["OUTPUT0"])[::-1]
                         + bytes.fromhex(observed["OUTPUT1"])[::-1])[:len(plaintext)]
    actual_tag = bytes.fromhex(observed["TAG"])[::-1]
    # Require both the testbench's PASS flag and an independent comparison
    # with the Python reference values before printing an overall PASS.
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
