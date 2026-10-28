"""Document the folded datapath and the later controller security fixes."""
import json
from pathlib import Path
from gpt2_report_sections import table
from figure_support import add_figure

ROOT = Path(__file__).resolve().parents[1]


def add_fold_results(doc, heading, body, caption):
    evidence = ROOT / 'docs/evidence/handoff_study_fold_20261021'
    report = json.loads((evidence / 'adapter_sim_report.json').read_text())
    full = next(v for v in report['variants'] if v['variant'] == 'u3-fold' and v['sample'] == 'full')
    assert full['cycles'] == {'ENCRYPT': 449581, 'DECRYPT': 449581}
    assert full['result'] == 'PASS'
    assert full['recovered_sha256'] == 'c184175fc18d24373f009875c03698e630e8c36a5341146aab2bd13a98fff8eb'
    heading(doc, 'XIV. Folded absorption and controller fixes')
    body(doc, 'The folded core reduces the complete adapter run to 449,581 cycles per direction, compared with 899,153 for the buffered three-round core and 1,798,305 for the original one-round baseline. At the simulated 100 MHz clock, this is 4.49581 ms and 533.318 MB/s. Encryption matches the reference ciphertext and tag; decryption authenticates, commits and recovers all 2,397,696 bytes. Reattaching the preserved 20-byte header reconstructs the saved checkpoint exactly. These are GHDL simulation results, not measured memory or host-transfer rates [14].')
    heading(doc, 'A. State ownership and the three clock schedule')
    body(doc, 'G_FOLDED_ABSORB selects a separate entity with one 320-bit state register S. It requires G_ROUNDS_PER_CYCLE=3 and G_BUFFERING_ENABLE=true and is disabled by default. S feeds the round chain directly. Its load multiplexer selects hold, the three-round result (R3), the two-round tail with absorption (TAIL), or an XOR-only leg (XF) for command loading, key and domain-separation terms, and absorption without rounds (Fig. 7). There is no second state register or registered start/done interface. The load and completion-copy clocks in Fig. 6 therefore disappear.')
    body(doc, 'Absorption then uses the spare depth in the 3+3+2 schedule. After the final two p8 rounds, encryption XORs the queued plaintext into the rate and emits ciphertext. Decryption emits the old rate XOR the queued ciphertext, then replaces the valid rate bytes with ciphertext. The next p8 group runs on the following edge. The resulting recurrence is R3, R3, TAIL; p12 remains four groups of three, with no omitted rounds. In the saved route, the state-to-output-queue tap had +1.373 ns slack, while the worst state-update path remained seven LUT levels and 9.841 ns [14]. That output-tap result is not a separate measurement of every path through the tail. A 4+4 grouping has no short group and would place absorption after four rounds.')
    add_figure(doc, 'fig_xiv_fold_architecture.png', 'Fig. 7. Folded datapath with one state owner. Gray blocks show S, the decoded input queue and tail absorption. The output tap uses the rate before absorption, from S or the two-round result, XORed with the queued data. Tag and external command wiring are omitted. The multiplexer selects HOLD, R3, TAIL or XF.', caption)
    table(doc, ['Steady state edge', 'State update'], [
        ('1', 'First three p8 rounds'),
        ('2', 'Next three p8 rounds'),
        ('3', 'Final two p8 rounds and next block absorption'),
    ], [1.55, 5.59])
    caption(doc, 'Table X. Saturated full-block schedule. Initialization, finalization and stall recovery are separate.')
    body(doc, 'Input beats are decoded on queue acceptance, preparing masked data, padding and error flags before the tail edge. The queue head stays at entry zero, and round constants are registered one clock before use. Input ready is derived from registered phase and queue state rather than from input valid or downstream ready; reset still gates the interface combinationally. The FSM in Fig. 8 uses absorb-only states for the first beat and whenever a tail cannot absorb the next beat. It finishes p8 without absorption if input is absent or output space is unavailable, then waits for an eligible beat. Final full, partial and empty blocks retain their separate padding rules [1], [13]–[15].')
    add_figure(doc, 'fig_xiv_fold_fsm.png', 'Fig. 8. Grouped folded-controller flow. The gray state sustains one full block per three clocks when input and output space are available. Absorb-only states handle initial absorption and tail fallback. Partial/empty final payloads can enter F_FINAL directly from either absorption path. p8/p12 group advances, waits and error edges are omitted; protocol errors enter F_ZEROIZE.', caption)
    body(doc, 'Other hardware reports need separate interpretation. Liu, Han and Quan describe a larger parallel architecture using legacy Ascon-128 [4]; their throughput is not a single-stream SP 800-232 result. Huong, Nam and Phat report an IoT application of Ascon-AEAD128 [5]. Neither source supplies performance measurements for this adapter or board wrapper.')
    heading(doc, 'B. Verification and saved implementation results')
    table(doc, ['Configuration', 'Full adapter cycles', '1 KiB cycles'], [
        ('Original one-round baseline', '1,798,305', '801'),
        ('Buffered three-round core', '899,153', '401'),
        ('Folded three-round core', '449,581', '205'),
    ], [3.35, 2.04, 1.75])
    caption(doc, 'Table XI. Command through done with empty AD and always-ready output. Counts are equal for encryption and decryption [14].')
    body(doc, 'The folded core passed 2,178 official directional checks, concurrent stream tests, partial blocks, stalls, reset and malformed-input checks. test_fold compares intermediate round groups with the Python model and checks a mid-stream error with queued plaintext. test_cycles now checks documented cycle counts. Generated-Verilog smoke tests passed with Icarus and Verilator before the later legacy-engine fixes. The final tag-gate evidence records twelve test_ascon groups passing for all four configurations, full KAT runs for u1, buffered u3 and fold, full stream suites for buffered u3 and fold, and cycle regressions. Restoring the ungated legacy assignment makes the new tag-output test fail, as expected [14], [16].')
    table(doc, ['Core-only snapshot at 100 MHz', 'Setup / hold ns', 'LUT / FF'], [
        ('Buffered u3 before both fixes', '+0.038 / +0.144', '3,708 / 1,680'),
        ('Buffered u3 after AD fix, before tag gate', '+0.287 / +0.110', '3,871 / 1,688'),
        ('Folded core', '+0.139 / +0.101', '2,985 / 1,085'),
    ], [3.75, 1.65, 1.74])
    caption(doc, 'Table XII. Vivado 2023.2 routes on xc7a100tcsg324-1. External I/O delays are unconstrained; the final legacy tag gate has not been rerouted [14], [16].')
    body(doc, 'Relative to the earlier buffered snapshot, the fold saves 723 LUTs and 595 registers. Its setup path still has seven LUT levels, with 9.841 ns data delay. The small slack differences are not evidence of a higher maximum frequency. AMD notes that 7-series LUT delay is included in net delay, so a large reported routing fraction cannot be interpreted as removable wire delay alone [17].')
    body(doc, 'In separate RTL copies with both board cores folded, the board wrapper routed at 83.333 MHz with +0.785 ns setup and +0.024 ns hold slack, and at 100 MHz in one run with +0.181 ns setup and +0.049 ns hold slack. The 100 MHz build used 9,690 LUTs and 5,362 registers. Board LUT savings did not follow the core-only reduction. At this October 21 stage, no folded bitstream was written or programmed; the later multicore fixture is reported in Section XVI. The earlier physical captures belong to the buffered core; fold board simulations passed the self-test in 995 cycles and all eight demo pairs in 198 cycles. Full-adapter physical streaming remains unmeasured [14].')
    heading(doc, 'C. Associated data framing and tag output fixes')
    body(doc, 'The legacy engine incorrectly treated an empty last AD beat as empty AD even when full non-last AD beats preceded it. It skipped the padded block and p8, producing non-standard output and allowing two distinct AD strings to reach the same authentication state. The fix records whether any non-empty AD has been absorbed. An empty terminator after non-empty AD now takes the existing padding path; genuinely empty AD still skips p8. The folded entity already handled this case. Official-vector framing and the empty-AD adapter workload were unaffected [16].')
    body(doc, 'A second fix holds tag_out_o at zero during legacy decryption. The previous assignment exposed the expected tag while the core awaited tag_in_i; an observer could read the correct tag for modified ciphertext and return it on tag_in_i, causing that message to authenticate and commit. Encryption retains the extra tag-visible clock used by the existing demo. The folded entity already gated its tag output. Default configurations therefore intentionally differ from the published 8b886c0 source: pre-fix netlist-identity evidence is historical, not a claim about the final patched engine. Saved final regressions and negative controls cover the gate [16].')
    heading(doc, 'D. Weight loading and the remaining system boundary')
    body(doc, 'The core emits provisional plaintext, so a trusted consumer must accept it into quarantine and release it only on commit_o. Discard, reset or protocol error invalidates that transaction. A FIFO is not a complete-message authentication buffer. Independent authenticated chunks can bound storage and allow loading to overlap compute, but require unique encryption nonces, authenticated model and tensor identity, offsets, lengths, chunk count and a trusted version policy. AEAD alone does not prevent rollback or hide weights from an authorized plaintext endpoint. GuardNN motivates workload-aware memory protection; its AES confidentiality-only FPGA prototype is not an Ascon integrity-performance measurement [18].')
    body(doc, 'The weight study found that lossless exponent-oriented compression reduces this export to about 83% of its original size, with byte-exact recovery. That does not establish a faster integrated loader. A decoder must sustain the folded core and must not expose unauthenticated bytes. The next measurements should test folded-core timing across implementation strategies and actual memory service gaps before adding lanes. A two-round folded schedule is a separate, untested candidate [14].')
