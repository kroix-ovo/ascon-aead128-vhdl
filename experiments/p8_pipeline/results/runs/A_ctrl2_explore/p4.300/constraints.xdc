## Pins for the p8 timing harness on the Nexys A7-100T (xc7a100tcsg324-1).
## The clock period is appended per run by scripts/impl_one.tcl.
##
## BTNC is an asynchronous push button sampled by a two-flop synchronizer and
## LED[0] is a static indicator.  Neither has input/output delay constraints,
## so check_timing lists them as unconstrained I/O.  No core path depends on
## them and no timing exception is applied anywhere in this experiment.

set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

set_property -dict { PACKAGE_PIN E3  IOSTANDARD LVCMOS33 } [get_ports CLK100MHZ]
set_property -dict { PACKAGE_PIN N17 IOSTANDARD LVCMOS33 } [get_ports BTNC]
set_property -dict { PACKAGE_PIN H17 IOSTANDARD LVCMOS33 } [get_ports {LED[0]}]

create_clock -name sys_clk_pin -period 4.300 [get_ports CLK100MHZ]
