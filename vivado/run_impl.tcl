# Synthesize, implement, and archive the Nexys A7 demonstration at 100 MHz.
# The script treats an incomplete run, negative setup slack, missing bitstream,
# or any critical warning as a failure instead of leaving interpretation to the
# Vivado graphical interface.

set repo_root [file normalize [file join [file dirname [info script]] ..]]
source [file join $repo_root vivado create_project.tcl]
open_project [file join $repo_root build vivado project ascon_aead128.xpr]

set report_dir [file join $repo_root build vivado reports]
set artifact_dir [file join $repo_root build vivado artifacts]
file mkdir $report_dir
file mkdir $artifact_dir

proc require_complete_run {run_name} {
  set run_status [get_property STATUS [get_runs $run_name]]
  if {![string match -nocase "*complete*" $run_status]} {
    error "$run_name did not complete successfully. Vivado status: $run_status"
  }
}

proc write_clock_list {output_path} {
  set output_file [open $output_path w]
  puts $output_file "Clock objects after implementation"
  foreach clock_object [get_clocks] {
    puts $output_file [format "%s period=%s waveform=%s" \
      $clock_object \
      [get_property PERIOD $clock_object] \
      [get_property WAVEFORM $clock_object]]
  }
  close $output_file
}

launch_runs synth_1 -jobs 4
wait_on_run synth_1
require_complete_run synth_1
open_run synth_1
report_utilization -file [file join $report_dir post_synth_utilization.txt]
report_utilization -hierarchical -file [file join $report_dir post_synth_hierarchical_utilization.txt]
report_timing_summary -file [file join $report_dir post_synth_timing.txt]
if {[llength [info commands report_ram_utilization]] > 0} {
  report_ram_utilization -file [file join $report_dir post_synth_ram_utilization.txt]
}
close_design

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
require_complete_run impl_1
open_run impl_1
report_utilization -file [file join $report_dir post_route_utilization.txt]
report_utilization -hierarchical -file [file join $report_dir post_route_hierarchical_utilization.txt]
report_timing_summary -file [file join $report_dir post_route_timing.txt]
report_power -file [file join $report_dir post_route_power.txt]
report_drc -file [file join $report_dir post_route_drc.txt]
report_clock_utilization -file [file join $report_dir clock_utilization.txt]
if {[llength [info commands report_clock_networks]] > 0} {
  report_clock_networks -file [file join $report_dir clock_networks.txt]
}
if {[llength [info commands report_ram_utilization]] > 0} {
  report_ram_utilization -file [file join $report_dir post_route_ram_utilization.txt]
}
write_clock_list [file join $report_dir clocks.txt]
write_checkpoint -force [file join $report_dir ascon_demo_routed.dcp]

set worst_paths [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
if {[llength $worst_paths] == 0} {
  close_design
  close_project
  error "Vivado did not return a setup timing path"
}
set worst_slack [get_property SLACK [lindex $worst_paths 0]]
set slack_file [open [file join $report_dir setup_slack.txt] w]
puts $slack_file "WNS_NS=$worst_slack"
close $slack_file
if {$worst_slack < 0.0} {
  close_design
  close_project
  error "Post-route setup slack is negative: $worst_slack ns"
}

set implementation_dir [get_property DIRECTORY [get_runs impl_1]]
set generated_bitstream [file join $implementation_dir ascon_demo_top.bit]
if {![file exists $generated_bitstream]} {
  close_design
  close_project
  error "Implementation completed without the expected bitstream: $generated_bitstream"
}
file copy -force $generated_bitstream [file join $artifact_dir ascon_demo_top.bit]

# Vivado 2023.2 does not provide get_messages in batch Tcl. Inspect the
# synthesis and implementation run logs instead so the release flow still
# fails closed when either child run emits a critical warning.
set critical_messages [list]
foreach run_name {synth_1 impl_1} {
  set run_log [file join [get_property DIRECTORY [get_runs $run_name]] runme.log]
  if {[file exists $run_log]} {
    set run_log_file [open $run_log r]
    while {[gets $run_log_file log_line] >= 0} {
      if {[string match "*CRITICAL WARNING:*" $log_line]} {
        lappend critical_messages "$run_name: $log_line"
      }
    }
    close $run_log_file
  }
}
set warning_file [open [file join $report_dir critical_warnings.txt] w]
foreach warning_message $critical_messages {
  puts $warning_file $warning_message
}
close $warning_file
set critical_count [llength $critical_messages]

close_design
close_project

if {$critical_count > 0} {
  error "Vivado reported $critical_count critical warning(s); see critical_warnings.txt"
}

puts "Bitstream: [file join $artifact_dir ascon_demo_top.bit]"
puts "Post-route WNS: $worst_slack ns"
puts "Reports: $report_dir"
