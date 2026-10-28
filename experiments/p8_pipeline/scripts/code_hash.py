#!/usr/bin/env python3
"""SHA-256 of VHDL with comments and blank lines removed.

Used to show that edits made after the timing runs (header renames) changed
comments only, so the implemented logic is identical to what was measured.
"""
import hashlib
import json
import re
import sys
from pathlib import Path

EXP = Path(__file__).resolve().parents[1]


def code_hash(path: Path) -> str:
    lines = []
    for line in path.read_text().splitlines():
        code = re.sub(r"--.*$", "", line).rstrip()
        if code.strip():
            lines.append(code)
    return hashlib.sha256("\n".join(lines).encode()).hexdigest()


def main():
    files = sorted((EXP / "rtl").rglob("*.vhd")) + sorted((EXP / "bench").glob("*.vhd"))
    result = {str(p.relative_to(EXP)).replace("\\", "/"): code_hash(p) for p in files}
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else None
    text = json.dumps(result, indent=2)
    if out:
        out.write_text(text)
    print(text)


if __name__ == "__main__":
    main()
