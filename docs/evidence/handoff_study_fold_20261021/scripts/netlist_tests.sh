#!/usr/bin/env bash
# Generated-Verilog (GHDL synth) smoke tests with Icarus and Verilator, as in CI.
# Verilator: oss-cad-suite 5.053 (system 4.038 is too old for cocotb 2); Icarus: system 11.0.
set -uo pipefail
S=$HOME/ascon_fold_scratch
B=$S/wt/scripts
mkdir -p "$S/vbin"
printf '#!/bin/sh\nexec /home/kroix/tools/oss-cad-suite/bin/verilator "$@"\n' > "$S/vbin/verilator"
printf '#!/bin/sh\nexec /home/kroix/tools/oss-cad-suite/bin/verilator_bin "$@"\n' > "$S/vbin/verilator_bin"
chmod +x "$S/vbin/verilator" "$S/vbin/verilator_bin"
R="bash $B/cocotb_run.sh"
G=$S/generated
{
$R nl_icarus_fold_stream FULL_KAT=0 -- --sim icarus --netlist $G/fold.v --rounds-per-cycle 3 --buffering --folded --module test_stream &
$R nl_icarus_fold_ascon KAT_LIMIT=8 -- --sim icarus --netlist $G/fold.v --rounds-per-cycle 3 --buffering --folded --module test_ascon &
$R nl_icarus_fold_cycles -- --sim icarus --netlist $G/fold.v --rounds-per-cycle 3 --buffering --folded --module test_cycles &
$R nl_icarus_buf_stream FULL_KAT=0 -- --sim icarus --netlist $G/buffered.v --rounds-per-cycle 3 --buffering --module test_stream &
$R nl_icarus_default_ascon KAT_LIMIT=8 -- --sim icarus --netlist $G/default.v --module test_ascon &
wait
PATH=$S/vbin:$PATH $R nl_verilator_fold_stream FULL_KAT=0 -- --sim verilator --netlist $G/fold.v --rounds-per-cycle 3 --buffering --folded --module test_stream
PATH=$S/vbin:$PATH $R nl_verilator_fold_cycles -- --sim verilator --netlist $G/fold.v --rounds-per-cycle 3 --buffering --folded --module test_cycles
PATH=$S/vbin:$PATH $R nl_verilator_buf_stream FULL_KAT=0 -- --sim verilator --netlist $G/buffered.v --rounds-per-cycle 3 --buffering --module test_stream
} 2>&1
echo NETLIST_DONE
