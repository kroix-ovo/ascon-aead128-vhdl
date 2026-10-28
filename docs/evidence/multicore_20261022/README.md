# Multicore evidence, October 22 2026

These are fresh local measurements from the isolated `codex/ascon-fold-multicore`
worktree based on `d304a7b`. Per-file hashes identify the tested working-tree
sources; the base commit alone does not contain the new implementation.

| Receipt | Scope |
|---|---|
| `sim_default.json` | Complete adapter, 1/2/4 cores, six traffic profiles, encrypt/decrypt: 36 passing runs |
| `sim_registered.json` | Same 36-run matrix with registered-ready input/output boundary queues |
| `sim_local_control.json` | Complete adapter, ideal service, all core counts, both directions, boundary queues and local key/control registers: six passing runs |
| `security_ghdl.json` | 129 passing direct-VHDL scenarios with boundary queues and local control |
| `security_verilator.json` | Same 129 scenarios using GHDL-synthesized behavioral Verilog in Verilator |
| `cross_core_compatibility.json` | One saved encrypted adapter decrypted on 1, 2, and 4 cores, with exact original-file reconstruction |
| `wholefile.json` | Fresh original-u1, buffered-u3 and folded whole-file comparisons, 1 KiB and complete payload, both directions |
| `multicore-fold-ascon.txt` | Current folded entity: full official KAT grid and twelve protocol/security test groups |
| `multicore-fold-stream.txt` | Current folded entity: concurrent stream regression |
| `multicore-fold-intermediate.txt` | Current folded entity: intermediate round groups and queued-error rejection |

The two 129-scenario receipts have identical metric dictionaries scenario by
scenario. Each includes 36 normal traffic runs, 51 rejection/reset cases, and
42 partial-length/skewed-lane cases. Partial chunk lengths are 1, 15, 16, 17, 31,
32 and 33 bytes. Normal traffic includes ideal service, source gaps, sink stalls,
seeded bursts, and 1.0/1.3 GB/s aggregate memory-service assumptions.

Fault IDs 1–17 test: first-layer bad tag; changed ciphertext; wrong chunk ID;
wrong offset; noncontiguous keep; replayed chunk ID; missing final chunk followed
by host timeout/abort; explicit abort; reset during traffic; wrong model ID;
swapped tags; nonce overflow; wrong manifest ID; wrong file nonce context;
swapped complete ciphertext/tag chunks; premature payload-last; and a bad tag on
the final layer. The last case checks whole-file discard after earlier chunks
can already have authenticated. Failed and reset cases release no output file.

Every normal full-file run compares each RTL payload beat to the Python
reference; encryption runs also compare all tags. Each decryption run verifies
the complete recovered weights and reconstructs the original checkpoint exactly.
The two full matrices contain 72 directional runs, including 36 decryption
checkpoint reconstructions. The original payload SHA-256 is
`c184175fc18d24373f009875c03698e630e8c36a5341146aab2bd13a98fff8eb`.
The checkpoint SHA-256 is
`7c45c25b28ae54943c1fd4ee160001dcd9a68ee1f8430aee229f933545672de6`.
The manifest was read from the existing FP32 adapter export. No training ran.

The historical baseline in `wholefile.json` is pinned to
`3cceb3c5d3e610728a0876c18e5ebd8bd6af4aa0`. Its RTL differs from the patched folded
branch. Baseline ciphertext and recovery comparisons do not establish that old
RTL has the later AD-framing and tag-output security fixes.

Each run keeps its own frozen source snapshot in the corresponding build/scratch
directory. The compact bundle contains measurements, hashes, commands and test
logs; raw vectors, weight binaries, compiled simulators and routed checkpoints
remain outside this bundle. RTL hashes in the full-file and security receipts
match the final implementation. The test drivers were extended with additional
negative cases after some full-file runs; their individual driver hashes retain
that distinction.

Timing receipts and selected report text are stored under `timing-n1/`,
`timing-n2/`, and `timing-n4/`. Raw routes
remain in `build/multicore-final-timing-n*/`. The comparison document reports
internal register-to-register setup/hold separately from the nominal zero-delay
OOC package-port checks. No physical board/file measurement or bitstream
programming is represented here.

Selected internal timing passes at 100 MHz for one and two cores with boundary
queues, and at 90 MHz for four cores with boundary queues, local control and
Pblocks. The four-core sequence stopped at 90 MHz; the 83.333 MHz fallback was
not needed. All saved attempts have zero routing errors and zero unconstrained
internal endpoints. The passing setup margins are 0.004, 0.012 and 0.060 ns.
