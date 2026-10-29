# Three-round model-weight stream experiment

## Folded absorption update October 21 2026

Branch `ascon-weight-stream-fold-absorb` adds the opt-in `G_FOLDED_ABSORB` core. The complete adapter takes 449,581 cycles per direction, about 4.50 ms at simulated 100 MHz, with exact authenticated recovery. Its steady interval is three clocks per full block. Saved core-only timing meets 100 MHz; a board-integrated copy also met 100 MHz in one run. No folded hardware programming or physical full-file measurement was performed.

Both legacy-engine defects are fixed here: empty-terminator AD framing receives mandatory padding, and the expected decryption tag is hidden. Historical results below retain their original source scope; they do not establish final patched legacy timing. See [the current report](../reports/Ascon%20weight%20stream%20bottlenecks.md), [the source ledger](../reports/Ascon%20source%20ledger.md), and [the fix note](ad_padding_fix.md).


Branch: `codex/ascon-weight-stream-3rpc`. This work starts from publication main
`3cceb3c5d3e610728a0876c18e5ebd8bd6af4aa0`, with selected unrolling changes from
the separate dirty experiment. That checkout and the existing detached worktree
are preserved. No training or merge is part of this experiment. The user authorized
publication of this branch and the updated research report on October 21, 2026.

## Complete adapter simulation at 100 MHz

The existing `runs/adapter_fp32_200/export/adapter_weights.bin` contains all
599,424 little-endian FP32 adapter values (2,397,696 bytes, no alignment padding).
The four tensor groups are `down_w`, `down_b`, `up_w`, and `up_b`. On October 20,
XSim verified the buffered candidate and a fresh GHDL run reproduced the earlier
one-round baseline on the same complete payload.

| Configuration | Cycles per direction | Simulated latency at 100 MHz | Payload MB/s |
|---|---:|---:|---:|
| Unchanged one-round baseline | 1,798,305 | 17.98305 ms | 133.331 |
| Three rounds with buffering and overlap | 899,153 | 8.99153 ms | 266.662 |

Both encryption and decryption passed reference ciphertext/tag parity,
authentication and commit, and exact byte recovery. The approximately 2x gain
combines unrolling and buffering; unrolling alone was not measured on this adapter.
Payload original/recovered SHA-256:
`c184175fc18d24373f009875c03698e630e8c36a5341146aab2bd13a98fff8eb`.
Preserving the original 20-byte format header reconstructs the checkpoint exactly;
the header is outside the exported weight payload. These are simulated 10 ns
clock results, not physical board throughput.

The research report's Section XIII and
[compact adapter evidence](../paper/evidence/adapter_100mhz_20261021/README.md)
record provenance, source hashes and verification. Reproduce with existing files:

```powershell
python verification/simulate_adapter.py <adapter_weights.bin> --manifest <export/manifest.json> --checkpoint <adapter_params_00000200.bin> --output build/adapter-new --nonce-base <unused-integer-range>
```

The new output directory must not exist. The runner tests unchanged `origin/main`
and the buffered candidate, at both 1 KiB and complete length, without training.
Allocate four unused nonces under the public test key for each invocation.

## Architecture references

