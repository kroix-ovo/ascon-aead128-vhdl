# Re-run physical implementation at a slower MMCM clock from a routed checkpoint.
# Args: routed.dcp OUT CLOCK_DIVIDE (e.g. 12 => 83.333 MHz from 100 MHz).
set checkpoint [file normalize [lindex $argv 0]]
set out [file normalize [lindex $argv 1]]
set divider [lindex $argv 2]
file mkdir $out
open_checkpoint $checkpoint
if {[get_property PART [current_design]] ne "xc7a100tcsg324-1"} {error "Unexpected FPGA part"}
set mmcm [get_cells -hier -filter {REF_NAME =~ MMCME2*}]
if {[llength $mmcm] != 1} {error "Expected one MMCM"}
set old_divider [get_property CLKOUT0_DIVIDE_F $mmcm]
if {$divider <= $old_divider} {error "This runner only lowers the configured clock"}
set_property CLKOUT0_DIVIDE_F $divider $mmcm
update_timing
set output_clock [get_clocks -of_objects [get_pins $mmcm/CLKOUT0]]
if {[llength $output_clock] != 1} {error "Missing generated core clock"}
set period [get_property PERIOD $output_clock]
# MMCM VCO is 1000 MHz: divider numerically equals period in ns.
if {abs($period-$divider) > 0.001} {error "Generated clock did not update: period=$period"}
route_design -unroute
place_design
route_design
report_utilization -file [file join $out utilization.txt]
report_timing_summary -delay_type min_max -report_unconstrained -file [file join $out timing.txt]
report_timing -delay_type max -max_paths 10 -path_type full_clock_expanded -file [file join $out setup_paths.txt]
report_timing -delay_type min -max_paths 10 -file [file join $out hold_paths.txt]
check_timing -verbose -file [file join $out timing_checks.txt]
report_clocks -file [file join $out clocks.txt]
write_xdc -force [file join $out constraints.xdc]
write_checkpoint -force [file join $out routed.dcp]
write_debug_probes -force [file join $out selftest.ltx]
set setup [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set hold [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
set f [open [file join $out implementation.json] w]
set members [format {"clock_divide": %s, "period_ns": %s, "setup_slack_ns": %s, "hold_slack_ns": %s} $divider $period $setup $hold]
puts $f "\{$members\}"
close $f
set f [open [file join $out clock_change.txt] w]
puts $f "Checkpoint=$checkpoint; MMCM=$mmcm; CLKOUT0_DIVIDE_F $old_divider -> $divider; generated period=$period ns"
close $f
if {$setup < 0 || $hold < 0} {error "Slower board clock still failed timing; no bitstream"}
write_bitstream -force [file join $out selftest.bit]
