# Core-only (out-of-context) implementation for the handoff timing study.
# Derived from vivado/route_stream.tcl (same read/synth/clock/impl order and
# thread settings) with optional knobs. Usage:
#   vivado -mode batch -source impl_core.tcl -tclargs out:DIR root:DIR rpc:N buf:0|1 period:NS (key:value; batch files split on =) \
#          [fast=0|1] [place=Default] [route=Default] [opt=Default] [physopt=none|Default|AggressiveExplore|...] \
#          [postroute_physopt=0|1] [retiming=0|1] [io=none|<in_ns>,<out_ns>] [overconstrain=0|<ns>] [deep=0|1]
array set A {perm rtl fast 0 place Default route Default opt Default physopt none postroute_physopt 0 retiming 0 io none overconstrain 0 deep 0 buf 0 rpc 1 period 10}
foreach kv $argv {
  set i [string first : $kv]
  set A([string range $kv 0 [expr {$i-1}]]) [string range $kv [expr {$i+1}] end]
}
set out [file normalize $A(out)]
set root [file normalize $A(root)]
file mkdir $out
set t0 [clock seconds]
create_project -in_memory -part xc7a100tcsg324-1
foreach n {ascon_pkg.vhd ascon_permutation.vhd ascon_aead128_core.vhd} {
  set src [file join $root rtl $n]
  if {$n eq "ascon_permutation.vhd" && $A(perm) ne "rtl"} {set src [file normalize $A(perm)]}
  read_vhdl -vhdl2008 $src
}
set buffered [expr {$A(buf) ? "true" : "false"}]
set fast [expr {$A(fast) ? "true" : "false"}]
set generics [list G_ROUNDS_PER_CYCLE=$A(rpc) G_BUFFERING_ENABLE=$buffered G_FULL_BLOCK_FAST_PATH=$fast]
set_param general.maxThreads 1
set synth_args [list -top ascon_aead128_core -mode out_of_context -part xc7a100tcsg324-1 -generic $generics]
if {$A(retiming)} {
  # Retiming needs the clock during synthesis, so supply it via a temp XDC.
  set xdc [file join $out synth_clock.xdc]
  set f [open $xdc w]; puts $f "create_clock -name core_clk -period $A(period) \[get_ports clk_i\]"; close $f
  read_xdc -mode out_of_context $xdc
  lappend synth_args -retiming
}
synth_design {*}$synth_args
if {!$A(retiming)} {
  create_clock -name core_clk -period $A(period) [get_ports clk_i]
}
if {$A(io) ne "none"} {
  lassign [split $A(io) _] din dout
  set ins [get_ports -filter {DIRECTION == IN && NAME != clk_i}]
  set outs [get_ports -filter {DIRECTION == OUT}]
  set_input_delay -clock core_clk $din $ins
  set_output_delay -clock core_clk $dout $outs
}
set_param general.maxThreads 4
opt_design -directive $A(opt)
if {$A(overconstrain) != 0} {
  set_clock_uncertainty -setup $A(overconstrain) [get_clocks core_clk]
}
place_design -directive $A(place)
if {$A(physopt) ne "none"} {
  phys_opt_design -directive $A(physopt)
}
if {$A(overconstrain) != 0} {
  set_clock_uncertainty -setup 0 [get_clocks core_clk]
}
route_design -directive $A(route)
if {$A(postroute_physopt)} {
  phys_opt_design -directive AggressiveExplore
}
report_utilization -file [file join $out utilization.txt]
report_timing_summary -delay_type min_max -report_unconstrained -file [file join $out timing.txt]
report_timing -delay_type max -max_paths 10 -path_type full_clock_expanded -file [file join $out setup_paths.txt]
report_timing -delay_type min -max_paths 10 -file [file join $out hold_paths.txt]
check_timing -verbose -file [file join $out timing_checks.txt]
write_xdc -force [file join $out constraints.xdc]
write_checkpoint -force [file join $out routed.dcp]
if {$A(deep)} {
  report_timing -delay_type max -max_paths 20 -nworst 1 -unique_pins -sort_by slack -file [file join $out top20_unique.txt]
  report_timing -delay_type max -max_paths 200 -nworst 1 -sort_by slack -file [file join $out top200.txt]
  report_utilization -hierarchical -file [file join $out utilization_hier.txt]
  report_design_analysis -timing -logic_level_distribution -max_paths 2000 -file [file join $out design_analysis_timing.txt]
  report_design_analysis -congestion -complexity -file [file join $out design_analysis_congestion.txt]
  report_high_fanout_nets -timing -load_types -max_nets 40 -file [file join $out high_fanout.txt]
  catch {report_qor_suggestions -file [file join $out qor_suggestions.txt]}
  report_route_status -file [file join $out route_status.txt]
}
set rr [get_timing_paths -from [all_registers] -to [all_registers] -delay_type max -max_paths 1]
set rrh [get_timing_paths -from [all_registers] -to [all_registers] -delay_type min -max_paths 1]
set any [get_timing_paths -delay_type max -max_paths 1]
set anyh [get_timing_paths -delay_type min -max_paths 1]
set setup [get_property SLACK $rr]
set hold [get_property SLACK $rrh]
set wns [get_property SLACK $any]
set whs [get_property SLACK $anyh]
set lut [llength [get_cells -hier -filter {PRIMITIVE_GROUP == LUT}]]
set ff [llength [get_cells -hier -filter {PRIMITIVE_GROUP == FLOP_LATCH}]]
set f [open [file join $out implementation.json] w]
puts $f [format {{"perm": "%s", "rpc": %s, "buffered": %s, "fast": %s, "period_ns": %s, "place": "%s", "route": "%s", "opt": "%s", "physopt": "%s", "postroute_physopt": %s, "retiming": %s, "io": "%s", "overconstrain": %s, "reg2reg_setup_slack_ns": %s, "reg2reg_hold_slack_ns": %s, "all_wns_ns": %s, "all_whs_ns": %s, "worst_start": "%s", "worst_end": "%s", "worst_levels": %s, "lut_cells": %s, "ff_cells": %s, "runtime_s": %s}} \
  $A(perm) $A(rpc) $buffered $fast $A(period) $A(place) $A(route) $A(opt) $A(physopt) $A(postroute_physopt) $A(retiming) $A(io) $A(overconstrain) \
  $setup $hold $wns $whs [get_property STARTPOINT_PIN $any] [get_property ENDPOINT_PIN $any] [get_property LOGIC_LEVELS $any] $lut $ff [expr {[clock seconds]-$t0}]]
close $f
