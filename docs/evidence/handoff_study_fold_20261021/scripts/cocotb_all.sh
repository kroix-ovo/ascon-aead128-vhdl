#!/usr/bin/env bash
# Full cocotb regression matrix for the fold study (run after sync.sh).
set -uo pipefail
B=$HOME/ascon_fold_scratch/wt/scripts
R="bash $B/cocotb_run.sh"
{
$R u1_ascon -- --rounds-per-cycle 1 --module test_ascon &
$R u3_ascon -- --rounds-per-cycle 3 --module test_ascon &
$R buf_ascon -- --rounds-per-cycle 3 --buffering --module test_ascon &
$R fold_ascon -- --rounds-per-cycle 3 --buffering --folded --module test_ascon &
$R fold_ascon_fullkat FULL_KAT=1 -- --rounds-per-cycle 3 --buffering --folded --module test_ascon &
$R buf_ascon_d11 -- --rounds-per-cycle 3 --buffering --input-depth 1 --output-depth 1 --module test_ascon &
$R fold_ascon_d11 -- --rounds-per-cycle 3 --buffering --folded --input-depth 1 --output-depth 1 --module test_ascon &
wait
$R u3_stream FULL_KAT=1 -- --rounds-per-cycle 3 --module test_stream &
$R buf_stream FULL_KAT=1 -- --rounds-per-cycle 3 --buffering --module test_stream &
$R fold_stream FULL_KAT=1 -- --rounds-per-cycle 3 --buffering --folded --module test_stream &
$R buf_stream_d11 FULL_KAT=0 -- --rounds-per-cycle 3 --buffering --input-depth 1 --output-depth 1 --module test_stream &
$R fold_stream_d11 FULL_KAT=0 -- --rounds-per-cycle 3 --buffering --folded --input-depth 1 --output-depth 1 --module test_stream &
$R fold_stream_d33 FULL_KAT=0 -- --rounds-per-cycle 3 --buffering --folded --input-depth 3 --output-depth 3 --module test_stream &
$R fold_trace -- --rounds-per-cycle 3 --buffering --folded --module test_fold &
wait
$R u1_cycles -- --rounds-per-cycle 1 --module test_cycles &
$R u3_cycles -- --rounds-per-cycle 3 --module test_cycles &
$R buf_cycles -- --rounds-per-cycle 3 --buffering --module test_cycles &
$R fold_cycles -- --rounds-per-cycle 3 --buffering --folded --module test_cycles &
wait
} 2>&1
echo ALL_DONE
