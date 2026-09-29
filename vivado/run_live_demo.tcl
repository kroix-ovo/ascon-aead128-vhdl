# Run the existing self-checking testbench with one caller-supplied vector.
# The vector file contains the official cases plus a replacement for case 67.
if {[llength $argv] != 1} {
  error "usage: vivado -mode batch -source vivado/run_live_demo.tcl -tclargs VECTOR_FILE"
}
set demo_vector_file [file normalize [lindex $argv 0]]
if {![file exists $demo_vector_file]} {
  error "Missing live-demo vector file: $demo_vector_file"
}

set repo_root [file normalize [file join [file dirname [info script]] ..]]
source [file join $repo_root vivado create_project.tcl]
open_project [file join $repo_root build vivado project ascon_aead128.xpr]
set_property generic [list G_VECTOR_FILE=$demo_vector_file] [get_filesets sim_1]

# create_project.tcl sets the simulation runtime to all. launch_simulation runs
# it to completion; issuing a second `run all` here would stall after $finish.
launch_simulation -simset sim_1 -mode behavioral
close_sim

set xsim_dir [file join $repo_root build vivado project ascon_aead128.sim sim_1 behav xsim]
set output_dir [file join $repo_root build live_demo]
file mkdir $output_dir
foreach result_name {simulation_results.txt simulation_vectors.txt} {
  set generated_file [file join $xsim_dir $result_name]
  if {![file exists $generated_file]} {
    close_project
    error "XSim completed without creating $generated_file"
  }
  file copy -force $generated_file [file join $output_dir $result_name]
}
close_project
puts "Live demo results copied to $output_dir"
