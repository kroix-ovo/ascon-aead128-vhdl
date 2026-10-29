# analyze_dcp.tcl DCP OUTDIR : path-class breakdown of a routed core checkpoint
set dcp [lindex $argv 0]; set out [lindex $argv 1]; file mkdir $out
open_checkpoint $dcp
set f [open [file join $out path_classes.txt] w]
proc cls {f name from to {through {}}} {
  set args [list -delay_type max -max_paths 1]
  if {$from ne ""} {lappend args -from $from}
  if {$to ne ""} {lappend args -to $to}
  if {$through ne ""} {lappend args -through $through}
  if {[catch {set p [get_timing_paths {*}$args]} e]} {puts $f [format "%-45s error: %s" $name $e]; return}
  if {[llength $p]==0} {puts $f [format "%-45s none" $name]; return}
  if {[get_property SLACK $p] eq ""} {puts $f [format "%-45s UNCONSTRAINED levels=%s datapath=%s start=%s end=%s" $name [get_property LOGIC_LEVELS $p] [get_property DATAPATH_DELAY $p] [get_property STARTPOINT_PIN $p] [get_property ENDPOINT_PIN $p]]; return}
  puts $f [format "%-45s slack=%7.3f levels=%2d datapath=%6.3f logic=%6.3f route=%6.3f start=%s end=%s" $name \
    [get_property SLACK $p] [get_property LOGIC_LEVELS $p] [get_property DATAPATH_DELAY $p] \
    [get_property DATAPATH_LOGIC_DELAY $p] [get_property DATAPATH_NET_DELAY $p] [get_property STARTPOINT_PIN $p] [get_property ENDPOINT_PIN $p]]
}
set perm [get_cells -hier -filter {NAME =~ *permutation_u/state_reg_reg[*]}]
set rnd  [get_cells -hier -filter {NAME =~ *permutation_u/round_number_reg_reg*}]
set pbusy [get_cells -hier -filter {NAME =~ *permutation_u/busy_reg_reg*}]
set eng  [get_cells -hier -filter {NAME =~ *engine*/state_reg_reg[*] && NAME !~ *permutation_u*}]
set ctl  [get_cells -hier -filter {NAME =~ *controller_state_reg*}]
set fifo [get_cells -hier -filter {(NAME =~ *iq_reg* || NAME =~ *oq_reg* || NAME =~ *ir_reg* || NAME =~ *iw_reg* || NAME =~ *orp_reg* || NAME =~ *ow_reg* || NAME =~ *ic_reg* || NAME =~ *oc_reg*)}]
set outd [get_cells -hier -filter {NAME =~ *out_data_reg_reg*}]
set key [get_cells -hier -filter {NAME =~ *key_reg_reg*}]
set tag [get_cells -hier -filter {NAME =~ *tag_reg_reg*}]
puts $f "counts: perm=[llength $perm] rnd=[llength $rnd] eng=[llength $eng] ctl=[llength $ctl] fifo=[llength $fifo] outd=[llength $outd]"
cls $f "ALL" "" ""
cls $f "perm.state -> perm.state (round datapath)" $perm $perm
cls $f "perm.round_number -> perm.state (RC/guard)" $rnd $perm
cls $f "perm.busy -> perm.state" $pbusy $perm
cls $f "eng.state -> perm.state (load mux)" $eng $perm
cls $f "ctl -> perm.state (start/load select)" $ctl $perm
cls $f "perm.state -> eng.state (writeback/key xor)" $perm $eng
cls $f "eng.state -> eng.state (absorb)" $eng $eng
cls $f "fifo -> eng.state (absorb from FIFO head)" $fifo $eng
cls $f "fifo -> out_data (encrypt/decrypt output)" $fifo $outd
cls $f "eng.state -> out_data" $eng $outd
cls $f "ctl -> eng.state" $ctl $eng
cls $f "any -> ctl" "" $ctl
cls $f "any -> fifo" "" $fifo
cls $f "perm.state -> tag" $perm $tag
cls $f "any -> key" "" $key
cls $f "input ports -> any" [get_ports -filter {DIRECTION==IN && NAME!=clk_i}] ""
cls $f "any -> output ports" "" [all_outputs]
cls $f "input ports -> output ports" [get_ports -filter {DIRECTION==IN && NAME!=clk_i}] [all_outputs]
close $f
# per-endpoint slack histogram for perm state endpoints
set f [open [file join $out perm_endpoint_hist.txt] w]
set paths [get_timing_paths -delay_type max -to [get_pins -of $perm -filter {REF_PIN_NAME==D}] -max_paths 400 -nworst 1]
array set h {}
foreach p $paths { set b [expr {int(floor([get_property SLACK $p]/0.25))}]; if {![info exists h($b)]} {set h($b) 0}; incr h($b) }
puts $f "perm state endpoints: [llength $paths] (worst path per endpoint), slack buckets of 0.25 ns:"
foreach b [lsort -integer [array names h]] { puts $f [format "  %6.2f..%6.2f : %d" [expr {$b*0.25}] [expr {($b+1)*0.25}] $h($b)] }
close $f
report_timing -delay_type max -from $rnd -to $perm -max_paths 3 -file [file join $out rnd_to_perm.txt]
report_timing -delay_type max -from $fifo -to $eng -max_paths 3 -file [file join $out fifo_to_eng.txt]
report_timing -delay_type max -from $perm -to $eng -max_paths 2 -file [file join $out perm_to_eng.txt]
report_timing -delay_type max -to $ctl -max_paths 2 -file [file join $out to_ctl.txt]
