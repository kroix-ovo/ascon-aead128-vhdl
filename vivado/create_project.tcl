# Recreate the Vivado 2023.2 project from source files.
# Run from any directory with: vivado -mode batch -source vivado/create_project.tcl

set repo_root [file normalize [file join [file dirname [info script]] ..]]
set project_dir [file join $repo_root build vivado project]
file mkdir $project_dir

create_project -force ascon_aead128 $project_dir -part xc7a100tcsg324-1
set_property target_language VHDL [current_project]
set_property simulator_language Mixed [current_project]

set rtl_files [list \
  [file join $repo_root rtl ascon_pkg.vhd] \
  [file join $repo_root rtl ascon_permutation.vhd] \
  [file join $repo_root rtl ascon_aead128_core.vhd] \
  [file join $repo_root rtl ascon_demo_top.vhd]]
add_files -norecurse $rtl_files
foreach source_file $rtl_files {
  set_property file_type {VHDL 2008} [get_files $source_file]
}

add_files -fileset constrs_1 -norecurse [file join $repo_root vivado nexys_a7_100t.xdc]
set_property top ascon_demo_top [get_filesets sources_1]

set testbench [file join $repo_root verification vhdl tb_ascon_aead128.vhd]
set vector_file [file join $repo_root verification vectors xsim_vectors.txt]
if {![file exists $vector_file]} {
  error "Missing $vector_file. Run 'python verification/fetch_vectors.py' first."
}
add_files -fileset sim_1 -norecurse $testbench
set_property file_type {VHDL 2008} [get_files $testbench]
set_property top tb_ascon_aead128 [get_filesets sim_1]
set_property generic [list G_VECTOR_FILE=$vector_file] [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
close_project
