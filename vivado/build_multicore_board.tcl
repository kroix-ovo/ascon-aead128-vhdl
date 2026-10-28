# Args: frozen source root, new output directory, core count, MMCM divider, synth directive.
set root [file normalize [lindex $argv 0]]
set out [file normalize [lindex $argv 1]]
set cores [lindex $argv 2]
set divider [lindex $argv 3]
set directive [lindex $argv 4]
if {$directive eq ""} {set directive Default}
file mkdir $out
set_param general.maxThreads 1
create_project -in_memory -part xc7a100tcsg324-1
foreach name {ascon_pkg ascon_permutation ascon_aead128_core ascon_elastic_stage ascon_multicore multicore_board_vectors ascon_multicore_selftest} {
  read_vhdl -vhdl2008 [file join $root rtl $name.vhd]
}
read_verilog [file join $root rtl ascon_multicore_board_top.v]
synth_design -directive $directive -top ascon_multicore_board_top -part xc7a100tcsg324-1 -flatten_hierarchy none \
  -generic [list CORES=$cores CLOCK_DIVIDE=$divider]
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property -dict {PACKAGE_PIN E3 IOSTANDARD LVCMOS33} [get_ports CLK100MHZ]
set_property -dict {PACKAGE_PIN M18 IOSTANDARD LVCMOS33} [get_ports BTNU]
foreach {index pin} {0 H17 1 K15 2 J13 3 N14} {
  set_property -dict [list PACKAGE_PIN $pin IOSTANDARD LVCMOS33] [get_ports [format {LED[%d]} $index]]
}
create_clock -name board_clk -period 10.000 [get_ports CLK100MHZ]
# Only the asynchronous reset entry and visual LEDs are excluded; all test,
# source-ROM, wrapper, core, checker, counter and ILA paths are timed.
set_false_path -from [get_ports BTNU]
set_false_path -to [get_ports {LED[*]}]
create_debug_core multicore_ila ila
set_property C_DATA_DEPTH 1024 [get_debug_cores multicore_ila]
set_property port_width 345 [get_debug_ports multicore_ila/probe0]
connect_debug_port multicore_ila/clk [get_nets clk]
set nets {}
foreach n {test_done test_pass test_fail} {lappend nets [get_nets $n]}
foreach {n width} {test_case 4 failure_code 8 passed_mask 10 case_cycles 320} {
  for {set i 0} {$i<$width} {incr i} {lappend nets [get_nets [format {%s[%d]} $n $i]]}
}
connect_debug_port multicore_ila/probe0 $nets
write_checkpoint -force [file join $out synthesized.dcp]
set_param general.maxThreads 2
opt_design
if {$cores==4} {
  # Reuse the study's legal per-core clock-region stripes. Shared ROM/source,
  # checker and ILA logic retain the remaining free sites.
  for {set i 0} {$i<4} {incr i} {
    create_pblock lane_$i
    set cells [get_cells -hier -regexp [format {.*lanes\[%d\]\.core$} $i] -filter {IS_PRIMITIVE == 0}]
    if {[llength $cells]!=1} {error "Core hierarchy not found uniquely"}
    add_cells_to_pblock [get_pblocks lane_$i] $cells
    resize_pblock [get_pblocks lane_$i] -add [format {CLOCKREGION_X0Y%d:CLOCKREGION_X1Y%d} $i $i]
    set_property IS_SOFT false [get_pblocks lane_$i]
  }
}
place_design
route_design
report_utilization -file [file join $out utilization.txt]
report_timing_summary -delay_type min_max -report_unconstrained -file [file join $out timing.txt]
report_timing -delay_type max -max_paths 10 -path_type full_clock_expanded -file [file join $out setup_paths.txt]
check_timing -verbose -file [file join $out timing_checks.txt]
report_route_status -file [file join $out route_status.txt]
report_drc -file [file join $out drc.txt]
report_clocks -file [file join $out clocks.txt]
write_xdc -force [file join $out implemented.xdc]
write_checkpoint -force [file join $out routed.dcp]
write_debug_probes -force [file join $out selftest.ltx]
set setup [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set hold [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
set f [open [file join $out implementation.json] w]
puts $f [format {{"cores":%d,"mmcm_divider":%d,"clock_mhz":%.9f,"setup_slack_ns":%s,"hold_slack_ns":%s}} $cores $divider [expr {900.0/$divider}] $setup $hold]
close $f
if {$setup<0 || $hold<0} {error "Board timing failed; no bitstream generated"}
write_bitstream -force [file join $out selftest.bit]
