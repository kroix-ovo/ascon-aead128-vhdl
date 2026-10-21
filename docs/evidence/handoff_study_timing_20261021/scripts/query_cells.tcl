open_checkpoint [lindex $argv 0]
set f [open [lindex $argv 1] w]
set p [get_timing_paths -delay_type max -max_paths 1]
foreach c [get_cells -of $p] {
  if {[get_property PRIMITIVE_GROUP $c] ne "LUT"} continue
  puts $f "== $c [get_property REF_NAME $c] INIT=[get_property INIT $c]"
  foreach pin [lsort [get_pins -of $c -filter {DIRECTION==IN}]] {
    set n [get_nets -of $pin]
    set drv [get_cells -of [get_pins -of $n -filter {DIRECTION==OUT}]]
    puts $f "   [get_property REF_PIN_NAME $pin] <- net $n (fo=[get_property FLAT_PIN_COUNT $n]) driver $drv"
  }
}
close $f
