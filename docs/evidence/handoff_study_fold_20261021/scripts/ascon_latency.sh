#!/usr/bin/env bash
# Re-run test_ascon on the queued configurations with the final test file (logs the error latency).
set -uo pipefail
S=$HOME/ascon_fold_scratch
WT=/mnt/c/Users/Symok/Downloads/ascon-aead128-vhdl-main/worktrees/ascon-weight-stream-handoff
sed 's/\r$//' $WT/verification/cocotb/test_ascon.py > $S/wt/verification/cocotb/test_ascon.py
B=$S/wt/scripts
for a in "buf_ascon -- --rounds-per-cycle 3 --buffering --module test_ascon" \
         "fold_ascon -- --rounds-per-cycle 3 --buffering --folded --module test_ascon" \
         "buf_ascon_d11 -- --rounds-per-cycle 3 --buffering --input-depth 1 --output-depth 1 --module test_ascon" \
         "fold_ascon_d11 -- --rounds-per-cycle 3 --buffering --folded --input-depth 1 --output-depth 1 --module test_ascon" \
         "u1_ascon -- --rounds-per-cycle 1 --module test_ascon" "u3_ascon -- --rounds-per-cycle 3 --module test_ascon"; do
  bash $B/cocotb_run.sh $a | grep -E "^==|TESTS=" | sed 's/  */ /g' &
done
wait
for n in buf_ascon fold_ascon; do echo "## $n"; grep -h "later than the unbuffered" $S/cocotb/$n/log.txt | sed 's/.*buffered core/buffered core/'; done
