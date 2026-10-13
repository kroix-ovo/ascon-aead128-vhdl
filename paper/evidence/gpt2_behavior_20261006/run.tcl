set run_dir [file normalize [lindex $argv 0]]
set root [file normalize [lindex $argv 1]]
create_project -force gpt2_weights [file join $run_dir project] -part xc7a100tcsg324-1
foreach name {ascon_pkg.vhd ascon_permutation.vhd ascon_aead128_core.vhd} {
  set source_file [file join $root rtl $name]
  add_files -norecurse $source_file
  set_property file_type {VHDL 2008} [get_files $source_file]
}
set_property top ascon_aead128_core [get_filesets sources_1]
set bench [file join $run_dir tb_gpt2_weights.vhd]
add_files -fileset sim_1 -norecurse $bench
set_property file_type {VHDL 2008} [get_files $bench]
set_property top tb_gpt2_weights [get_filesets sim_1]
set_property generic [list G_VECTOR_FILE=[file join $run_dir weights_vector.txt]] [get_filesets sim_1]
set_property xsim.simulate.runtime all [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
launch_simulation -simset sim_1 -mode behavioral
close_sim
set sim_dir [file join $run_dir project gpt2_weights.sim sim_1 behav xsim]
foreach name {simulation_results.txt simulation_vectors.txt full_output.txt} {
  file copy -force [file join $sim_dir $name] [file join $run_dir $name]
}
close_project
