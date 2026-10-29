# Copy of vivado/route_weight_board.tcl for the fold study (G_FOLDED_ABSORB board RTL copies); bitstream step removed.
# Board-integrated route, including clock generator, demo and hardware selftest.
# Args: OUT ROOT CLOCK_DIVIDE (10 => 100 MHz, 20 => 50 MHz)
set out [file normalize [lindex $argv 0]]
set root [file normalize [lindex $argv 1]]
set divider [lindex $argv 2]
file mkdir $out
create_project -in_memory -part xc7a100tcsg324-1
foreach n {ascon_pkg.vhd ascon_permutation.vhd ascon_aead128_core.vhd ascon_demo_top.vhd ascon_demo_autotest.vhd ascon_selftest_vectors.vhd ascon_weight_selftest.vhd} {
  read_vhdl -vhdl2008 [file join $root rtl $n]
}
read_verilog [file join $root rtl ascon_weight_board_top.v]
read_xdc [file join $root vivado nexys_a7_100t.xdc]
set_param general.maxThreads 1
synth_design -directive RuntimeOptimized -flatten_hierarchy none -top ascon_weight_board_top -part xc7a100tcsg324-1 -generic CLOCK_DIVIDE=$divider
# Buttons and switches enter synchronizers; LEDs are unsampled indicators.
set_false_path -from [get_ports {SW[*] BTNC BTNU}]
set_false_path -to [get_ports {LED[*]}]
# Instrument latched selftest results so hardware behavior can be read via JTAG.
create_debug_core selftest_ila ila
set_property C_DATA_DEPTH 1024 [get_debug_cores selftest_ila]
set_property port_width 81 [get_debug_ports selftest_ila/probe0]
connect_debug_port selftest_ila/clk [get_nets clk]
set probe_nets {}
foreach n {done pass fail} {lappend probe_nets [get_nets $n]}
for {set i 0} {$i < 8} {incr i} {lappend probe_nets [get_nets [format {test_case[%d]} $i]]}
for {set i 0} {$i < 32} {incr i} {lappend probe_nets [get_nets [format {cycles[%d]} $i]]}
foreach n {auto_done auto_pass auto_fail} {lappend probe_nets [get_nets $n]}
for {set i 0} {$i < 3} {incr i} {lappend probe_nets [get_nets [format {auto_case[%d]} $i]]}
for {set i 0} {$i < 32} {incr i} {lappend probe_nets [get_nets [format {auto_cycles[%d]} $i]]}
connect_debug_port selftest_ila/probe0 $probe_nets
set_param general.maxThreads 4
opt_design
place_design
route_design
report_utilization -file [file join $out utilization.txt]
report_timing_summary -delay_type min_max -report_unconstrained -file [file join $out timing.txt]
report_timing -delay_type max -max_paths 10 -path_type full_clock_expanded -file [file join $out setup_paths.txt]
check_timing -verbose -file [file join $out timing_checks.txt]
report_clocks -file [file join $out clocks.txt]
write_xdc -force [file join $out constraints.xdc]
write_checkpoint -force [file join $out routed.dcp]
write_debug_probes -force [file join $out selftest.ltx]
set setup [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set hold [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
set f [open [file join $out implementation.json] w]
set members [format {"clock_divide": %s, "setup_slack_ns": %s, "hold_slack_ns": %s} $divider $setup $hold]
puts $f "\{$members\}"
close $f
# FOLD STUDY COPY: no bitstream is written (timing/utilization study only; hardware is not programmed).
