#!/usr/bin/env python3
"""Build the editable undergraduate research paper as a DOCX file."""

import json
from pathlib import Path

from docx import Document
from docx.enum.section import WD_SECTION
from docx.enum.table import WD_ALIGN_VERTICAL, WD_TABLE_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_BREAK, WD_LINE_SPACING
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Inches, Pt, RGBColor


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "paper" / "VHDL_Implementation_of_NIST_Ascon_AEAD128_on_a_Nexys_A7_FPGA.docx"
METRICS = ROOT / "build" / "vivado" / "reports" / "metrics.json"


def load_metrics():
    if not METRICS.exists():
        return {"simulation": {"complete": False}, "vivado": {"complete": False}}
    return json.loads(METRICS.read_text(encoding="utf-8"))


def set_cell_border(cell, **edges):
    tc_pr = cell._tc.get_or_add_tcPr()
    borders = tc_pr.first_child_found_in("w:tcBorders")
    if borders is None:
        borders = OxmlElement("w:tcBorders")
        tc_pr.append(borders)
    for edge_name, values in edges.items():
        tag = "w:" + edge_name
        edge = borders.find(qn(tag))
        if edge is None:
            edge = OxmlElement(tag)
            borders.append(edge)
        for key, value in values.items():
            edge.set(qn("w:" + key), str(value))


def add_page_number(paragraph):
    run = paragraph.add_run()
    begin = OxmlElement("w:fldChar")
    begin.set(qn("w:fldCharType"), "begin")
    instruction = OxmlElement("w:instrText")
    instruction.set(qn("xml:space"), "preserve")
    instruction.text = "PAGE"
    end = OxmlElement("w:fldChar")
    end.set(qn("w:fldCharType"), "end")
    run._r.extend([begin, instruction, end])


def add_body(doc, text, indent=True):
    paragraph = doc.add_paragraph()
    paragraph.alignment = WD_ALIGN_PARAGRAPH.JUSTIFY
    paragraph.paragraph_format.space_after = Pt(3)
    paragraph.paragraph_format.line_spacing = 1.02
    if indent:
        paragraph.paragraph_format.first_line_indent = Inches(0.22)
    paragraph.add_run(text)
    return paragraph


def add_heading(doc, text):
    paragraph = doc.add_paragraph()
    paragraph.paragraph_format.space_before = Pt(5)
    paragraph.paragraph_format.space_after = Pt(2)
    paragraph.paragraph_format.keep_with_next = True
    run = paragraph.add_run(text)
    run.bold = True
    run.font.size = Pt(10.5)
    return paragraph


def add_caption(doc, text):
    paragraph = doc.add_paragraph()
    paragraph.alignment = WD_ALIGN_PARAGRAPH.CENTER
    paragraph.paragraph_format.space_before = Pt(2)
    paragraph.paragraph_format.space_after = Pt(4)
    paragraph.paragraph_format.keep_with_next = False
    run = paragraph.add_run(text)
    run.font.size = Pt(8.5)
    return paragraph


