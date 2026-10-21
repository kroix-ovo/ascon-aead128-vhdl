#!/usr/bin/env bash
grep -h "checked groups" ~/ascon_fold_scratch/cocotb/fold_trace/log.txt | sed 's/.*checked/checked/'
which iverilog verilator yosys
iverilog -V 2>&1 | head -1
verilator --version 2>&1
ls /home/kroix/tools/oss-cad-suite/bin 2>/dev/null | grep -E '^(iverilog|verilator|yosys|ghdl)$'
/home/kroix/tools/oss-cad-suite/bin/verilator --version 2>/dev/null
/home/kroix/tools/oss-cad-suite/bin/iverilog -V 2>/dev/null | head -1
ghdl --version | head -1
ghdl synth --help 2>&1 | head -2
