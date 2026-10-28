# Layer-chunk format and multicore interface, version 1

This experimental wrapper uses the existing folded NIST Ascon-AEAD128 engine.
It supports 1, 2, or 4 cores and exactly twelve independently authenticated
chunks. The original single-core public interface is unchanged. Optional
observation outputs were added to the internal folded entity, with defaults so
existing instantiations remain valid. No permutation equations changed.

## Adapter mapping

The validated FP32 export has twelve layers, 768 channels, and rank 32. Its
2,397,696 bytes are stored in four tensor groups. Chunk `i` gathers layer `i` in
this order:

| Tensor slice | Bytes | Chunk offset | Original file offset |
|---|---:|---:|---|
| down_w | 98,304 | 0 | `98,304*i` |
| down_b | 128 | 98,304 | `1,179,648 + 128*i` |
| up_w | 98,304 | 98,432 | `1,181,184 + 98,304*i` |
| up_b | 3,072 | 196,736 | `2,360,832 + 3,072*i` |

Each chunk is 199,808 bytes, or 12,488 sixteen-byte payload beats. The runner
derives this mapping from the manifest, validates shapes, contiguous coverage,
payload length and SHA-256, and reverses the mapping after authenticated
decryption. The optional checkpoint must match its saved SHA-256 and exact body.

Lane `i mod N` processes chunk `i`. A lane handles one message at a time; it
starts its next chunk only after its current message completes and its output
boundary drains. Thus each core handles 12/N complete chunks with no cross-core
Ascon state sharing. Identical work assignments do not eliminate bus stalls.

Core count is not authenticated into the format. A saved ciphertext/tag set can
be decrypted with a different supported core count by changing only the lane
assignment. The cross-core compatibility test checks one saved encrypted adapter
on all three core counts.

## Authenticated metadata

Each chunk uses its own 128-bit nonce, `file_nonce_base + chunk_index`, encoded
little endian. A base larger than `2^128 - 12` is rejected before starting any
core. The caller supplies a fresh range for each independent encryption file
under a key; the RTL does not maintain persistent nonce allocation across resets.
The runners use the public test key `000102030405060708090a0b0c0d0e0f` and record
their ranges. This test key is not key provisioning for a deployed product.

Associated data is exactly 96 bytes:

| Byte offset | Length | Encoding |
|---|---:|---|
| 0 | 4 | Version 1, uint32 little endian |
| 4 | 4 | Layer/chunk index, uint32 little endian |
| 8 | 4 | Chunk count 12, uint32 little endian |
| 12 | 4 | Chunk payload length, uint32 little endian |
| 16 | 32 | Model identity: SHA-256 bytes of the original exported payload |
| 48 | 32 | SHA-256 bytes of canonical manifest JSON |
| 80 | 16 | File nonce base, uint128 little endian |

Canonical JSON uses Python `json.dumps(manifest, sort_keys=True,
separators=(',', ':'))`, UTF-8, without a terminating newline. Hash bytes retain
their normal digest order. On each RTL rate port, byte zero occupies bits 7:0.

The model and manifest IDs must come from the trusted expected-file descriptor.
Accepting arbitrary IDs supplied alongside an untrusted ciphertext would not
establish which model was authorized. This experiment supplies no persistent
rollback/version anchor. Per-chunk identity, length, count, manifest digest and
file nonce context prevent rearranging or replaying chunks inside a transaction.

## Ready/valid interface

`file_valid_i/file_ready_o` accepts the key, nonce base, direction, expected model
and manifest IDs, and common chunk length. The adapter length is 199,808; small
positive lengths are supported for protocol tests, including partial final beats.
`busy_o`, `done_o`, `commit_o`, and `discard_o` describe the whole transaction.
Status pulses last one clock. Only 1/2/4 are legal values of `G_CORES`.

The source maintains N side-by-side lane streams. For lane `j`, slices of
`source_data_i`, `source_keep_i`, `source_chunk_i`, and `source_offset_i` contain
its next beat; lane zero occupies the least significant slice. `source_tag_i`
distinguishes a decryption tag from payload. Payload offsets count bytes within
a gathered layer; a tag has offset equal to chunk length, keep=FFFF and last=1.
`chunk_id_o` identifies the lane's current message. `chunk_start_o` and
`chunk_done_o` expose per-lane command acceptance and message completion.

