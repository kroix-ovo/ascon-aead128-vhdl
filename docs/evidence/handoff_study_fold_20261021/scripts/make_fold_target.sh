#!/usr/bin/env bash
# Exercise the new Makefile target (LF copy of the worktree Makefile) in the scratch tree.
set -uo pipefail
S=$HOME/ascon_fold_scratch
V=/mnt/c/Users/Symok/Downloads/ascon-aead128-vhdl-main/worktrees/ascon-weight-stream-3rpc/build/linux-venv/bin/python
D=$S/make_equiv
sed 's/\r$//' /mnt/c/Users/Symok/Downloads/ascon-aead128-vhdl-main/worktrees/ascon-weight-stream-handoff/Makefile > "$D/Makefile"
cd "$D" && export PYTHONDONTWRITEBYTECODE=1 && make vhdl-textio-fold-test PYTHON=$V 2>&1 | tail -4
echo "make rc=${PIPESTATUS[0]}"
tail -1 "$D/build/ghdl-textio-fold/simulation_results.txt"
