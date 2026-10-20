# Read-only device discovery. Does not configure the FPGA.
open_hw_manager
connect_hw_server -allow_non_jtag
set targets [get_hw_targets]
puts "ASCON_TARGETS=$targets"
foreach target $targets {
 open_hw_target $target
 foreach d [get_hw_devices] {puts "ASCON_DEVICE=$d PART=[get_property PART $d]"}
 close_hw_target
}
close_hw_manager
