#!/usr/bin/env bash
# Print assertion context from cocotb logs. usage: show_fail.sh <name>...
for n in "$@"; do
  echo "### $n"
  sed 's/\x1b\[[0-9;]*m//g' "$HOME/ascon_fold_scratch/cocotb/$n/log.txt" | grep -E -A14 "Traceback|AssertionError" | grep -v '^\s*$' | head -${LINES_MAX:-80}
done