def add_result_table(doc, metrics):
    table = doc.add_table(rows=1, cols=4)
    table.alignment = WD_TABLE_ALIGNMENT.CENTER
    table.autofit = False
    widths = [Inches(2.05), Inches(1.45), Inches(1.25), Inches(2.05)]
    headings = ["Verification level", "Cases", "Result", "Evidence"]
    for index, cell in enumerate(table.rows[0].cells):
        cell.width = widths[index]
        cell.vertical_alignment = WD_ALIGN_VERTICAL.CENTER
        p = cell.paragraphs[0]
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        r = p.add_run(headings[index])
        r.bold = True
        r.font.size = Pt(8.2)
    textio_complete = metrics.get("simulation", {}).get("complete", False)
    rows = [
        ("Python reference", "81 boundary pairs", "PASS", "official KAT comparison"),
        ("GHDL direct VHDL", "1,089 × 2", "PASS", "encrypt and decrypt"),
        ("Protocol/security", "9 test groups", "PASS", "stalls, reset, zeroization"),
        (
            "GHDL TextIO bench",
            "1,089 × 2" if textio_complete else "not rerun",
            "PASS" if textio_complete else "PENDING",
            "two output text files",
        ),
        ("Icarus netlist", "1,089 × 2", "PASS", "GHDL-generated Verilog"),
        ("Verilator netlist", "1,089 × 2", "PASS", "GHDL-generated Verilog"),
        (
            "Vivado 2023.2",
            "implemented" if metrics.get("vivado", {}).get("complete") else "not run",
            "PASS" if metrics.get("vivado", {}).get("complete") else "PENDING",
            "reports and bitstream" if metrics.get("vivado", {}).get("complete") else "requires Windows/Linux host",
        ),
    ]
    for values in rows:
        cells = table.add_row().cells
        for index, value in enumerate(values):
            cells[index].width = widths[index]
            cells[index].vertical_alignment = WD_ALIGN_VERTICAL.CENTER
            p = cells[index].paragraphs[0]
            p.alignment = WD_ALIGN_PARAGRAPH.CENTER if index in (1, 2) else WD_ALIGN_PARAGRAPH.LEFT
            p.paragraph_format.space_after = Pt(0)
            r = p.add_run(value)
            r.font.size = Pt(8.0)
    for row in table.rows:
        for cell in row.cells:
            set_cell_border(
                cell,
                top={"val": "single", "sz": 5, "color": "000000"},
                bottom={"val": "single", "sz": 5, "color": "000000"},
                left={"val": "single", "sz": 5, "color": "000000"},
                right={"val": "single", "sz": 5, "color": "000000"},
            )
    return table