Each source must hold valid and every beat field stable until its own ready/valid
handshake. The wrapper generates the six AD beats itself, interleaves ready
lanes one beat at a time, and advances its round-robin pointer on acceptance.
Exactly one input beat can move per clock. An input grant is retained while
blocked, including when `bus_in_enable_i=0`. That optional service gate models a
memory scheduler; it defaults to enabled.

The collector independently shares one 128-bit output bus. `out_tag_o` marks an
encryption tag; payload outputs have byte offset, keep and last framing.
Output fields remain stable while valid and blocked. Input and output may each
move one beat in the same clock. Quarantine addresses come from chunk ID and
offset plus the manifest mapping, not from arrival order.

Core FIFOs default to two entries each. `G_BOUNDARY_REGISTERS=true` adds a
two-entry elastic queue at each core input and output. Queue-ready depends only
on registered occupancy, breaking cross-core ready paths. A full queue deliberately
does not accept a replacement on its pop edge. `G_LOCAL_CONTROL=true` gives each
lane preserved local key, nonce and direction registers. A preparation clock
ensures those values settle before each command.

Final-beat offset and keep mask are registered at file-command acceptance.
Candidate framing checks operate in parallel per lane, before arbitration.
The dispatcher does not place a wide length subtraction after its grant mux.

## Quarantine and errors

An output handshake means the trusted quarantine has accepted that write.
For asynchronous storage, return ready only when that acceptance acknowledgment
is meaningful; this interface has no separate outstanding-write response port.
The RTL stores only small elastic queues, never the entire plaintext file.

All output remains provisional until file commit. Decryption commit requires all
twelve authenticated chunk completions and all core/output queues drained.
Encryption completion similarly waits for every ciphertext/tag output. Any core
error, bad authentication, malformed accepted source beat, or `abort_i` discards
the whole file and flushes the cores and boundary queues. A trusted consumer must
discard its quarantine on that signal. Reset cancels the transaction and flushes
hardware; the consumer must also cancel its quarantine on reset.

Missing input cannot be distinguished from a source that is merely late.
The caller must implement a deadline and assert `abort_i`; the missing-chunk
test explicitly exercises that policy. No file can commit with a missing chunk.

The testbench quarantines bytes, compares provisional outputs internally, then
writes recovered output only after commit. Failed cases produce no released
output. No physical external plaintext-memory protection is implemented.

## Measurements

Cycles start immediately after file-command acceptance and end on file done.
First-output latency ends at the first accepted payload output. Chunk latency
is completion minus command-acceptance timestamp. File commit tail is done minus
the final accepted input **payload** beat; the final output-write timestamp is
also recorded. Tags and AD are counted in total bus utilization but excluded from
payload utilization.

`busy` means the core has an active command, including waits. `starved` counts
absorb-only states waiting on an empty internal input FIFO. `blocked` counts
absorb-only payload states with no internal output capacity. `missed_tail`
separately counts p8 tails that cannot fold the next absorb due to input absence
or output capacity. Tail clocks perform rounds and are not added to stall clocks.

Source-wait cycles are partitioned into setup/AD phase, input capacity, disabled
shared-memory service, and arbitration waits, in that precedence. Collector waits
are separated into external sink backpressure and arbitration while the sink is
ready. These interface waits are distinct from internal execution stalls and
must not be added together as disjoint lost core clocks.

Profiles are ideal service, a source opportunity every eight clocks per lane,
an output opportunity every eight clocks, seeded bursts, and aggregate memory
budgets of 10 or 13 bytes per clock. Burst service combines deterministic windows
with xorshift32 seed `8135a77d`; held beats remain offered until acceptance.
The memory scheduler shares a maximum 32-byte credit bucket between reads and
writes and alternates preferred direction; transfers cost a full 16-byte slot,
including partial beats, AD and tags. Unused reserved opportunities may be idle.
This is a defined service model, not a calibrated DDR2 controller.

The additional `skewed_lanes` test only lets lane zero offer new payload every
31 clocks, while other lanes can continue. Fairness assertions apply whenever
all lanes remain eligible, ready, and requesting service. File command/key
provisioning, software gathering, host transfer, and a later quarantine-release
copy are excluded from the payload-bus timing.
