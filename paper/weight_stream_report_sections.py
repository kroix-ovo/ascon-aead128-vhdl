"""Measured three-round acceleration and complete adapter recovery."""
import json
from pathlib import Path
from gpt2_report_sections import table

ROOT = Path(__file__).resolve().parents[1]


def add_weight_stream_results(doc, heading, body, caption):
    evidence = ROOT/'paper/evidence/adapter_100mhz_20261021'
    baseline = json.loads((evidence/'baseline_report.json').read_text())
    candidate = json.loads((evidence/'candidate_report.json').read_text())
    full = next(r for r in baseline['variants'] if r['sample']=='full')
    assert full['result'] == candidate['result'] == 'PASS'
    assert full['recovered_sha256'] == candidate['recovered_sha256']
    assert full['bytes'] == candidate['plaintext_bytes'] == 2397696
    assert full['cycles'] == {'ENCRYPT': 1798305, 'DECRYPT': 1798305}
    assert candidate['measurements']['encrypt']['cycles'] == 899153
    assert candidate['measurements']['decrypt']['cycles'] == 899153
    assert candidate['rtl_authenticated_and_committed']
    doc.add_page_break()
    heading(doc, 'XIII. Buffered three round adapter results')
    body(doc, 'The complete SAGE adapter export was encrypted and recovered with half the baseline cycle count at a 100 MHz simulated clock. The unchanged one-round core required 1,798,305 cycles per direction; three rounds per cycle with input/output buffering and controller overlap required 899,153. This approximately doubles throughput and halves the cycle count. Both runs recovered every byte and passed RTL authentication and commit. The result measures encryption and decryption throughput, not model inference speed.')
    heading(doc, 'A. Architecture and sources')
    body(doc, 'NIST SP 800-232 defines the required Ascon-AEAD128 behavior [1]. The implementation retains its 128-bit rate, padding, round constants, twelve-round initialization/finalization, and eight-round block permutations. A configurable combinational chain defaults to one round per clock. The candidate evaluates p8 as 3 + 3 + 2 rounds and p12 as four groups of three. The last p8 group executes only its two remaining rounds; it neither omits a round nor executes a ninth round.')
    body(doc, 'The earlier architecture study drew on Robert Primas’s public Ascon hardware variants, which provide one-, two-, and four-round unrolling [11], and OpenTitan’s discussion of latency, feedback dependencies, and the area cost of unrolling [12]. Those sources motivate the architectural technique; they do not supply this project’s three-round performance numbers. OpenTitan also limits its unrolling rationale to an unhardened datapath. This core remains unmasked and makes no side-channel-resistance claim.')
    body(doc, 'The FIFO design follows the ready/valid principles summarized by LaForest [13]: transfer on a simultaneous ready/valid handshake, hold unaccepted data stable, and avoid advancing interface state without a completed transfer. This is a supporting design reference, not evidence that third-party FIFO RTL was copied. The two-entry input queue stores data and kind/keep/last metadata while the permutation runs. The two-entry output queue accepts a completed block before permutation work advances; the controller launches p8 on that enqueue edge. Simultaneous push/pop is supported, full queues cannot overwrite data, and input acceptance stops after the final payload beat. These queues and controller changes are this repository’s adaptation of the general ideas.')
    body(doc, 'Decrypted bytes remain provisional. An external consumer must collect them into quarantine while the stream runs and publish only on commit_o; discard, protocol error, or reset invalidates that transaction. Authentication is delayed until queued plaintext drains, and pending ciphertext is retained through completion. Reset and protocol errors erase queued data and cryptographic storage. A selectable full-16-byte mask specialization saved no clocks and increased area in the controlled experiment, so it is disabled. Partial endings and mandatory final padding remain supported.')
    heading(doc, 'B. Adapter identity and simulation method')
    body(doc, 'The existing file runs/adapter_fp32_200/export/adapter_weights.bin contains all 599,424 little-endian FP32 adapter values: down_w [12,32,768], down_b [12,32], up_w [12,768,32], and up_b [12,768]. Its length is 2,397,696 bytes (149,856 full blocks), with no export padding. The saved checkpoint is adapter_params_00000200.bin. The export is exactly its complete body after the 20-byte [B,L,C,r,T] format header. This experiment used saved artifacts and did not train a model.')
    body(doc, 'On October 20, 2026, Vivado 2023.2 XSim ran the buffered three-round core with a 10 ns behavioral clock. A fresh GHDL run of unchanged origin/main reproduced the earlier one-round result exactly on the same file. Both file benches count command through done, including stream handshakes, empty associated data, mandatory final padding, and tag work; host I/O, Python reference execution, and simulator wall time are excluded. Output is always ready in this throughput test. Independent encryption runs use distinct nonces under a public test key. The corresponding decryption reuses each message’s nonce as required to verify it.')
    table(doc, ['Configuration at 100 MHz', 'Cycles each', 'Latency each', 'Payload MB/s'], [
        ('Unchanged one-round baseline', '1,798,305', '17.98305 ms', '133.331'),
        ('Three rounds with queues and overlap', '899,153', '8.99153 ms', '266.662'),
    ], [3.15, 1.25, 1.35, 1.39])
    caption(doc, 'Table VII. Complete adapter payload; encryption and decryption have equal latency. MB denotes 1,000,000 bytes. The speedup combines unrolling, buffering, and launch overlap.')
    body(doc, 'The Python oracle first passed all 1,089 official known-answer vectors. The full-file RTL runs then matched every ciphertext block and tag against that oracle, asserted authentication and commit, and recovered all payload bytes with zero mismatches. Original and recovered payload SHA-256: c184175fc18d24373f009875c03698e630e8c36a5341146aab2bd13a98fff8eb. Reattaching the original format header reproduced the complete saved checkpoint exactly, SHA-256 7c45c25b28ae54943c1fd4ee160001dcd9a68ee1f8430aee229f933545672de6. The header itself is outside the requested exported weight payload and was preserved unchanged.')
    heading(doc, 'C. Correctness coverage and comparison with earlier workloads')
    body(doc, 'All three core configurations passed all 1,089 official vectors in both directions, or 2,178 checks per configuration. Additional tests covered concurrent sustained traffic, input gaps, long output stalls, FIFO capacities one through three, wraparound and simultaneous enqueue/dequeue, reset with buffered data, malformed streams, consecutive messages, empty inputs, all partial final lengths, and tampered ciphertext, associated data, nonces, and tags. Rejected transactions must never commit. Intermediate permutation-state traces check grouping without changing cryptographic round counts. These protocol checks are separate from the always-ready adapter throughput run.')
    table(doc, ['Configuration', '1 KiB cycles', '1,641,984-byte cycles', 'Full-block interval'], [
        ('One round', '801', '1,231,521', '12 clocks'),
        ('Three rounds alone', '465', '718,385', '7 clocks'),
        ('Three rounds with queues and overlap', '401', '615,761', '6 clocks'),
    ], [2.65, 1.15, 1.94, 1.40])
    caption(doc, 'Table VIII. Separate complete small-LLaMA payload comparison from October 20, 2026. These are measured simulation counts, not estimates for the adapter file.')
    body(doc, 'The adapter comparison does not separately measure three-round unrolling alone. Table VIII isolates that stage on another complete payload. Under a 1 KiB schedule with associated data, input gaps and output stalls, buffering reduced three-round cycles from 862 to 581. With always-ready traffic it added two clocks of first-output latency but reduced block spacing from seven clocks to six. Three clocks of the remaining six execute p8 round groups; request, completion and block-handling overhead remain. This explains why tripling round execution per clock gives approximately twice the complete-file throughput.')
    heading(doc, 'D. Routed timing and physical evidence')
    table(doc, ['Core-only configuration', 'Setup / hold ns', 'LUTs', 'Registers'], [
        ('One round', '+2.914 / +0.147', '1,894', '1,081'),
        ('Three rounds alone', '+0.125 / +0.152', '3,192', '1,088'),
        ('Three rounds with queues and overlap', '+0.038 / +0.144', '3,708', '1,680'),
    ], [3.15, 1.59, 1.20, 1.20])
    caption(doc, 'Table IX. Vivado routed core-only results for xc7a100tcsg324-1 with a 10 ns clock. External I/O paths were unconstrained; these are internal core timing results.')
    body(doc, 'The final board-integrated design contains separate demo and self-test cores plus ILA. It closed at 83.333 MHz with +1.110 ns setup and +0.024 ns hold slack, using 9,503 LUTs and 6,510 registers. Its MMCM generates a 12 ns clock from the board’s 100 MHz reference. An earlier board trial at 100 MHz failed setup at -0.130 ns; it predates the final demo fix and is not a timing result for the final source. The core-only 38 ps setup margin does not establish 100 MHz board closure.')
    body(doc, 'Physical JTAG ILA captures on the confirmed Nexys A7-100T show completion/pass with no failure for 18 core self-test cases and eight demo vector/mode pairs. Latched counts were 1,161 and 274 cycles respectively, matching simulation. These captured bounded fixtures establish more than programming success, but do not establish full adapter transport or physical weight throughput. Complete adapter recovery remains simulation evidence. Full-file board testing would require a host transport beyond this core.')
    heading(doc, 'E. Reproduction and remaining bottlenecks')
    body(doc, 'The new verification/simulate_adapter.py runner validates the export manifest and optional original checkpoint, then freezes unchanged origin/main and buffered candidate sources and runs the 1 KiB prefix and complete file at 10 ns. It checks all output/tag bytes and authenticated recovery, publishes recovered files only after PASS, reconstructs the checkpoint when supplied, and records source hashes, nonces and cycle counts. paper/evidence/adapter_100mhz_20261021 contains compact reports, manifests and simulation logs. docs/evidence/weight_stream_3rpc contains the wider protocol, implementation and hardware evidence. Binary weights, full dumps, simulator projects and bitstreams remain local.')
    body(doc, 'Subsequent research could test absorption directly on permutation completion and determine whether the reduced controller overhead outweighs added critical-path delay. Parallel independent-message lanes need separate cryptographic contexts and bandwidth arbitration. Memory bursts need bus/DMA and memory-controller integration. Lossless compression needs a codec, framing, metadata and exact reconstruction, with a measured ratio on actual weights. None is included here; the present measurements first establish the benefit of buffering and controller scheduling.')
