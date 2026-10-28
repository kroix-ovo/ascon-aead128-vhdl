# vivado -mode batch -source route_multicore.tcl -tclargs OUT ROOT CORES REG LOCAL PBLOCK PERIOD [SYNTH_DCP]
set out [file normalize [lindex $argv 0]]
set root [file normalize [lindex $argv 1]]
set cores [lindex $argv 2]
set reg [lindex $argv 3]
set local [lindex $argv 4]
set pblock [lindex $argv 5]
set period [lindex $argv 6]
file mkdir $out
set_param general.maxThreads 1
if {[llength $argv] > 7} {
  open_checkpoint [lindex $argv 7]
} else {
create_project -in_memory -part xc7a100tcsg324-1
foreach n {ascon_pkg ascon_permutation ascon_aead128_core ascon_elastic_stage ascon_multicore ascon_multicore_timing} {
  read_vhdl -vhdl2008 [file join $root rtl $n.vhd]
}
synth_design -top ascon_multicore_timing -mode out_of_context -part xc7a100tcsg324-1 \
  -flatten_hierarchy none -generic [list G_CORES=$cores G_BOUNDARY_REGISTERS=$reg G_LOCAL_CONTROL=$local]
write_checkpoint -force [file join $out synthesized.dcp]
}
set_param general.maxThreads 2
create_clock -name core_clk -period $period [get_ports clk_i]
# OOC timing applies to every register-to-register path, including the registered
# harness. Package I/O timing is deliberately outside this integration study.
set_input_delay 0 -clock core_clk [get_ports -filter {DIRECTION == IN && NAME != clk_i}]
set_output_delay 0 -clock core_clk [get_ports -filter {DIRECTION == OUT}]
if {$pblock} {
  # Each clock-region stripe contains legal CLB/BRAM/DSP sites. Hard Pblocks
  # constrain core cells; shared logic can use free sites and routing can cross.
  set stripes {{X0Y0:X1Y0} {X0Y1:X1Y1} {X0Y2:X1Y2} {X0Y3:X1Y3}}
  if {$cores == 2} {set stripes {{X0Y0:X1Y1} {X0Y2:X1Y3}}}
  if {$cores == 1} {set stripes {{X0Y0:X1Y3}}}
  for {set i 0} {$i < $cores} {incr i} {
    create_pblock lane_$i
    set pattern [format {.*lanes\[%d\]\.core$} $i]
    set lane [get_cells -hierarchical -regexp $pattern -filter {IS_PRIMITIVE == 0}]
    if {[llength $lane] == 0} {error "No hierarchy found for lane $i"}
    add_cells_to_pblock [get_pblocks lane_$i] $lane
    lassign [split [lindex $stripes $i] :] first last
    resize_pblock [get_pblocks lane_$i] -add "CLOCKREGION_$first:CLOCKREGION_$last"
    set_property IS_SOFT false [get_pblocks lane_$i]
  }
}
opt_design
place_design
route_design
report_utilization -file [file join $out utilization.txt]
report_utilization -hierarchical -file [file join $out utilization_hierarchical.txt]
report_timing_summary -delay_type min_max -report_unconstrained -file [file join $out timing.txt]
report_timing -delay_type max -max_paths 20 -path_type full_clock_expanded -file [file join $out setup_paths.txt]
report_timing -delay_type min -max_paths 10 -file [file join $out hold_paths.txt]
check_timing -verbose -file [file join $out timing_checks.txt]
report_route_status -file [file join $out route_status.txt]
report_drc -file [file join $out drc.txt]
write_xdc -force [file join $out constraints.xdc]
write_checkpoint -force [file join $out routed.dcp]
set setup [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set hold [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
set lut [llength [get_cells -hier -filter {REF_NAME =~ LUT*}]]
set ff [llength [get_cells -hier -filter {REF_NAME =~ FD*}]]
set bram [llength [get_cells -hier -filter {REF_NAME =~ RAMB*}]]
set f [open [file join $out implementation.json] w]
puts $f [format {{"cores":%d,"registers":%s,"local_control":%s,"pblock":%s,"period_ns":%s,"setup_slack_ns":%s,"hold_slack_ns":%s,"luts":%d,"register_count":%d,"bram_primitives":%d}} \
  $cores $reg $local $pblock $period $setup $hold $lut $ff $bram]
close $f
