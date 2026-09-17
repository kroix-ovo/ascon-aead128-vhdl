# Verification status

Last portable run: September 17, 2026 on macOS.

The independent Python model passed its official-vector boundary checks. The
permutation test compared the VHDL state with the model after every round of
p12 and p8. The direct GHDL run passed all 1,089 official vectors in encryption
and decryption, followed by nine protocol, reset, authentication, zeroization,
and fixed-seed differential test groups.

The pure VHDL TextIO bench also ran all 1,089 vectors in both directions. Its
2,178 checks passed, and it produced `simulation_results.txt` and
`simulation_vectors.txt` under `build/ghdl-textio`. Command-to-done latency
ranged from 34 cycles for empty associated data and an empty message to 88
cycles when both lengths were 32 bytes. Across the 33 associated-data lengths,
a 32-byte payload averaged 72.636 cycles. That is 352.441 Mb/s when the cycle
count is evaluated at the target 100 MHz clock. It is not a post-route maximum
frequency measurement.

GHDL synthesis accepted both the reusable core and the Nexys A7 wrapper. The
GHDL-generated Verilog passed the complete 1,089-vector encryption and
decryption run with Icarus Verilog 13.0 and Verilator 5.048. The short generated
netlist targets remain available for CI, and the `full-icarus-kat` and
`full-verilator-kat` targets reproduce the complete runs.

The corrected Dockerfile copies the repository and runs all portable smoke
paths plus the full TextIO bench. Docker Desktop was not running during this
verification, so the image itself has not been built locally.

The following work still requires a Vivado 2023.2 installation:

- all 1,089 vectors in both directions under XSim;
- post-synthesis and post-route resource reports;
- non-negative post-route setup slack for the 10 ns clock;
- power, RAM, clock, and clock-network reports;
- bitstream generation and programmed-board testing.

No Vivado utilization, timing, or power value in this repository should be
treated as measured until `vivado/run_impl.tcl` has produced the checked reports
and `verification/summarize_results.py` marks the Vivado metrics complete.
