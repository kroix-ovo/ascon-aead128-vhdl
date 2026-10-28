# Publication verification on October 28 2026

The seven pipeline variants each pass 2,178 official directional checks, 400
per-round runs and 520 transactions in each streaming mode on the measured
sources. The totals are in pipeline_regression.json. Fresh execution used
GHDL in Ubuntu 22.04 through WSL, with outputs in a new ignored build directory.
The original simulation and routed evidence remains unchanged.

synthetic_multicore_security.json records 129 passing direct-VHDL scenarios
for 1/2/4 cores with registered boundaries and local control, including security
faults and partial-length/skewed-lane cases. The default synthetic chunks are
256 bytes each. This rerun is not a full-adapter test or a new physical test.
Reproduce with verification/run_multicore.py --registers --local-control
--security --edge-cases --nonce-base <fresh-synthetic-base> --output <new-dir>.

All pipeline source hashes were checked against the saved provenance and all
available board source hashes against the three board receipts. Git attributes
preserve the exact measured source/evidence bytes across platforms. The report
was built and all 25 rendered pages reviewed; the three new diagrams use the
repository Matplotlib primitives. Timing sweeps and physical captures were not
rerun for this publication.
