# Usage: vivado -mode batch -source route_stream.tcl -tclargs OUT ROOT RPC BUFFER FAST PERIOD
set out [file normalize [lindex $argv 0]]
set root [file normalize [lindex $argv 1]]
set rpc [lindex $argv 2]
set buffered [expr {[lindex $argv 3] ? "true" : "false"}]
set fast [expr {[lindex $argv 4] ? "true" : "false"}]
set period [lindex $argv 5]
file mkdir $out
create_project -in_memory -part xc7a100tcsg324-1
foreach n {ascon_pkg.vhd ascon_permutation.vhd ascon_aead128_core.vhd} {
  read_vhdl -vhdl2008 [file join $root rtl $n]
}
set generics {}
if {$rpc ne "baseline"} {
  set generics [list G_ROUNDS_PER_CYCLE=$rpc G_BUFFERING_ENABLE=$buffered G_FULL_BLOCK_FAST_PATH=$fast]
}
set_param general.maxThreads 1
synth_design -top ascon_aead128_core -mode out_of_context -part xc7a100tcsg324-1 -generic $generics
create_clock -name core_clk -period $period [get_ports clk_i]
set_param general.maxThreads 4
opt_design
place_design
route_design
report_utilization -file [file join $out utilization.txt]
report_timing_summary -delay_type min_max -report_unconstrained -file [file join $out timing.txt]
report_timing -delay_type max -max_paths 10 -path_type full_clock_expanded -file [file join $out setup_paths.txt]
report_timing -delay_type min -max_paths 10 -file [file join $out hold_paths.txt]
check_timing -verbose -file [file join $out timing_checks.txt]
write_xdc -force [file join $out constraints.xdc]
write_checkpoint -force [file join $out routed.dcp]
set setup [get_property SLACK [get_timing_paths -from [all_registers] -to [all_registers] -delay_type max -max_paths 1]]
set hold [get_property SLACK [get_timing_paths -from [all_registers] -to [all_registers] -delay_type min -max_paths 1]]
set f [open [file join $out implementation.json] w]
set members [format {"period_ns": %s, "setup_slack_ns": %s, "hold_slack_ns": %s} $period $setup $hold]
puts $f "\{$members\}"
close $f
