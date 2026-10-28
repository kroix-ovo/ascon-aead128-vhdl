#!/usr/bin/env python3
"""One-time rename of working variant names to the final A/B/C/D scheme.

Run only when no sweep is active.  Renames RTL directories, simulation and
run directories, sweep summaries and logs, and rewrites the old names inside
JSON/log/shell files so every recorded path stays valid.
"""

import re
from pathlib import Path

EXP = Path(__file__).resolve().parents[1]
MAPPING = {
    "B_keep": "A_ctrl1",        # control experiment on A: local keep decode
    "B2_onehot": "A_ctrl2",     # + one-hot controller + tree tag compare
    "C_split": "B_2stage",      # two-stage reused round
    "D_2stage": "D",            # B_2stage + A_ctrl2 control changes
    "D_3stage": "D_alt_3stage", # verified only; not selected, not swept
}
# A name may be followed by "_<strategy>" (B_keep_default), so a trailing
# underscore counts as a boundary; a leading one does not.
PATTERN = re.compile(r"(?<![A-Za-z0-9_])(" + "|".join(map(re.escape, MAPPING)) + r")(?![A-Za-z0-9])")


def rename_tree(root: Path):
    # Deepest paths first so parents are renamed after their children.
    for p in sorted(root.rglob("*"), key=lambda q: len(q.parts), reverse=True):
        new_name = PATTERN.sub(lambda m: MAPPING[m.group(1)], p.name)
        if new_name != p.name:
            p.rename(p.with_name(new_name))


def rewrite_text(root: Path):
    for p in root.rglob("*"):
        if p.is_file() and p.suffix in {".json", ".log", ".sh", ".py", ".md", ".txt"} and p.name != "rename_variants.py":
            text = p.read_text(errors="replace")
            new = PATTERN.sub(lambda m: MAPPING[m.group(1)], text)
            if new != text:
                p.write_text(new)


def main():
    for sub in ("rtl", "results"):
        rename_tree(EXP / sub)
    rewrite_text(EXP / "results")
    rewrite_text(EXP / "scripts")
    print("renamed:", MAPPING)


if __name__ == "__main__":
    main()
