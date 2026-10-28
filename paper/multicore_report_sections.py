"""Keep full-adapter simulation, modeled memory and physical fixture distinct."""
from gpt2_report_sections import table
from figure_support import add_figure


def add_multicore_results(doc, heading, body, caption):
    p = heading(doc, 'XVI. Folded multicore architecture and physical fixture')
    p.paragraph_format.page_break_before = True
    body(doc, 'The folded multicore experiment assigns twelve independently authenticated layer chunks to one, two or four folded cores. In full-adapter simulation, two cores nearly halve the one-core cycle count, while four approach the shared 128-bit input and output bus ceiling. A later FPGA test validates all three core counts on a bounded 3,072-byte adapter fixture. It does not measure transfer of the complete adapter or service from DDR2 [20].')
    body(doc, 'The complete 2,397,696-byte FP32 payload is gathered into twelve 199,808-byte chunks. Each chunk has 96 bytes of authenticated metadata, its own nonce and tag, and preserved chunk/offset identity. Input arbitration admits at most one 128-bit beat per clock across all lanes; the output collector also serves at most one beat per clock. Each lane has an optional registered-ready elastic boundary around a folded 3+3+2 core. Chunks are distributed by lane index and then advanced by the core count. Provisional decrypted output must terminate in trusted quarantine; transaction commit permits release and discard, abort or reset invalidates it. The diagram\'s quarantine is a required system consumer, not a complete-adapter storage block implemented by this wrapper.')
    add_figure(doc, 'fig_xvi_multicore.png', 'Fig. 11. Four-lane view of the configurable one-, two- and four-core wrapper. Shared input framing and output collection bound aggregate traffic. Each core independently authenticates its chunks; transaction control collects completion and failure. Memory hardware is outside this architecture.', caption)
    table(doc, ['Cores', 'Encrypt cycles', 'Decrypt cycles', 'Encrypt MB/s', 'Speedup'], [
        (1, '450,013', '450,001', '532.806', '1.000'),
        (2, '225,008', '225,002', '1,065.605', '2.000'),
        (4, '149,968', '149,965', '1,598.805', '3.001'),
    ], [.6, 1.65, 1.65, 1.8, 1.44])
    caption(doc, 'Table XIV. Full-adapter always-ready simulation at a nominal 100 MHz, with boundary queues bypassed. Decimal payload MB/s excludes metadata. These are simulated kernel results [20].')
    heading(doc, 'A. Bus service and routed integration timing')
    body(doc, 'All reported full-adapter encryptions match every reference ciphertext beat and tag. Decryption reconstructs the file and checkpoint exactly. Registered-ready boundaries preserve similar ideal throughput: 450,013, 225,007 and 149,971 encryption clocks for one, two and four cores. Two folded cores request about 1,066.7 MB/s of payload; four would request about 2,133.3 MB/s without bus contention. Four therefore approach the separate buses\' 1,600 MB/s ceiling at 100 MHz. Four-core cycle speedup is about 3.001 times one chunked core, 5.996 times buffered u3 and 11.991 times original u1; those denominators describe different architectures.')
    body(doc, 'The memory model charges reads and writes, including AD and tags, against an assumed shared budget. At 1 GB/s aggregate service, two and four cores both take about 4.797 ms to encrypt; at 1.3 GB/s they take about 3.749 ms. A payload read plus write already costs 4,795,392 bytes, so ideal lower bounds are 4.795392 and 3.688763 ms. A later release copy is excluded. These are modeled service limits, with no physical DDR2 controller or measured memory bandwidth.')
    table(doc, ['Integration harness', 'MHz', 'Setup / hold ns', 'LUT / registers', 'Derived encrypt ms'], [
        ('1 core, boundaries', '100', '+0.004 / +0.098', '6,980 / 3,873', '4.50013'),
        ('2 cores, boundaries', '100', '+0.012 / +0.098', '12,776 / 5,908', '2.25007'),
        ('4 cores, local control', '90', '+0.060 / +0.098', '25,916 / 10,966', '1.66634'),
    ], [2.1, .55, 1.5, 1.65, 1.34])
    caption(doc, 'Table XV. Selected routed integration harnesses on xc7a100tcsg324-1, Vivado 2023.2. Time is simulated registered-boundary cycles divided by routed clock. This is not physical file latency [20].')
    body(doc, 'Unregistered base routes fail 100 MHz for all three counts. Boundary registers close one and two cores; four fail at 100 MHz even with local control and Pblocks, then pass at 90 MHz. The one- and two-core critical paths are seven-level folded state feedback; four cores are limited by twelve-level framing/control into the core input boundary. These are individual routes with margins as small as 0.004 ns. Internal register timing is assessed separately from nominal unconstrained physical I/O placement in the out-of-context harness.')
    heading(doc, 'B. Physical FPGA fixture and negative cases')
    body(doc, 'The October 27 board fixture contains 3,072 bytes from the trained adapter, 256 bytes per layer: the first 64 bytes of each down_w, down_b, up_w and up_b slice. An on-FPGA checker compares every encryption beat/tag and valid decryption beat against an independent Python oracle. Each core count was programmed and captured twice through JTAG ILA, passing all ten cases in both runs with exact agreement with simulated case cycle counts. The complete 2,397,696-byte adapter was not transferred through the FPGA in this test [20].')
    table(doc, ['Cores', 'Board MHz', 'Setup / hold ns', 'Encrypt cycles / us', 'Decrypt cycles / us'], [
        (1, '90', '+0.963 / +0.038', '1,021 / 11.344', '1,009 / 11.211'),
        (2, '90', '+0.776 / +0.032', '511 / 5.678', '505 / 5.611'),
        (4, '75', '+0.306 / +0.028', '307 / 4.093', '304 / 4.053'),
    ], [.55, .9, 1.65, 2.02, 2.02])
    caption(doc, 'Table XVI. Measured board cycle counters for the 3,072-byte fixture. Times use nominal MMCM frequencies without external calibration. Every configuration passes 10/10 cases twice [20].')
    body(doc, 'The ten cases cover ideal encryption/decryption, input gaps and output stalls in each direction, corrupted final-layer tag, ciphertext tampering, incorrect chunk identity, abort, reset during traffic, and successful decryption after reset. Injected comparator faults were detected in simulation before bitstream generation. Provisional plaintext terminates at the trusted internal checker; only test status is externally visible. Fixture nonces are public repeat-test values, not production encryption nonces.')
    body(doc, 'The final board harness fails 100 MHz for one and two cores and fails 90 MHz for four; it passes at 90, 90 and 75 MHz respectively. Its fixture ROM, checker and debug IP introduce different paths from the integration harness, so the two clock tables must remain separate. Saved physical attempts have zero routing errors, missing clocks, unconstrained internal endpoints, multiple-clock pins and combinational loops. The selected routes pass debug-IP bus-skew constraints. Button and visual LED paths are excluded from external I/O timing; raw warnings are retained. No flash programming, physical full-file transfer, DDR2 measurement or authenticated compute integration is established by these tests.')
