# harness_impl.tcl out:DIR root:DIR period:NS tail:0|1 kh:0|1  (key:value args)
array set A {tail 1 kh 0 period 9}
foreach kv $argv { set i [string first : $kv]; set A([string range $kv 0 [expr {$i-1}]]) [string range $kv [expr {$i+1}] end] }
set out [file normalize $A(out)]; set root [file normalize $A(root)]; file mkdir $out
create_project -in_memory -part xc7a100tcsg324-1
read_vhdl -vhdl2008 [file join $root rtl ascon_pkg.vhd]
read_vhdl -vhdl2008 [file join $root build handoff_vivado variants tail_harness.vhd]
set_param general.maxThreads 1
set fh [expr {$A(kh) ? "none" : "rebuilt"}]
synth_design -top tail_harness -mode out_of_context -part xc7a100tcsg324-1 -flatten_hierarchy $fh -generic [list G_TAIL=[expr {$A(tail) ? "true" : "false"}]]
create_clock -name core_clk -period $A(period) [get_ports clk_i]
set_param general.maxThreads 4
opt_design; place_design; route_design
report_utilization -hierarchical -file [file join $out utilization_hier.txt]
report_timing_summary -file [file join $out timing.txt]
report_timing -max_paths 5 -file [file join $out setup_paths.txt]
set f [open [file join $out classes.txt] w]
proc cls {f name args} {
  set p [get_timing_paths -delay_type max -max_paths 1 {*}$args]
  if {[llength $p]==0} {puts $f "$name none"; return}
  puts $f [format "%-34s slack=%7.3f levels=%2d datapath=%6.3f logic=%6.3f route=%6.3f %s -> %s" $name [get_property SLACK $p] [get_property LOGIC_LEVELS $p] [get_property DATAPATH_DELAY $p] [get_property DATAPATH_LOGIC_DELAY $p] [get_property DATAPATH_NET_DELAY $p] [get_property STARTPOINT_PIN $p] [get_property ENDPOINT_PIN $p]]
}
set st [get_cells -hier -filter {NAME =~ state_reg_reg[*]}]
cls $f "ALL"
cls $f "state->state" -from $st -to $st
if {$A(kh)} {
  cls $f "through 3-round chain" -to $st -through [get_pins -hier -filter {NAME =~ c3/o[*]}]
  if {$A(tail)} {
    cls $f "through 2-round tail+absorb" -to $st -through [get_pins -hier -filter {NAME =~ *c2/o[*]}]
    cls $f "din_reg -> tail -> state" -from [get_cells -hier -filter {NAME =~ din_reg_reg*}] -to $st
    cls $f "tail -> out_reg (ciphertext)" -to [get_cells -hier -filter {NAME =~ out_reg_reg*}]
  }
}
close $f
set p [get_timing_paths -delay_type max -max_paths 1]
set j [open [file join $out implementation.json] w]
puts $j [format {{"harness": 1, "tail": %s, "kh": %s, "period_ns": %s, "wns": %s, "levels": %s}} $A(tail) $A(kh) $A(period) [get_property SLACK $p] [get_property LOGIC_LEVELS $p]]
close $j
