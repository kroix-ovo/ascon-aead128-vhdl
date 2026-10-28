# Reassess a saved route without changing placement/routing or constraints.
set out [file normalize [lindex $argv 0]]
open_checkpoint [file join $out routed.dcp]
set regs [all_registers]
set setup [get_property SLACK [get_timing_paths -from $regs -to $regs -delay_type max -max_paths 1]]
set hold [get_property SLACK [get_timing_paths -from $regs -to $regs -delay_type min -max_paths 1]]
report_timing -from $regs -to $regs -delay_type max -max_paths 20 -file [file join $out internal_setup_paths.txt]
report_timing -from $regs -to $regs -delay_type min -max_paths 10 -file [file join $out internal_hold_paths.txt]
set f [open [file join $out internal_timing.json] w]
puts $f [format {{"internal_setup_slack_ns":%s,"internal_hold_slack_ns":%s}} $setup $hold]
close $f
