# analyze_fold.tcl DCP OUTDIR : path-class breakdown of a routed G_FOLDED_ABSORB core checkpoint.
# Adapted (read-only reuse) from build/handoff_vivado/scripts/analyze_dcp.tcl for the fold cell names.
set dcp [lindex $argv 0]; set out [lindex $argv 1]; file mkdir $out
open_checkpoint $dcp
set f [open [file join $out path_classes.txt] w]
proc cls {f name from to {through {}}} {
  set args [list -delay_type max -max_paths 1]
  if {$from ne ""} {lappend args -from $from}
  if {$to ne ""} {lappend args -to $to}
  if {$through ne ""} {lappend args -through $through}
  if {[catch {set p [get_timing_paths {*}$args]} e]} {puts $f [format "%-44s error: %s" $name $e]; return}
  if {[llength $p]==0} {puts $f [format "%-44s none" $name]; return}
  if {[get_property SLACK $p] eq ""} {puts $f [format "%-44s UNCONSTRAINED levels=%s datapath=%s start=%s end=%s" $name [get_property LOGIC_LEVELS $p] [get_property DATAPATH_DELAY $p] [get_property STARTPOINT_PIN $p] [get_property ENDPOINT_PIN $p]]; return}
  puts $f [format "%-44s slack=%7.3f levels=%2d datapath=%6.3f logic=%6.3f route=%6.3f start=%s end=%s" $name \
    [get_property SLACK $p] [get_property LOGIC_LEVELS $p] [get_property DATAPATH_DELAY $p] \
    [get_property DATAPATH_LOGIC_DELAY $p] [get_property DATAPATH_NET_DELAY $p] [get_property STARTPOINT_PIN $p] [get_property ENDPOINT_PIN $p]]
}
set st   [get_cells -hier -filter {NAME =~ *fold_u/s_reg_reg[*]}]
set rate {}; set cap {}
foreach c $st { regexp {\[(\d+)\]$} [get_property NAME $c] -> i; if {$i < 128} {lappend rate $c} else {lappend cap $c} }
set rc   [get_cells -hier -filter {NAME =~ *fold_u/rc*_reg*}]
set ctl  [get_cells -hier -filter {(NAME =~ *fold_u/fsm_reg* || NAME =~ *fold_u/grp_reg* || NAME =~ *fold_u/*pend_reg* || NAME =~ *fold_u/ad_*_reg* || NAME =~ *fold_u/msg_last_reg* || NAME =~ *fold_u/dec_reg_reg* || NAME =~ *fold_u/closed_reg*)}]
set iq   [get_cells -hier -filter {NAME =~ *fold_u/iq_reg*}]
set head [get_cells -hier -filter {NAME =~ *fold_u/iq_reg[0]*}]
set oq   [get_cells -hier -filter {NAME =~ *fold_u/oq_reg*}]
set cnt  [get_cells -hier -filter {(NAME =~ *fold_u/ic_reg* || NAME =~ *fold_u/oc_reg*)}]
set key  [get_cells -hier -filter {NAME =~ *fold_u/key_reg_reg*}]
set stat [get_cells -hier -filter {(NAME =~ *fold_u/auth*_reg* || NAME =~ *fold_u/commit_reg* || NAME =~ *fold_u/discard_reg* || NAME =~ *fold_u/error_reg* || NAME =~ *fold_u/done_reg*)}]
puts $f "counts: state=[llength $st] rate=[llength $rate] cap=[llength $cap] rc=[llength $rc] ctl=[llength $ctl] iq=[llength $iq] head=[llength $head] oq=[llength $oq] cnt=[llength $cnt] key=[llength $key] stat=[llength $stat]"
cls $f "ALL" "" ""
cls $f "state -> state (rounds; R3 or tail leg)" $st $st
cls $f "state -> rate bits of state" $st $rate
cls $f "state -> capacity bits of state" $st $cap
cls $f "rc regs -> state (round constants)" $rc $st
cls $f "ctl/flags -> state (leg select, operands)" $ctl $st
cls $f "queue head -> state (absorb operand)" $head $st
cls $f "queue counts -> state (absorb gating)" $cnt $st
cls $f "key -> state (key XOR terms)" $key $st
cls $f "state -> output queue (ciphertext/plaintext tap)" $st $oq
cls $f "queue head -> output queue" $head $oq
cls $f "any -> input queue" "" $iq
cls $f "any -> ctl/flags" "" $ctl
cls $f "any -> queue counts" "" $cnt
cls $f "any -> rc regs" "" $rc
cls $f "state/key -> status (tag compare)" "" $stat
cls $f "input ports -> any" [get_ports -filter {DIRECTION==IN && NAME!=clk_i}] ""
cls $f "any -> output ports" "" [all_outputs]
cls $f "input ports -> output ports" [get_ports -filter {DIRECTION==IN && NAME!=clk_i}] [all_outputs]
close $f
# Endpoint slack histogram for state-register D pins and level histogram of the top state paths.
set f [open [file join $out state_endpoint_hist.txt] w]
set paths [get_timing_paths -delay_type max -to [get_pins -of $st -filter {REF_PIN_NAME==D}] -max_paths 320 -nworst 1]
array set h {}; array set lv {}
foreach p $paths {
  set b [expr {floor([get_property SLACK $p] * 4) / 4.0}]
  if {[info exists h($b)]} {incr h($b)} else {set h($b) 1}
  set l [get_property LOGIC_LEVELS $p]
  if {[info exists lv($l)]} {incr lv($l)} else {set lv($l) 1}
}
puts $f "worst-path slack per state D endpoint (bin = floor to 0.25 ns): count"
foreach b [lsort -real [array names h]] {puts $f "  $b : $h($b)"}
puts $f "logic levels of those worst paths: count"
foreach l [lsort -integer [array names lv]] {puts $f "  $l : $lv($l)"}
close $f
report_timing -delay_type max -max_paths 3 -from $head -to $st -file [file join $out head_to_state_paths.txt]
report_timing -delay_type max -max_paths 3 -from $st -to $oq -file [file join $out state_to_outq_paths.txt]
report_timing -delay_type max -max_paths 3 -from $ctl -to $st -file [file join $out ctl_to_state_paths.txt]
report_design_analysis -logic_level_distribution -logic_level_dist_paths 1000 -file [file join $out logic_levels.txt]
report_utilization -hierarchical -file [file join $out utilization_hier.txt]
report_high_fanout_nets -max_nets 20 -file [file join $out high_fanout.txt]
