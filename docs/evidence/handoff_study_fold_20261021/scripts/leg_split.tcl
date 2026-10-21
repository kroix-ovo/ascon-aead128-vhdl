# leg_split.tcl DCP OUT : separate state->state paths by logic depth.
# 7-level paths = 3-round chain (6 LUT levels) + final D-mux; <=6-level state->state paths into
# rate bits are the 2-round tail + absorb leg (or the XOR-only leg).
open_checkpoint [lindex $argv 0]
set out [lindex $argv 1]
set st [get_cells -hier -filter {NAME =~ *fold_u/s_reg_reg[*]}]
set f [open $out w]
set paths [get_timing_paths -delay_type max -from $st -to [get_pins -of $st -filter {REF_PIN_NAME==D}] -max_paths 20000 -nworst 40]
array set best {}
foreach p $paths {
  set l [get_property LOGIC_LEVELS $p]
  set s [get_property SLACK $p]
  if {![info exists best($l)] || $s < [lindex $best($l) 0]} {
    set best($l) [list $s [get_property DATAPATH_DELAY $p] [get_property DATAPATH_LOGIC_DELAY $p] [get_property DATAPATH_NET_DELAY $p] [get_property STARTPOINT_PIN $p] [get_property ENDPOINT_PIN $p] $p]
  }
}
puts $f "state->state worst path per logic-level count (from [llength $paths] enumerated paths, up to 40 per endpoint)"
foreach l [lsort -integer [array names best]] {
  lassign $best($l) s d lg nt sp ep p
  puts $f [format "levels=%d slack=%.3f datapath=%.3f logic=%.3f route=%.3f %s -> %s" $l $s $d $lg $nt $sp $ep]
  set cells {}
  foreach c [get_cells -of $p] { lappend cells [get_property REF_NAME $c] }
  puts $f "    cells: $cells"
}
close $f
