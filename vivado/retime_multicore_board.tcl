# Preserve the failed route, lower only its MMCM clock, and route a new attempt.
# Args: routed checkpoint, new output, core count, new divider.
set checkpoint [file normalize [lindex $argv 0]]
set out [file normalize [lindex $argv 1]]
set cores [lindex $argv 2]
set divider [lindex $argv 3]
file mkdir $out
set_param general.maxThreads 2
open_checkpoint $checkpoint
if {[get_property PART [current_design]] ne "xc7a100tcsg324-1"} {error "Unexpected FPGA part"}
set mmcm [get_cells -hier -filter {REF_NAME =~ MMCME2*}]
if {[llength $mmcm]!=1} {error "Expected one MMCM"}
set old [get_property CLKOUT0_DIVIDE_F $mmcm]
if {$divider<=$old} {error "Only lower-clock attempts are permitted"}
set_property CLKOUT0_DIVIDE_F $divider $mmcm
update_timing
set output_clock [get_clocks -of_objects [get_pins $mmcm/CLKOUT0]]
set period [get_property PERIOD $output_clock]
if {abs($period-$divider/0.9)>0.002} {error "Generated clock failed to update"}
route_design -unroute
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
set f [open [file join $out clock_change.txt] w]
puts $f "Checkpoint=$checkpoint MMCM=$mmcm divider=$old->$divider period=$period ns"
close $f
if {$setup<0 || $hold<0} {error "Board timing failed; no bitstream generated"}
write_bitstream -force [file join $out selftest.bit]