The algorithm and required round counts come from
[NIST SP 800-232](https://csrc.nist.gov/pubs/sp/800/232/final).
[Primas's Ascon hardware](https://github.com/rprimas/ascon-verilog) provides
one-, two- and four-round variants that informed the earlier unrolling study.
[OpenTitan's design discussion](https://opentitan.org/book/hw/ip/ascon/doc/theory_of_operation.html)
explains unrolling tradeoffs and dependent-state limits; its masking constraints
also show why unhardened throughput does not imply protected throughput.
[LaForest's handshake rules](https://fpgacpu.ca/fpga/handshake.html) support the
FIFO ready/valid rationale. These sources motivate general techniques; the
three-round grouping, queues, launch overlap and measured results are local
implementation work. They are not third-party performance claims or copied FIFO RTL.

## Measured results (October 20, 2026)

All three configurations passed 2,178 official encrypt/decrypt checks and exact
recovery of the complete 1,641,984-byte payload. Encryption and decryption had
the same cycle counts in the full-file bench (empty AD, command acceptance
included, through done; host transfer time excluded).

| Configuration | 1 KiB cycles | Complete payload cycles | Core-only setup / hold at 100 MHz | LUTs / registers |
|---|---:|---:|---:|---:|
| Unchanged main, one round | 801 | 1,231,521 | +2.914 / +0.147 ns | 1,894 / 1,081 |
| Three rounds alone | 465 | 718,385 | +0.125 / +0.152 ns | 3,192 / 1,088 |
| Three rounds with FIFOs and launch overlap | 401 | 615,761 | +0.038 / +0.144 ns | 3,708 / 1,680 |

The buffered candidate halves long-payload cycles, with six clocks per full
16-byte block versus twelve in the baseline. Of those six clocks, three execute
round groups; request, completion and block-handling overhead remains. In a
separate 1 KiB traffic case with AD and periodic input gaps/output stalls, cycles
fell from 862 (three rounds alone) to 581 (buffered). Under always-ready traffic,
the queues add two clocks to first-output latency while improving sustained
block spacing from seven clocks to six. Queueing alone without launch overlap
left block spacing at seven clocks.

An earlier 100 MHz board trial failed at **-0.130 ns setup** (+0.039 ns hold).
Its worst path ran between state registers in the demo permutation: 9.961 ns
data delay, including 8.048 ns of routing. That trial predates the demo driver
fix and automatic demo suite; its source receipt and failed timing reports are
retained separately. No bitstream was generated from that failed trial.

The final board wrapper includes two cores (demo and self-test), automatic demo
checks and ILA. It used **9,503 LUTs and 6,510 registers** and closed at
**83.333 MHz**, with **+1.110 ns setup / +0.024 ns hold**. The 100 MHz input
reference remains unchanged; the MMCM output period is 12 ns. Core-only 100 MHz
closure does not establish board closure at that frequency, especially with
just 38 ps of candidate core setup margin.

Physical JTAG ILA captures show **done=1, pass=1, fail=0** for all **18 core
self-test cases and eight original demo vector/mode pairs**. Hardware counters
match simulation: **1,161 cycles** for the core suite and **274 cycles** for the
demo suite. The core suite's nominal duration is 13.932 us from the configured
clock; this is not a host-transfer latency measurement. Full-payload encryption
and recovery remain simulation evidence; hardware fixtures are bounded to 64
payload bytes. The demo input-driver regression fails vector 3 before the fix,
then passes all eight combinations with the corrected ready/valid handling.

The full-block mask specialization saved no clocks, increased area from 3,694
to 3,819 LUTs, and reduced setup slack from +0.204 to +0.030 ns in its controlled
experiment before the cleanup fix. It remains disabled in the candidate.

Repository CI commands and the added buffered checks passed locally, including
GHDL, Icarus and Verilator; no remote GitHub Actions run was launched. Older WSL
GHDL was used for simulation, while the installed OSS CAD Suite GHDL supplied
Verilog synthesis. Intermittent Vivado installation/generated-script load
failures were preserved; reported final routes completed successfully from
frozen RTL snapshots. The board's 100 MHz failure remains separately recorded.

[Machine-readable results and source hashes](evidence/weight_stream_3rpc/report.json),
[verification summary](evidence/weight_stream_3rpc/verification_summary.json), and
[physical capture](evidence/weight_stream_3rpc/hardware/decoded.json) accompany
this report. Raw simulator/Vivado projects, routed checkpoints and the bitstream
remain in this worktree's ignored `build/` directories.

## Configuration and interface

The public `ascon_aead128_core` ports are unchanged. Generics are:

| Generic | Default | Meaning |
|---|---:|---|
| `G_ROUNDS_PER_CYCLE` | 1 | Combinational round chain, supported values 1..12 |
| `G_BUFFERING_ENABLE` | false | Enable transaction-local input/output queues and overlap the p8 launch with output enqueue |
| `G_INPUT_FIFO_DEPTH` | 2 | Positive input queue capacity in 128-bit beats |
| `G_OUTPUT_FIFO_DEPTH` | 2 | Positive output queue capacity in 128-bit beats |
| `G_FULL_BLOCK_FAST_PATH` | false | Experimental full-keep mask specialization; disabled in the candidate |

Factor three executes p8 with constants B4..4B in groups 3+3+2 and p12 with
F0..4B in groups 3+3+3+3. No rounds are omitted. The original controller is
retained internally as `ascon_aead128_engine`; default bypass preserves its
external cycle behavior. Buffered mode launches p8 on the same edge that its
output register transfers into the output FIFO. This removes one launch cycle
per full payload block, without pipelining dependent permutation states.

Input beats include kind/keep/last. They may queue during initialization and
permutation, retaining order across AD/payload transitions. Input acceptance
closes after the final payload beat. Full FIFOs accept a replacement only when
a beat is removed on that edge. Empty FIFOs have no combinational fall-through.
Ready/valid outputs remain stable under stalls. Protocol errors abort the
transaction and invalidate queued beats; reset likewise cancels all traffic.
A new command requires `cmd_ready_o`, including the cleanup cycle after done.

Full aligned final AD and payload blocks still receive the standard mandatory
empty padding block. Partial final payload blocks are padded without p8 before
finalization. Neither alignment nor the fast-path switch changes the algorithm.

## Authentication contract

Every decryption output byte is **provisional**. Consumers must quarantine the
complete message outside this streaming core and publish it only on `commit_o`.
On `discard_o`, protocol error, or reset, erase that quarantine. Keep accepting
provisional bytes into quarantine; waiting for commit before asserting output
ready would deadlock this interface. A streaming
FIFO is not a complete-message authentication buffer.

The buffered wrapper permits tag input acceptance and tag output transfer only
after every queued payload beat has transferred. Thus authentication/commit
cannot race pending plaintext, and completion cannot erase pending ciphertext.
On a protocol error, discard may immediately cancel outstanding queued data.
The board self-test contains its own bounded quarantine and checks publication
only following commit, including rejected tags and other authenticated inputs.

## Reproducing checks

Run the commands from this worktree, using Python dependencies from
`verification/requirements.txt`. GHDL must support VHDL-2008; Verilog translation
also requires a GHDL build with `--out=verilog`. Cocotb 2 needs Verilator >=5.036.

```text
make vectors model-test permutation-test ghdl-test vhdl-textio-test weight-file-test board-selftest board-demo-test
make iverilog-lint verilator-lint
KAT_LIMIT=8 make iverilog-test verilator-test
python verification/run_permutation.py --rounds-per-cycle 3
python verification/run.py --rounds-per-cycle 3 --buffering --module test_stream
```

`test_stream` runs all 1089 official vectors in both directions by default,
concurrent producers/consumers, partial lengths, long stalls, input gaps,
malformed metadata, tampering and buffered reset recovery. `FULL_KAT=0` selects
an eight-vector smoke subset while retaining the added protocol tests. Runner
options `--input-depth`, `--output-depth` and `--fast-path` cover queue variants.
Generated buffered Verilog is also tested under Icarus and Verilator in CI.

For a new complete-payload comparison, use the existing export and manifest:

```powershell
python .\verification\compare_stream.py 'C:\Users\Symok\Downloads\ascon-aead128-vhdl-main\build\small_llama_20261013_01\trained_weights_fp32.bin' --manifest 'C:\Users\Symok\Downloads\ascon-aead128-vhdl-main\build\small_llama_20261013_01\tensor_manifest.json' --output .\build\comparison-new
```

The output directory must be new. The runner freezes each variant's sources,
uses raw `origin/main` RTL for the baseline, validates the FP32 tensor manifest,
checks all ciphertext, tag and recovered bytes, and records source hashes and
cycles. On Windows it invokes GHDL through the installed Ubuntu-22.04 WSL distro.
Use `--nonce-base` to allocate another independent range of public test nonces.
Official KATs necessarily retain their prescribed keys/nonces; altered-input
cases intentionally attempt authentication against an existing message.

The complete existing export is 1,641,984 bytes of little-endian FP32 tensors,
SHA-256 `d1c38f9b274368f989a3c578bb4880003ac821e57faee985ad5bd2841d80b594`.
The copied manifest identifies all 17 tensors (410,496 FP32 values), their shapes, byte offsets and lengths. The
1 KiB comparison uses the first 1024 bytes of that same export. This is existing
model-artifact evidence, not a new training run or an inference-speed claim.

## Board use and evidence

The board build targets Nexys A7-100T / `xc7a100tcsg324-1`, with a 100 MHz board
reference and an MMCM-generated core clock. The generated clock, demo, self-test
and optional debug instrumentation are included in board timing. Core-only
out-of-context results exclude package placement and external I/O delays.
Board buttons/switches enter synchronizers and are excluded as asynchronous UI
inputs; LEDs are unsampled indicators and excluded from synchronous I/O timing.
These exclusions do not exclude internal datapath timing.

- `BTNU` resets the self-test and demo. Self-test runs automatically after reset.
- `SW9=1` displays self-test results: LED8 done (both suites), LED9 pass (both suites), LED10 fail, LED12 clock locked.
- With SW3=0, SW1:0 selects bytes 0..3 of the latched total self-test cycle count on LED7:0.
- With SW3=1, LED7:0 displays the current/failing core case; 0x80..0x87 identifies an automatic demo failure.
- `SW9=0` selects the existing demo: SW1:0 selects its vector, SW2 selects decrypt,
  BTNC starts it, SW3 selects tag display, and SW7:4 selects the displayed byte.
  The original demo's LED meanings apply in this mode.

At startup, the hardware also runs all four original demo vectors in both
encryption and decryption mode. The automatic driver checks the demo's done/pass/fail
indicators, then returns switches and BTNC to manual control. The demo now holds
input valid and metadata until ready/valid acceptance; the previous driver lost
vector 3 beats under backpressure. A regression test reproduces that failure
before the fix and checks all eight combinations after it. ILA records the
automatic demo result and its separate cycle counter.

Self-test fixtures include empty/full/partial messages and AD, tampered tag,
nonce, AD and ciphertext, long periodic output stalls, input gaps, queue
saturation and an initial reset-aborted transaction. All keys/nonces are public
fixtures. Distinct encryption fixtures and the aborted transaction have distinct
nonces. Readonly fixture bytes are generated by `verification/generate_selftest.py`.

A short Windows launcher freezes sources and preserves each run:

```powershell
python .\verification\build_weight_board.py --output .\build\board-new --clock-divide 12 --program
```

Omit `--program` for implementation only. The program stage captures and checks
both the 18-case core self-test and all eight original demo combinations.

`vivado/discover_weight_board.tcl` identifies the connected device without
programming it. `route_weight_board.tcl` takes output directory, worktree root
and clock divider (10 = 100 MHz; 12 = 83.333 MHz; 20 = 50 MHz). It refuses to
write a bitstream when routed setup or hold slack is negative.
`program_weight_board.tcl` programs volatile configuration only and captures the
latched self-test result through ILA. Programming receipts are separate from
physical functional captures. No configuration flash is written.

`retime_weight_board.tcl` can reopen the routed board checkpoint, lower the MMCM
output clock, verify the generated period changed, and rerun placement/routing.
The clock override and source checkpoint are recorded explicitly; the RTL
remains identical. A passing implementation is required before bitstream output.

Physical full-weight streaming needs an added transport; this branch tests the
complete weight payload in simulation and bounded self-test fixtures on hardware.

## Remaining experiments

One message remains state-dependent. Multiple independent lanes require separate
states, keys/nonces/tags, transaction tracking, buffering and bandwidth arbitration.
A memory burst interface requires a DMA/bus adapter and memory controller beyond
this core's existing 128-bit ready/valid ports. Lossless compression requires a
codec, metadata/framing, decompression and exact-reconstruction checks; its ratio
must be measured on these actual tensor bytes. None is included in this branch.

After measuring controller overhead and timing, deeper research could resolve
whether scheduling block absorption directly on permutation completion offers
more throughput without extending the critical path. That is a subsequent
experiment, particularly if the three-round timing margin is small.
