# Program volatile FPGA configuration and capture latched physical selftest.
# Args: implemented directory, output directory. Never writes configuration flash.
set impl [file normalize [lindex $argv 0]]
set out [file normalize [lindex $argv 1]]
file mkdir $out
open_hw_manager
connect_hw_server -allow_non_jtag
set targets [get_hw_targets *210292ABF1AAA]
if {[llength $targets] != 1} {error "Expected connected Digilent target was not found uniquely"}
open_hw_target [lindex $targets 0]
set devices [get_hw_devices -filter {PART == xc7a100t}]
if {[llength $devices] != 1} {error "Expected one XC7A100T device"}
set device [lindex $devices 0]
current_hw_device $device
set_property PROGRAM.FILE [file join $impl selftest.bit] $device
set_property PROBES.FILE [file join $impl selftest.ltx] $device
set_property FULL_PROBES.FILE [file join $impl selftest.ltx] $device
program_hw_devices $device
refresh_hw_device $device
set ilas [get_hw_ilas -of_objects $device]
if {[llength $ilas] != 1} {error "Expected one selftest ILA"}
set ila [lindex $ilas 0]
run_hw_ila -trigger_now $ila
wait_on_hw_ila -timeout 30 $ila
set data [upload_hw_ila_data $ila]
write_hw_ila_data -csv_file [file join $out capture.csv] $data
set f [open [file join $out device.txt] w]
puts $f "TARGET=[lindex $targets 0] DEVICE=$device PART=[get_property PART $device]"
puts $f "PROGRAMMED=[file join $impl selftest.bit]"
puts $f "ILA=$ila PROBE_BITS=done:0,pass:1,fail:2,case:10:3,cycles:42:11,auto_done:43,auto_pass:44,auto_fail:45,auto_case:48:46,auto_cycles:80:49"
close $f
close_hw_target
close_hw_manager
