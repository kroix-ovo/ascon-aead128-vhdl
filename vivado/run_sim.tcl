# Recreate the project, run the self-checking XSim bench, and retain its text
# reports under build/vivado/simulation.

set repo_root [file normalize [file join [file dirname [info script]] ..]]
source [file join $repo_root vivado create_project.tcl]
open_project [file join $repo_root build vivado project ascon_aead128.xpr]

set output_dir [file join $repo_root build vivado simulation]
file mkdir $output_dir
launch_simulation -simset sim_1 -mode behavioral
# create_project.tcl sets xsim.simulate.runtime to "all", so
# launch_simulation has already run the bench through its normal $finish.
# A second `run all` can wait indefinitely after the completed simulation.
close_sim

# XSim runs from a generated directory inside the project. Copy the durable
# TextIO artifacts to one predictable location instead of relying on Vivado's
# current working directory.
set xsim_dir [file join $repo_root build vivado project ascon_aead128.sim sim_1 behav xsim]
foreach result_name {simulation_results.txt simulation_vectors.txt} {
  set generated_file [file join $xsim_dir $result_name]
  if {![file exists $generated_file]} {
    close_project
    error "XSim completed without creating $generated_file"
  }
  file copy -force $generated_file [file join $output_dir $result_name]
}
close_project

puts "XSim results copied to $output_dir"
