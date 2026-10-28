# Args: implementation, new capture directory, expected Digilent serial.
# Volatile FPGA programming only; never writes flash.
set impl [file normalize [lindex $argv 0]]
set out [file normalize [lindex $argv 1]]
set serial [lindex $argv 2]
file mkdir $out
open_hw_manager
connect_hw_server -allow_non_jtag
set targets [get_hw_targets *$serial]
if {[llength $targets]!=1} {error "Expected Digilent serial not unique"}
open_hw_target [lindex $targets 0]
set devices [get_hw_devices -filter {PART == xc7a100t}]
if {[llength $devices]!=1} {error "Expected exactly one XC7A100T"}
set device [lindex $devices 0]
current_hw_device $device
set_property PROGRAM.FILE [file join $impl selftest.bit] $device
set_property PROBES.FILE [file join $impl selftest.ltx] $device
set_property FULL_PROBES.FILE [file join $impl selftest.ltx] $device
program_hw_devices $device
refresh_hw_device $device
set ilas [get_hw_ilas -of_objects $device]
if {[llength $ilas]!=1} {error "Expected one multicore ILA"}
set ila [lindex $ilas 0]
run_hw_ila -trigger_now $ila
wait_on_hw_ila -timeout 30 $ila
set data [upload_hw_ila_data $ila]
write_hw_ila_data -csv_file [file join $out capture.csv] $data
set f [open [file join $out device.txt] w]
puts $f "TARGET=[lindex $targets 0] DEVICE=$device PART=[get_property PART $device]"
puts $f "PROGRAMMED=[file join $impl selftest.bit]"
puts $f "PROBE_BITS=done:0,pass:1,fail:2,case:6:3,failure:14:7,passed:24:15,cycles:344:25"
close $f
close_hw_target
close_hw_manager
