# Verification status

Last updated: September 18, 2026.

## Portable verification

The independent Python model passed its official-vector boundary checks. The
permutation test compared the VHDL state with the model after every round of
p12 and p8. The direct GHDL run passed all 1,089 official vectors in encryption
and decryption, followed by nine protocol, reset, authentication, zeroization,
and fixed-seed differential test groups.

The pure VHDL TextIO bench ran all 1,089 vectors in both directions. Its 2,178
checks passed. Command-to-done latency ranged from 34 cycles for empty
associated data and an empty message to 88 cycles when both lengths were 32
bytes. Across the 33 associated-data lengths, a 32-byte payload averaged
72.636 cycles. That is 352.441 Mb/s when evaluated at the target 100 MHz clock.
It is a cycle-based simulation result, not a measured maximum clock frequency.

GHDL synthesis accepted both the reusable core and the Nexys A7 wrapper. The
GHDL-generated Verilog passed the complete 1,089-vector encryption and
decryption run with Icarus Verilog 13.0 and Verilator 5.048. The short generated
netlist targets remain available for CI, and the `full-icarus-kat` and
`full-verilator-kat` targets reproduce the complete runs.

The corrected Dockerfile copies the repository and runs all portable smoke
paths plus the full TextIO bench. Docker Desktop was not running during the
September 17 portable verification, so that local Docker image was not built.
GitHub Actions exercises the corresponding Ubuntu paths.

## Vivado XSim

Vivado 2023.2 ran the same pure VHDL TextIO bench on Windows. XSim completed
all 1,089 official vectors in encryption and decryption. All 2,178 directional
checks passed with no failures. The durable files are:

- `build/vivado/simulation/simulation_results.txt`;
- `build/vivado/simulation/simulation_vectors.txt`.

The XSim run reproduced the 34-to-88-cycle latency range and the 72.636-cycle
mean for a 32-byte payload across all associated-data lengths.

## Vivado implementation

Vivado 2023.2 completed synthesis, placement, routing, timing analysis, power
estimation, and bitstream generation for `xc7a100tcsg324-1`.

| Measurement | Result |
|---|---:|
| Clock constraint | 100 MHz |
| Setup failing endpoints | 0 |
| Worst setup slack | +2.941 ns |
| Hold failing endpoints | 0 |
| Worst hold slack | +0.117 ns |
| Slice LUTs | 1,717 (2.71%) |
| Slice registers | 1,372 (1.08%) |
| Block RAM tiles | 0 |
| DSP blocks | 0 |
| Estimated dynamic power | 0.040 W |
| Estimated static power | 0.097 W |
| Estimated total on-chip power | 0.137 W |
| Bitstream | Generated successfully |

The XDC sets `CFGBVS VCCO` and `CONFIG_VOLTAGE 3.3` for the Nexys A7
configuration bank. A fresh routed DRC reported zero violations, confirming
that the earlier `CFGBVS-1` warning is resolved.
The power figures are Vivado estimates and have not been measured on the board.

## Security scope

The current core is intentionally unmasked. It does not implement side-channel
masking, redundant execution, or fault detection. The verification results
establish functional behavior and protocol handling; they do not establish
resistance to power analysis, electromagnetic analysis, or injected faults.

## Remaining hardware work

The generated bitstream has not yet been programmed onto the Nexys A7. The
remaining release evidence is:

- program the Nexys A7 100T with the generated bitstream;
- run the empty, partial, full-block, and 17-byte demonstrations;
- record the LED results for encryption and decryption;
- confirm reset and repeated-start behavior on the physical board;
- measure board power if a measured value is required.
