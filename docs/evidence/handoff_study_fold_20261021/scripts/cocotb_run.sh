#!/usr/bin/env bash
# Run one cocotb suite on a private copy of the synced tree (parallel-safe).
# usage: cocotb_run.sh <name> <env-assignments...> -- <run.py args...>
#   e.g. cocotb_run.sh fold_ascon FULL_KAT=1 -- --rounds-per-cycle 3 --buffering --folded --module test_ascon
set -uo pipefail
S=$HOME/ascon_fold_scratch
V=/mnt/c/Users/Symok/Downloads/ascon-aead128-vhdl-main/worktrees/ascon-weight-stream-3rpc/build/linux-venv/bin/python
name=$1; shift
envs=()
while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
shift
D=$S/cocotb/$name
rm -rf "$D"; mkdir -p "$D"
cp -r "$S/wt/rtl" "$S/wt/verification" "$D/"
cd "$D"
export PYTHONDONTWRITEBYTECODE=1
start=$(date +%s)
env "${envs[@]}" $V verification/run.py "$@" > "$D/log.txt" 2>&1
rc=$?
end=$(date +%s)
echo "== $name rc=$rc wall=$((end-start))s args: ${envs[*]} $*"
grep -E "TESTS=|FAIL |PASS " "$D/log.txt" | sed 's/\x1b\[[0-9;]*m//g' | tail -16
