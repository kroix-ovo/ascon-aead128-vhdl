#!/usr/bin/env bash
# AD padding fix regression: sync, cocotb matrix, framing probe.
set -uo pipefail
B=/mnt/c/Users/Symok/Downloads/ascon-aead128-vhdl-main/worktrees/ascon-weight-stream-handoff/build/handoff_fold/scripts
bash $B/sync.sh
W=$HOME/ascon_fold_scratch/wt/scripts
R="bash $W/cocotb_run.sh"
{
$R pf_u1_ascon -- --rounds-per-cycle 1 --module test_ascon &
$R pf_u3_ascon -- --rounds-per-cycle 3 --module test_ascon &
$R pf_buf_ascon -- --rounds-per-cycle 3 --buffering --module test_ascon &
$R pf_fold_ascon -- --rounds-per-cycle 3 --buffering --folded --module test_ascon &
wait
$R pf_u1_kat FULL_KAT=1 -- --rounds-per-cycle 1 --module test_ascon &
$R pf_buf_kat FULL_KAT=1 -- --rounds-per-cycle 3 --buffering --module test_ascon &
$R pf_buf_d11 -- --rounds-per-cycle 3 --buffering --input-depth 1 --output-depth 1 --module test_ascon &
$R pf_buf_stream FULL_KAT=1 -- --rounds-per-cycle 3 --buffering --module test_stream &
wait
$R pf_u1_cycles -- --rounds-per-cycle 1 --module test_cycles &
$R pf_u3_cycles -- --rounds-per-cycle 3 --module test_cycles &
$R pf_buf_cycles -- --rounds-per-cycle 3 --buffering --module test_cycles &
$R pf_fold_cycles -- --rounds-per-cycle 3 --buffering --folded --module test_cycles &
wait
} 2>&1
bash $B/framing_probe.sh
echo ALL_DONE
