#!/bin/bash
# run.sh NAME tcl [tclargs...]   -> runs vivado batch in build/handoff_vivado/NAME
W="C:/Users/Symok/Downloads/ascon-aead128-vhdl-main/worktrees/ascon-weight-stream-handoff"
name=$1; shift; tcl=$1; shift
d="$W/build/handoff_vivado/$name"; mkdir -p "$d"; cd "$d"
"C:/Xilinx/Vivado/2023.2/bin/vivado.bat" -mode batch -nojournal -log "$d/vivado.log" -source "$tcl" -tclargs "$@" > "$d/stdout.txt" 2>&1
echo "$name exit=$?"
