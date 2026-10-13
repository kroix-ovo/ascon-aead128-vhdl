"""Add the measured Ascon and GPT-2 behavior results to the research report."""
import json
from pathlib import Path
from gpt2_report_sections import table

ROOT = Path(__file__).resolve().parents[1]


def add_behavior_results(doc, heading, body, caption):
    evidence = ROOT / 'paper/evidence/gpt2_behavior_20261006'
    rtl = json.loads((evidence / 'report.json').read_text())
    model = json.loads((evidence / 'model_report.json').read_text())
    assert rtl['result'] == model['result'] == 'PASS'
    assert rtl['checks'] == 17 and rtl['cases'] == 12
    assert model['all_parameters_identical'] and model['max_absolute_logit_difference'] == 0
    assert model['checkpoint_sha256'] == model['restored_serialization_sha256']

    doc.add_page_break()
    heading(doc, 'XI. Ascon behavior on trained weight bytes')
    body(doc, 'A follow-up experiment on October 6, 2026 tested how the existing Ascon VHDL core responds to changed authenticated inputs, delayed handshakes, and a valid command after authentication failures. All 17 checks across 12 scenarios passed. The input was the same 1,024-byte trained GPT-2 weight sample from Section IX. Five valid scenarios each tested encryption and decryption; seven modified-input scenarios tested rejection during decryption.')
    body(doc, 'The runner verification/gpt2_behavior.py created a separate Vivado 2023.2 XSim project without modifying the RTL or the original testbench. Before generating expected outputs, its Python oracle passed all 1,089 pinned official known-answer vectors. The new testbench compared all 64 payload blocks, encryption tags, authentication events, commit and discard signals, and completion cleanup. Decryption outputs in failed cases were checked against the oracle as provisional plaintext, rather than accepted model weights.')
    table(doc, ['Scenario', 'Observed behavior', 'Cycles'], [
        ('Original sample, empty AD', 'Exact encryption and recovery; authentication passed', '801 each'),
        ('Ciphertext bit flip at byte 0, 512, or 1,023', 'All three rejected; no commit; discard asserted', '801 each'),
        ('Tag bit flip', 'Rejected; no commit; discard asserted', '801'),
        ('Wrong key or wrong nonce', 'Both rejected; no commit; discard asserted', '801 each'),
        ('Valid command after failed commands', 'Correct encryption and authenticated recovery', '801 each'),
        ('Valid 16-byte associated data', 'Correct encryption and authenticated recovery', '821 each'),
        ('Associated-data bit flip', 'Rejected; no commit; discard asserted', '821'),
        ('Input gaps, output stalls, delayed tag', 'Correct data; held outputs stable; no early authentication', '1,003 each'),
        ('Valid changed nonce', 'Different ciphertext and tag; correct authenticated recovery', '801 each'),
    ], [2.15, 4.14, 0.85])
    caption(doc, 'Table V. XSim behavior results for the 1 KiB trained-weight sample. Each denotes encryption and decryption where both were tested.')
    body(doc, 'The baseline latency remained 801 cycles, or 8.01 microseconds at the simulated 100 MHz clock. Adding 16 bytes of associated data increased it to 821 cycles, or 8.21 microseconds. The stall scenario inserted three-cycle gaps before input beats, held each output beat for three cycles, and delayed tag acceptance by seven cycles. It completed in 1,003 cycles, or 10.03 microseconds. Payload and tag values remained stable while held. These are command-to-done simulation intervals under the specified driver schedule; no physical FPGA or host-transfer time was measured.')
    body(doc, 'Every modified-input case produced auth_ok=0, commit=0, and discard=1. A valid transaction immediately after the failures succeeded. The core still streams provisional plaintext before checking the tag, so an external receiver must quarantine the entire transaction until commit and discard it on failure. This experiment verifies the core signals, not a production authenticated checkpoint loader. Equal valid and invalid latencies in the tested cases do not establish protection against timing, power, or electromagnetic side channels.')

    doc.add_page_break()
    heading(doc, 'XII. GPT-2 behavior after weight recovery')
    body(doc, 'The full GPT-2 model produced identical results when its tested weight slice was replaced with the newly recovered RTL bytes. This experiment used the complete 497,904,640-byte trained FP32 checkpoint, but only the first 1 KiB of parameter data passed through Ascon RTL. That slice contains 256 FP32 values from token embedding row 0; it begins immediately after the checkpoint header. Whole-checkpoint encryption was not performed.')
    body(doc, 'The runner verification/gpt2_model_behavior.py loaded two model instances using the actual checkpoint tensor order and padded vocabulary format. One instance used the original checkpoint bytes; the second substituted the recovered slice. Every model parameter matched. Reserializing both instances reproduced the original full-checkpoint SHA-256, c5acb338337d9f14b814a21e1d18415ce72c34bf18650c9ead5299b4f3ad2733. This check binds the loaded models to the trained export and guards against a wrong tensor order or an unintended model source.')
    body(doc, 'Inference ran in evaluation mode on the NVIDIA RTX 3080 Laptop GPU using PyTorch 2.11.0+cu128. FP32 arithmetic, deterministic operations, and disabled TF32 controlled the numerical comparison. Five text prompts and an explicit token sequence [0, 1, 2, 3] were evaluated. Token 0 directly exercises the embedding row containing the recovered values. Each text prompt also generated 24 new tokens using greedy decoding and a separate seeded top-40 sampling run at temperature 0.8 with seed 20261006.')
    table(doc, ['Comparison', 'Measured result'], [
        ('Parameters and serialized checkpoint hash', 'Exactly identical'),
        ('Prompt logits across six input sequences', '1,306,682 FP32 values; all exactly identical'),
        ('Maximum absolute prompt-logit difference', '0.0'),
        ('Greedy generation', 'Five prompts; 24 new tokens each; identical token sequences'),
        ('Seeded generation', 'Five prompts; 24 new tokens each; identical token sequences'),
        ('Held-out validation sample', '20 batches of 64 predicted tokens; 1,280 tokens total'),
        ('Mean cross-entropy with original weights', f"{model['validation_mean_loss_original']:.10f}"),
        ('Mean cross-entropy with recovered slice', f"{model['validation_mean_loss_restored']:.10f}"),
        ('Validation logits and per-batch losses', 'Exactly identical in all 20 batches'),
    ], [2.65, 4.49])
    caption(doc, 'Table VI. Full-model inference comparison with the original and RTL-recovered 1 KiB weight slice.')
    body(doc, 'Validation used the first 20 non-overlapping 64-token input batches from the held-out Tiny Shakespeare token file, with next-token targets. Its mean cross-entropy was 4.0104284048 for both model instances. Section VIII reports a different five-batch evaluation mean of 3.810759 after training; the different sampling schedules prevent a direct before-and-after quality comparison between those two means. The behavior test compares original and restored weights on the same inputs and obtains zero change.')
    body(doc, 'Together, these results demonstrate exact recovery of the tested weight bytes, rejection of the seven tested modifications, and preservation of full-model inference behavior after restoring that slice. They do not establish model quality, whole-checkpoint RTL encryption, or a physical-board application. The public evidence folder paper/evidence/gpt2_behavior_20261006 preserves the runner and testbench snapshots, compact simulator results, and machine-readable report.json and model_report.json, including generated text and token sequences. Trained weight binaries, full block dumps, and generated Vivado projects remain local.')