def build():
    metrics = load_metrics()
    vivado = metrics.get("vivado", {})
    if vivado.get("complete"):
        implementation_summary = (
            f"Vivado used {int(vivado['slice_luts'])} slice LUTs and "
            f"{int(vivado['slice_registers'])} slice registers. The post-route "
            f"worst setup slack was {vivado['wns_ns']:.3f} ns at 100 MHz."
        )
    else:
        implementation_summary = (
            "Vivado implementation measurements remain pending because Vivado is not "
            "available on the Mac used for this stage of the work."
        )
    simulation = metrics.get("simulation", {})
    latency = metrics.get("latency_by_payload_bytes", {}).get("encryption", {})
    if simulation.get("complete") and "32" in latency:
        latency_32 = latency["32"]
        latency_summary = (
            f"The official-vector TextIO run measured 34 to 88 command-to-done "
            f"cycles. For a 32-byte payload, the mean across all 33 associated-data "
            f"lengths was {latency_32['mean_cycles']:.3f} cycles, equal to "
            f"{latency_32['mean_payload_throughput_mbps']:.3f} Mb/s at 100 MHz. "
            "These are cycle-based simulation results, not a measured maximum clock rate."
        )
    else:
        latency_summary = "Cycle-count results are generated after the full TextIO run."

    doc = Document()
    section = doc.sections[0]
    section.page_width = Inches(8.5)
    section.page_height = Inches(11)
    section.top_margin = Inches(0.55)
    section.bottom_margin = Inches(0.52)
    section.left_margin = Inches(0.68)
    section.right_margin = Inches(0.68)

    normal = doc.styles["Normal"]
    normal.font.name = "Times New Roman"
    normal._element.rPr.rFonts.set(qn("w:eastAsia"), "Times New Roman")
    normal.font.size = Pt(10.25)
    normal.font.color.rgb = RGBColor(0, 0, 0)

    title_style = doc.styles["Title"]
    title_style.font.name = "Times New Roman"
    title_style._element.rPr.rFonts.set(qn("w:eastAsia"), "Times New Roman")
    title_style.font.size = Pt(16)
    title_style.font.bold = True
    title_style.font.color.rgb = RGBColor(0, 0, 0)

    footer = section.footer.paragraphs[0]
    footer.alignment = WD_ALIGN_PARAGRAPH.CENTER
    footer_run = footer.add_run("Jones | ")
    footer_run.font.name = "Times New Roman"
    footer_run.font.size = Pt(8)
    add_page_number(footer)

    title = doc.add_paragraph(style="Title")
    title.alignment = WD_ALIGN_PARAGRAPH.CENTER
    title.paragraph_format.space_after = Pt(5)
    title_borders = OxmlElement("w:pBdr")
    title_bottom = OxmlElement("w:bottom")
    title_bottom.set(qn("w:val"), "nil")
    title_borders.append(title_bottom)
    title._p.get_or_add_pPr().append(title_borders)
    title_run = title.add_run("VHDL Implementation of NIST Ascon AEAD128\non a Nexys A7 FPGA")
    title_run.bold = True
    title_run.font.name = "Times New Roman"
    title_run.font.size = Pt(16)

    author = doc.add_paragraph()
    author.alignment = WD_ALIGN_PARAGRAPH.CENTER
    author.paragraph_format.space_after = Pt(7)
    author.add_run(
        "Kroix Jones\nElectrical Engineering Undergraduate Researcher\n"
        "Howard University\nResearch Advisor: Professor Wenjie Che"
    )

    add_heading(doc, "Abstract")
    add_body(
        doc,
        "This paper describes a VHDL-2008 implementation of the standardized NIST "
        "Ascon-AEAD128 algorithm for a Nexys A7 100T FPGA. The design uses one shared "
        "320-bit permutation datapath and completes one Ascon round per clock cycle. A "
        "128-bit streaming interface accepts associated data and payload bytes, including "
        "empty and partial blocks. Encryption returns ciphertext and a tag. Decryption "
        "returns tentative plaintext and releases it only after tag verification. The "
        "portable test flow passed all 1,089 official known-answer vectors in both "
        "directions with GHDL. Generated Verilog was also checked with Icarus Verilog and "
        "Verilator. Vivado scripts, a TextIO testbench, constraints, and a switch-and-LED "
        f"demonstration are included. {implementation_summary}",
        indent=False,
    )

    add_heading(doc, "I. Research objective")
    add_body(
        doc,
        "The goal of this work is to build an understandable FPGA implementation of "
        "authenticated encryption. The core must follow the final standard, handle normal "
        "streaming stalls, and make authentication failure visible to the surrounding "
        "system. The first version favors a clear control path over maximum throughput. "
        "It is meant to support later research on faster datapaths and hardware security "
        "countermeasures without changing the external transaction format.",
    )

    add_heading(doc, "II. Ascon-AEAD128 background")
    add_body(
        doc,
        "NIST SP 800-232 defines Ascon-AEAD128 with a 128-bit key, 128-bit nonce, "
        "128-bit authentication tag, 128-bit data rate, and a 320-bit internal state [1]. "
        "The state is divided into five 64-bit words. Initialization and finalization use "
        "a 12-round permutation. Associated-data and full payload blocks use an 8-round "
        "permutation. Each round applies a constant to one state word, evaluates 64 "
        "five-input S-box slices in parallel, and then performs word-specific rotations "
        "and XOR operations.",
    )
    add_body(
        doc,
        "The final NIST version was selected instead of legacy Ascon-128 or Ascon-128a. "
        "The final standard changed the initialization value and changed byte mapping to "
        "little endian [1]. For this core, byte lane 0 is bits 7 through 0 of the 128-bit "
        "port. Padding places the byte value 01 immediately after the last valid byte. "
        "Using the official mapping avoids a common result where a design is internally "
        "consistent but does not match current NIST vectors.",
    )

    flow = doc.add_table(rows=1, cols=6)
    flow.alignment = WD_TABLE_ALIGNMENT.CENTER
    labels = ["Initialize\np12", "Absorb AD\np8", "Domain\nseparate", "Process data\np8", "Finalize\np12", "Tag\n128 bits"]
    for idx, cell in enumerate(flow.rows[0].cells):
        cell.width = Inches(1.18)
        cell.vertical_alignment = WD_ALIGN_VERTICAL.CENTER
        p = cell.paragraphs[0]
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        p.paragraph_format.space_after = Pt(0)
        r = p.add_run(labels[idx])
        r.font.size = Pt(8.3)
        if idx in (0, 5):
            r.bold = True
        set_cell_border(
            cell,
            top={"val": "single", "sz": 8, "color": "000000"},
            bottom={"val": "single", "sz": 8, "color": "000000"},
            left={"val": "single", "sz": 8, "color": "000000"},
            right={"val": "single", "sz": 8, "color": "000000"},
        )
    add_caption(doc, "Fig. 1. Ascon-AEAD128 processing phases, adapted from NIST SP 800-232 [1].")

    doc.add_page_break()
    add_heading(doc, "III. Hardware architecture")
    add_body(
        doc,
        "The datapath contains five 64-bit state registers and one combinational round. "
        "A small round counter selects the required constants and returns the updated state "
        "after 8 or 12 clocks. Reusing one round reduces duplicated logic and keeps the "
        "relationship between the VHDL and the algorithm visible. The same engine serves "
        "initialization, associated data, payload processing, and finalization.",
    )
    pic = doc.add_picture(str(ROOT / "paper" / "assets" / "ascon_architecture.png"), width=Inches(7.0))
    pic.alignment = WD_ALIGN_PARAGRAPH.CENTER
    add_caption(doc, "Fig. 2. Original block diagram of the implemented architecture.")
    add_body(
        doc,
        "The controller accepts a command containing the key, nonce, and direction. "
        "Associated data must finish before payload begins. Each stream beat includes 16 "
        "keep bits and a last flag. Keep bits must start at lane 0 and remain contiguous. "
        "An empty phase uses a terminal beat with no keep bits set. Any invalid ordering or "
        "mask produces a protocol error and sends all transaction storage through the "
        "same zeroization state used after a normal result.",
    )

    add_heading(doc, "IV. Authentication-safe decryption")
    add_body(
        doc,
        "A decryption core cannot know whether plaintext is authentic until it processes "
        "the final tag. Storing every possible message inside the cryptographic core would "
        "make its memory size depend on the application. This design sends tentative "
        "plaintext to an external quarantine buffer instead. A correct tag pulses commit. "
        "A wrong tag pulses discard and never pulses commit. The interface therefore makes "
        "the safe release rule explicit, but the system integrator must enforce it.",
    )

    doc.add_page_break()
    add_heading(doc, "V. Controller and verification")
    add_body(
        doc,
        "The finite-state machine was made for this streaming architecture. Start states "
        "issue a one-cycle request to the permutation engine. Wait states prevent another "
        "request until the current permutation ends. Output states hold data stable during "
        "backpressure. Tag states either wait for the encryption tag to be accepted or wait "
        "for a decryption tag to be supplied.",
    )
    pic = doc.add_picture(str(ROOT / "paper" / "assets" / "ascon_fsm.png"), width=Inches(7.0))
    pic.alignment = WD_ALIGN_PARAGRAPH.CENTER
    add_caption(doc, "Fig. 3. Original controller state flow used by the VHDL core.")
    add_body(
        doc,
        "Verification began with an independent Python model. The model was compared with "
        "the official ascon-c known-answer file pinned to a recorded source revision [2]. "
        "Cocotb then drove the same vectors through the VHDL core. The full run covered all "
        "1,089 combinations of associated-data and plaintext lengths from 0 through 32 "
        "bytes, with encryption followed by decryption. Separate tests stalled each output, "
        "reset an active transaction, sent invalid masks and phase ordering, checked fixed-"
        "seed messages up to 80 bytes, and changed the key, nonce, associated data, ciphertext, "
        "and tag.",
    )
    add_result_table(doc, metrics)
    add_caption(doc, "Table I. Verification results collected before Vivado implementation.")

    doc.add_page_break()
    add_heading(doc, "VI. Vivado flow and FPGA demonstration")
    add_body(
        doc,
        "The repository contains Tcl scripts for Vivado 2023.2 and an XDC file for the "
        "Nexys A7 100T part xc7a100tcsg324-1. The constraint sets the board clock to 100 "
        "MHz. A pure VHDL XSim testbench writes simulation_results.txt for human review "
        "and simulation_vectors.txt for scripts. The same file-driven bench was checked "
        "with GHDL across all 1,089 vectors in both directions. XSim uses the identical "
        "TextIO input. " + latency_summary + " " + (
            "The measured implementation results are read from the validated Vivado "
            "metrics file. " + implementation_summary
            if vivado.get("complete")
            else "XSim execution, synthesis, implementation, timing, and power reporting "
            "still require the Vivado machine. Resource use, maximum clock rate, and "
            "post-route throughput are intentionally not estimated in this paper."
        ),
    )
    add_body(
        doc,
        "The board wrapper stores four official vectors: empty input, a one-byte partial "
        "block, one full block, and a 17-byte two-block case. Switches choose the vector, "
        "encryption or decryption, payload or tag display, block number, and byte number. "
        "The center button starts a run and the upper button resets the design. LEDs display "
        "the selected result byte, busy and done state, authentication pass or fail, and a "
        "protocol error.",
    )

    add_heading(doc, "VII. Limitations and next work")
    add_body(
        doc,
        "This version is an unprotected cryptographic core. It does not prevent power or "
        "electromagnetic side-channel analysis, and it does not detect injected faults. "
        "Kandi et al. describe threshold and redundancy-based hardware options that could "
        "be studied after the baseline is stable [3]. A faster unrolled or ping-pong "
        "architecture is another option, but it would use more logic and make the first "
        "implementation harder to inspect [4]. The external quarantine buffer is also a "
        "required part of safe decryption, not an optional application feature.",
    )

    add_heading(doc, "VIII. Conclusion")
    add_body(
        doc,
        "The project now has a readable NIST Ascon-AEAD128 RTL core, an explicit streaming "
        "protocol, an authentication-safe decryption contract, official-vector tests, and "
        "a reproducible Vivado setup. Portable simulation gives evidence that the algorithm "
        "and boundary handling are correct. The next measured step is to run the prepared "
        "Vivado flow, record utilization and post-route timing, and test the four-vector "
        "demonstration on the Nexys A7 board.",
    )

    add_heading(doc, "References")
    references = [
        "[1] M. S. Turan, K. A. McKay, D. Chang, J. Kang, and J. Kelsey, “Ascon-Based Lightweight Cryptography Standards for Constrained Devices,” NIST SP 800-232, Aug. 2025, doi: 10.6028/NIST.SP.800-232.",
        "[2] Ascon Team, “ascon-c: Reference and optimized implementations of Ascon,” commit 446347f21b209f3921c65ece70027c366cbe1693. [Online]. Available: https://github.com/ascon/ascon-c",
        "[3] A. Kandi et al., “Hardware Implementation of ASCON,” NIST Lightweight Cryptography Workshop, June 2023.",
        "[4] K. Liu, L. Han, and Z. Quan, “A High Performance Ascon Architecture for Data Encryption and Authentication,” in Proc. 5th Int. Conf. on Cryptography, Network Security and Communication Technology (CNSCT 2026), Haikou, China, Jan. 23–25, 2026, doi: 10.1145/3802927.3802941.",
        "[5] N. T. M. Huong, T. V. Nam, and P. V. Phat, “Application of the Ascon-AEAD128 Algorithm for IoT Data Security,” 11th Int. Conf. on Applying New Technology in Green Buildings, 2026, doi: 10.1109/ATIGB70203.2026.11628316.",
        "[6] Digilent, “Nexys A7-100T Master XDC.” [Online]. Available: https://github.com/Digilent/digilent-xdc",
    ]
    for ref in references:
        p = doc.add_paragraph()
        p.paragraph_format.left_indent = Inches(0.22)
        p.paragraph_format.first_line_indent = Inches(-0.22)
        p.paragraph_format.space_after = Pt(1.5)
        p.alignment = WD_ALIGN_PARAGRAPH.LEFT
        r = p.add_run(ref)
        r.font.size = Pt(8.2)

    core = doc.core_properties
    core.title = "VHDL Implementation of NIST Ascon AEAD128 on a Nexys A7 FPGA"
    core.author = "Kroix Jones"
    core.subject = "Undergraduate research with Professor Wenjie Che"
    core.keywords = "Ascon-AEAD128, VHDL, FPGA, Nexys A7, authenticated encryption"
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    doc.save(OUTPUT)
    print(OUTPUT)


if __name__ == "__main__":
    build()
