"""Document the folded datapath and the later controller security fixes."""
import json
from pathlib import Path
from gpt2_report_sections import table

ROOT = Path(__file__).resolve().parents[1]


def add_fold_results(doc, heading, body, caption):
    evidence = ROOT / 'docs/evidence/handoff_study_fold_20261021'
    report = json.loads((evidence / 'adapter_sim_report.json').read_text())
    full = next(v for v in report['variants'] if v['variant'] == 'u3-fold' and v['sample'] == 'full')
    assert full['cycles'] == {'ENCRYPT': 449581, 'DECRYPT': 449581}
    assert full['result'] == 'PASS'
    assert full['recovered_sha256'] == 'c184175fc18d24373f009875c03698e630e8c36a5341146aab2bd13a98fff8eb'
    doc.add_page_break()
    heading(doc, 'XIV. Folded absorption and controller fixes')
    body(doc, 'The folded core reduces the complete adapter run to 449,581 cycles per direction, compared with 899,153 for the buffered three-round core and 1,798,305 for the original one-round baseline. At the simulated 100 MHz clock, this is 4.49581 ms and 533.318 MB/s. Encryption matches the reference ciphertext and tag; decryption authenticates, commits and recovers all 2,397,696 bytes. Reattaching the preserved 20-byte header reconstructs the saved checkpoint exactly. These are GHDL simulation results, not measured memory or host-transfer rates [14].')
    heading(doc, 'A. State ownership and the three clock schedule')
    body(doc, 'G_FOLDED_ABSORB selects a separate entity with one 320-bit state register. It requires G_ROUNDS_PER_CYCLE=3 and G_BUFFERING_ENABLE=true and is disabled by default. The earlier controller and permutation each owned a state register; absorption, request loading and completion copying added three clocks to every block. The folded entity removes those handoffs. It executes p8 in groups of 3, 3 and 2 rounds and absorbs the next queued block on the two-round tail edge. p12 still executes four groups of three. No cryptographic rounds are removed.')
    table(doc, ['Steady state edge', 'State update'], [
        ('1', 'First three p8 rounds'),
        ('2', 'Next three p8 rounds'),
        ('3', 'Final two p8 rounds and next block absorption'),
    ], [1.55, 5.59])
    caption(doc, 'Table X. Saturated full-block schedule. Initialization, finalization and stall recovery are separate.')
    body(doc, 'Round constants are registered ahead of each group. Input keep masks, padding and error flags are prepared when a beat enters the queue. The tail uses ciphertext replacement during decryption and XOR absorption during encryption. If the next input is absent or output space is unavailable, p8 completes without absorption; a later absorb-only clock resumes the stream. The full and partial final-block paths retain mandatory padding. These changes apply established absorption and buffering techniques to this controller; no novelty claim is made [1], [11]–[13], [15].')
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
    body(doc, 'In separate RTL copies with both board cores folded, the board wrapper routed at 83.333 MHz with +0.785 ns setup and +0.024 ns hold slack, and at 100 MHz in one run with +0.181 ns setup and +0.049 ns hold slack. The 100 MHz build used 9,690 LUTs and 5,362 registers. Board LUT savings did not follow the core-only reduction. No folded bitstream was written or programmed. The earlier physical captures belong to the buffered core; fold board simulations passed the self-test in 995 cycles and all eight demo pairs in 198 cycles. Full-adapter physical streaming remains unmeasured [14].')
    heading(doc, 'C. Associated data framing and tag output fixes')
    body(doc, 'The legacy engine incorrectly treated an empty last AD beat as empty AD even when full non-last AD beats preceded it. It skipped the padded block and p8, producing non-standard output and allowing two distinct AD strings to reach the same authentication state. The fix records whether any non-empty AD has been absorbed. An empty terminator after non-empty AD now takes the existing padding path; genuinely empty AD still skips p8. The folded entity already handled this case. Official-vector framing and the empty-AD adapter workload were unaffected [16].')
    body(doc, 'A second fix holds tag_out_o at zero during legacy decryption. The previous assignment exposed the expected tag while the core awaited tag_in_i; routing those bits to an untrusted observer would undermine authentication. Encryption retains the extra tag-visible clock used by the existing demo. The folded entity already gated its tag output. Default configurations therefore intentionally differ from the published 8b886c0 source: pre-fix netlist-identity evidence is historical, not a claim about the final patched engine. Saved final regressions and negative controls cover the gate [16].')
    heading(doc, 'D. Weight loading and the remaining system boundary')
    body(doc, 'The core emits provisional plaintext, so a trusted consumer must accept it into quarantine and release it only on commit_o. Discard, reset or protocol error invalidates that transaction. A FIFO is not a complete-message authentication buffer. Independent authenticated chunks can bound storage and allow loading to overlap compute, but require unique encryption nonces, authenticated model and tensor identity, offsets, lengths, chunk count and a trusted version policy. AEAD alone does not prevent rollback or hide weights from an authorized plaintext endpoint. GuardNN motivates workload-aware memory protection; its AES confidentiality-only FPGA prototype is not an Ascon integrity-performance measurement [18].')
    body(doc, 'The weight study found that lossless exponent-oriented compression reduces this export to about 83% of its original size, with byte-exact recovery. That does not establish a faster integrated loader. A decoder must sustain the folded core and must not expose unauthenticated bytes. The next measurements should test folded-core timing across implementation strategies and actual memory service gaps before adding lanes. A two-round folded schedule is a separate, untested candidate [14].')
