# Implement one variant of the p8 experiment at one clock period.
#
# usage: vivado -mode batch -source impl_one.tcl -tclargs \
#          VARIANT_DIR PERIOD_NS STRATEGY OUT_DIR
#
# VARIANT_DIR holds the variant's ascon_permutation.vhd and
# ascon_aead128_core.vhd (the baseline uses the repository rtl/ directory).
# The package and benchmark harness are shared by every variant.  The script
# never adds false-path or multicycle exceptions; the only clock constraint is
# the requested period on the oscillator pin.

if {[llength $argv] != 4} {
  error "usage: impl_one.tcl VARIANT_DIR PERIOD_NS STRATEGY OUT_DIR"
}
lassign $argv variant_dir period strategy out_dir
set variant_dir [file normalize $variant_dir]
set out_dir [file normalize $out_dir]
file mkdir $out_dir

set exp_root  [file normalize [file join [file dirname [info script]] ..]]
set repo_root [file normalize [file join $exp_root .. ..]]
set part xc7a100tcsg324-1

set sources [list \
  [file join $repo_root rtl ascon_pkg.vhd] \
  [file join $variant_dir ascon_permutation.vhd] \
  [file join $variant_dir ascon_aead128_core.vhd] \
  [file join $exp_root bench ascon_bench_top.vhd]]
foreach f $sources { read_vhdl -vhdl2008 $f }

# Pins come from the shared XDC; the clock period is written per run so that
# synthesis, placement, and routing all see the same requested target.
set xdc [file join $out_dir constraints.xdc]
set fh [open [file join $exp_root bench ascon_bench_pins.xdc] r]
set pin_text [read $fh]
close $fh
set fh [open $xdc w]
puts $fh $pin_text
puts $fh [format "create_clock -name sys_clk_pin -period %.3f \[get_ports CLK100MHZ\]" $period]
close $fh
read_xdc $xdc

# Strategies.  Every variant is run with the same named strategy so that
# comparisons never mix implementation effort with architecture.
set synth_args {}
set place_dir Default
set phys_dir  {}
set route_dir Default
switch -- $strategy {
  default {}
  retime  { set synth_args {-retiming} }
  explore {
    set synth_args {-directive PerformanceOptimized}
    set place_dir ExtraTimingOpt
    set phys_dir  AggressiveExplore
    set route_dir AggressiveExplore
  }
  explore_retime {
    set synth_args {-directive PerformanceOptimized -retiming}
    set place_dir ExtraTimingOpt
    set phys_dir  AggressiveExplore
    set route_dir AggressiveExplore
  }
  physopt { set phys_dir Default }
  default { error "unknown strategy $strategy" }
}

synth_design -top ascon_bench_top -part $part {*}$synth_args
report_utilization -file [file join $out_dir post_synth_utilization.txt]

opt_design
place_design -directive $place_dir
if {$phys_dir ne {}} { phys_opt_design -directive $phys_dir }
route_design -directive $route_dir
if {$phys_dir ne {}} { phys_opt_design -directive $phys_dir }

report_timing_summary -max_paths 20 -report_unconstrained -file [file join $out_dir timing_summary.txt]
report_timing -delay_type max -max_paths 40 -nworst 1 -unique_pins -input_pins \
  -file [file join $out_dir critical_paths.txt]
report_utilization -file [file join $out_dir utilization.txt]
report_utilization -hierarchical -file [file join $out_dir utilization_hier.txt]
report_drc -file [file join $out_dir drc.txt]
report_route_status -file [file join $out_dir route_status.txt]
report_pulse_width -file [file join $out_dir pulse_width.txt]
check_timing -verbose -file [file join $out_dir check_timing.txt]
report_methodology -file [file join $out_dir methodology.txt]

# Machine-readable summary.
proc jstr {s} { return "\"[string map {\\ \\\\ \" \\\"} $s]\"" }

