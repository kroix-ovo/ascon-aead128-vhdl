# Selected completed route directories. Check IP bus-skew constraints separately
# from ordinary setup/hold, as requested by Vivado's timing-summary warning.
set_param general.maxThreads 2
foreach directory $argv {
  set directory [file normalize $directory]
  open_checkpoint [file join $directory routed.dcp]
  report_bus_skew -file [file join $directory bus_skew.txt]
  close_design
}
