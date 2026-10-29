#!/usr/bin/env bash
# Mirror the worktree's RTL and verification sources into a WSL-native scratch
# tree (fast GHDL I/O). Reads the worktree only; writes only under $S.
set -euo pipefail
WT=/mnt/c/Users/Symok/Downloads/ascon-aead128-vhdl-main/worktrees/ascon-weight-stream-handoff
OLDWT=/mnt/c/Users/Symok/Downloads/ascon-aead128-vhdl-main/worktrees/ascon-weight-stream-3rpc
S=$HOME/ascon_fold_scratch
V=$OLDWT/build/linux-venv/bin/python
export PYTHONDONTWRITEBYTECODE=1
mkdir -p "$S/wt"
rm -rf "$S/wt/rtl" "$S/wt/verification" "$S/wt/scripts"
cp -r "$WT/rtl" "$S/wt/rtl"
mkdir -p "$S/wt/verification"
cp -r "$WT/verification/model" "$WT/verification/vhdl" "$WT/verification/cocotb" "$S/wt/verification/"
cp "$WT"/verification/*.py "$S/wt/verification/"
cp -r "$WT/build/handoff_fold/scripts" "$S/wt/scripts"
mkdir -p "$S/wt/verification/vectors"
# Pinned official KAT (read-only copy from the earlier worktree), SHA-256 checked.
cp "$OLDWT/verification/vectors/LWC_AEAD_KAT_128_128.txt" "$S/wt/verification/vectors/"
echo "bbbc34692fe05e5fda0a3b025585622ab3e3747495e5e3655b29aae8c2a4bd33  $S/wt/verification/vectors/LWC_AEAD_KAT_128_128.txt" | sha256sum -c
(cd "$S/wt" && $V verification/fetch_vectors.py >/dev/null)
# CRLF working copies -> LF for the scratch tree (content otherwise identical).
find "$S/wt/rtl" "$S/wt/verification" -type f \( -name '*.vhd' -o -name '*.py' -o -name '*.v' \) -exec sed -i 's/\r$//' {} +
(cd "$S/wt" && sha256sum rtl/*.vhd verification/vhdl/*.vhd verification/cocotb/*.py verification/model/ascon_ref.py verification/vectors/* > "$S/wt/source_sha256_lf.txt")
echo synced