set setup [get_timing_paths -delay_type max -max_paths 1]
set hold  [get_timing_paths -delay_type min -max_paths 1]
set wns [get_property SLACK $setup]
set whs [get_property SLACK $hold]
# TNS and pulse-width slack: the first numeric row after the "WNS(ns)"
# header of the design timing summary.
set tns "null"
set wpws "null"
set fh [open [file join $out_dir timing_summary.txt] r]
set after_header 0
while {[gets $fh line] >= 0} {
  if {[string match "*WNS(ns)*TNS(ns)*" $line]} { set after_header 1; continue }
  if {$after_header && [regexp {^\s*-?\d} $line]} {
    set fields [regexp -all -inline {\S+} $line]
    set tns  [lindex $fields 1]
    set wpws [lindex $fields 8]
    break
  }
}
close $fh

set rs [report_route_status -return_string]
set unrouted 0
if {[regexp {# of nets with routing errors\.*\s*:\s*(\d+)} $rs -> n]} { set unrouted $n }
set drc_errs [llength [get_drc_violations -quiet -filter {SEVERITY == Error}]]
set drc_crit [llength [get_drc_violations -quiet -filter {SEVERITY == "Critical Warning"}]]

set luts [llength [get_cells -hier -quiet -filter {PRIMITIVE_GROUP == LUT}]]
set ffs  [llength [get_cells -hier -quiet -filter {PRIMITIVE_GROUP == FLOP_LATCH}]]
set core_luts [llength [get_cells -hier -quiet -filter {PRIMITIVE_GROUP == LUT && NAME =~ core_u/*}]]
set core_ffs  [llength [get_cells -hier -quiet -filter {PRIMITIVE_GROUP == FLOP_LATCH && NAME =~ core_u/*}]]

set path_json {}
foreach p [get_timing_paths -delay_type max -max_paths 25 -nworst 1 -unique_pins] {
  set nets [get_nets -quiet -of_objects $p]
  set max_fo 0
  foreach n $nets {
    set fo [get_property FLAT_PIN_COUNT $n]
    if {$fo ne {} && $fo > $max_fo} { set max_fo $fo }
  }
  lappend path_json [format {{"slack": %s, "start": %s, "end": %s, "levels": %s, "logic_ns": %s, "route_ns": %s, "skew_ns": %s, "uncertainty_ns": %s, "max_net_pins": %s}} \
    [get_property SLACK $p] \
    [jstr [get_property NAME [get_property STARTPOINT_PIN $p]]] \
    [jstr [get_property NAME [get_property ENDPOINT_PIN $p]]] \
    [get_property LOGIC_LEVELS $p] \
    [get_property DATAPATH_LOGIC_DELAY $p] \
    [get_property DATAPATH_NET_DELAY $p] \
    [get_property SKEW $p] \
    [get_property UNCERTAINTY $p] \
    $max_fo]
}

# Worst path per functional category.  The overall top paths tend to come
# from one family, so each category is queried separately.
proc seq_cells {patterns} {
  set result {}
  foreach pat $patterns {
    set result [concat $result [get_cells -quiet -hier -filter "IS_SEQUENTIAL && NAME =~ $pat"]]
  }
  return $result
}
set P core_u/permutation_u
set categories [list \
  [list input_decode   {in_keep_reg* in_data_reg* in_valid_reg in_last_reg in_kind_reg} {core_u/*}] \
  [list ctrl_to_state  {core_u/FSM_* core_u/controller_state*} {core_u/state_reg_reg*}] \
  [list ctrl_to_perm   {core_u/FSM_* core_u/controller_state*} "$P/*"] \
  [list ctrl_to_output {core_u/FSM_* core_u/controller_state*} {core_u/out_* core_u/tag_reg* core_u/auth* core_u/commit* core_u/discard*}] \
  [list perm_round     "$P/state_reg_reg*" "$P/state_reg_reg* $P/sbox_reg_reg* $P/s1_reg_reg*"] \
  [list perm_stage_mid "$P/s1_reg_reg*" "$P/s2_reg_reg*"] \
  [list perm_stage_out "$P/sbox_reg_reg* $P/s2_reg_reg*" "$P/state_reg_reg*"] \
  [list perm_control   "$P/round_number* $P/busy* $P/phase* $P/final*" "$P/state_reg_reg* $P/sbox_reg_reg* $P/s1_reg_reg* $P/s2_reg_reg*"] \
  [list perm_load      {core_u/state_reg_reg*} "$P/state_reg_reg*"] \
  [list perm_capture   "$P/state_reg_reg*" {core_u/state_reg_reg*}] \
  [list perm_done      "$P/done_reg*" {core_u/*}] \
  [list absorb_output  {core_u/state_reg_reg*} {core_u/out_*}] \
  [list finalize_tag   "$P/state_reg_reg* core_u/key_reg*" {core_u/tag_reg*}] \
  [list authenticate   {core_u/tag_reg* tag_in_reg* tag_in_valid_reg} {core_u/*}] \
  [list to_harness     {core_u/*} {signature_reg* drive_state* cmd_* in_* tag_in* beats_left*}] \
]
set cat_json {}
foreach cat $categories {
  lassign $cat cname from_pats to_pats
  set from_cells [seq_cells $from_pats]
  set to_cells [seq_cells $to_pats]
  if {[llength $from_cells] == 0 || [llength $to_cells] == 0} { continue }
  set p [get_timing_paths -quiet -delay_type max -max_paths 1 -from $from_cells -to $to_cells]
  if {[llength $p] == 0} { continue }
  set max_fo 0
  foreach n [get_nets -quiet -of_objects $p] {
    set fo [get_property FLAT_PIN_COUNT $n]
    if {$fo ne {} && $fo > $max_fo} { set max_fo $fo }
  }
  lappend cat_json [format {"%s": {"slack": %s, "start": %s, "end": %s, "levels": %s, "logic_ns": %s, "route_ns": %s, "skew_ns": %s, "max_net_pins": %s}} \
    $cname [get_property SLACK $p] \
    [jstr [get_property NAME [get_property STARTPOINT_PIN $p]]] \
    [jstr [get_property NAME [get_property ENDPOINT_PIN $p]]] \
    [get_property LOGIC_LEVELS $p] [get_property DATAPATH_LOGIC_DELAY $p] \
    [get_property DATAPATH_NET_DELAY $p] [get_property SKEW $p] $max_fo]
  report_timing -from $from_cells -to $to_cells -max_paths 1 -input_pins \
    -file [file join $out_dir "category_paths.txt"] -append
}

set pass [expr {$wns >= 0.0 && $whs >= 0.0 && ($wpws eq "null" || $wpws >= 0.0) && $unrouted == 0 && $drc_errs == 0}]
set fh [open [file join $out_dir result.json] w]
puts $fh "{"
puts $fh "  \"variant_dir\": [jstr $variant_dir],"
puts $fh "  \"period_ns\": $period,"
puts $fh "  \"strategy\": [jstr $strategy],"
puts $fh "  \"vivado\": [jstr [version -short]],"
puts $fh "  \"part\": [jstr $part],"
puts $fh "  \"wns_ns\": $wns, \"tns_ns\": $tns, \"whs_ns\": $whs, \"wpws_ns\": $wpws,"
puts $fh "  \"route_error_nets\": $unrouted, \"drc_errors\": $drc_errs, \"drc_critical_warnings\": $drc_crit,"
puts $fh "  \"luts_total\": $luts, \"ffs_total\": $ffs, \"luts_core\": $core_luts, \"ffs_core\": $core_ffs,"
puts $fh "  \"pass\": [expr {$pass ? "true" : "false"}],"
puts $fh "  \"categories\": {\n    [join $cat_json ",\n    "]\n  },"
puts $fh "  \"paths\": \[\n    [join $path_json ",\n    "]\n  \]"
puts $fh "}"
close $fh
puts "RESULT period=$period wns=$wns whs=$whs wpws=$wpws pass=$pass"
