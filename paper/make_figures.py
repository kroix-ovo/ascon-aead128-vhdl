"""Architecture figures for the Ascon-AEAD128 paper.

Run from the repository root:  python paper/make_figures.py
Writes 300 dpi PNGs to paper/assets/v2/.  Every figure is drawn from the RTL
in rtl/ascon_aead128_core.vhd and rtl/ascon_permutation.vhd; gray fill marks
the logic that changed relative to the previous architecture.
"""

from pathlib import Path
from io import BytesIO
from PIL import Image

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyArrowPatch, FancyBboxPatch, Rectangle

OUT = Path(__file__).resolve().parent / "assets" / "v2"
plt.rcParams.update({
    "font.family": "serif",
    "font.serif": ["Times New Roman", "DejaVu Serif"],
    "font.size": 9,
})
CHANGED = "#d9d9d9"
LIGHT = "#f2f2f2"


def canvas(w, h):
    fig, ax = plt.subplots(figsize=(w, h))
    ax.set_xlim(-0.12, w + 0.12)
    ax.set_ylim(-0.12, h + 0.12)
    ax.axis("off")
    return fig, ax


def box(ax, x, y, w, h, title, lines=(), fill="white", dashed=False, round_=True,
        title_size=8.6, line_size=7.3, lw=1.1):
    style = "round,pad=0.02,rounding_size=0.06" if round_ else "square,pad=0"
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle=style, fc=fill, ec="black",
                                lw=lw, ls="--" if dashed else "-"))
    n = len(lines)
    top = y + h / 2 + (n * 0.155) / 2 + 0.07
    ax.text(x + w / 2, top if n else y + h / 2, title, ha="center", va="center",
            fontsize=title_size, fontweight="bold")
    for i, line in enumerate(lines):
        ax.text(x + w / 2, top - 0.2 - i * 0.155, line, ha="center", va="center",
                fontsize=line_size)
    return (x, y, w, h)


def arrow(ax, p, q, label=None, rad=0.0, lpos=0.5, loff=(0, 0.1), dashed=False,
          size=7.0, lw=1.0, both=False, ha="center", color="black"):
    ax.add_patch(FancyArrowPatch(p, q, arrowstyle="<|-|>" if both else "-|>",
                                 mutation_scale=10, lw=lw, color=color,
                                 ls="--" if dashed else "-",
                                 connectionstyle=f"arc3,rad={rad}",
                                 shrinkA=1, shrinkB=1))
    if label:
        mx = p[0] + (q[0] - p[0]) * lpos + loff[0]
        my = p[1] + (q[1] - p[1]) * lpos + loff[1]
        ax.text(mx, my, label, ha=ha, va="center", fontsize=size,
                bbox=dict(fc="white", ec="none", pad=0.6))


def poly(ax, pts, label=None, lpos=None, dashed=False, size=7.0, lw=1.0, color="black"):
    """Orthogonal connector through pts, arrowhead on the last segment."""
    xs, ys = zip(*pts)
    ax.plot(xs[:-1], ys[:-1], color=color, lw=lw, ls="--" if dashed else "-",
            solid_capstyle="butt")
    arrow(ax, pts[-2], pts[-1], dashed=dashed, lw=lw, color=color)
    if label and lpos:
        ax.text(lpos[0], lpos[1], label, ha="center", va="center", fontsize=size,
                bbox=dict(fc="white", ec="none", pad=0.6))


def save(fig, name):
    OUT.mkdir(parents=True, exist_ok=True)
    # Draw directly at a resolution that supports the requested seven-inch
    # insertion. Cropping can otherwise reduce a nominal 300-dpi canvas below
    # 2100 pixels. No color is needed in these print diagrams.
    dpi = 300
    while True:
        buffer = BytesIO()
        fig.savefig(buffer, format="png", dpi=dpi, bbox_inches="tight", pad_inches=0.07)
        buffer.seek(0)
        im = Image.open(buffer).convert("L")
        if im.width >= 2100:
            break
        dpi = int(dpi * 2100 / im.width) + 1
    im.save(OUT / f"{name}.png", dpi=(300, 300))
    plt.close(fig)


# --------------------------------------------------------------------------
# Fig. 2 (revised): original one-round core.  The controller and the
# permutation each own a 320-bit register, joined by start/done.
def fig_original_architecture():
    fig, ax = canvas(7.95, 3.85)
    ax.add_patch(Rectangle((1.5, 0.3), 4.35, 3.45, fill=False, ls=":", lw=0.9))
    ax.text(1.57, 3.64, "ascon_aead128_core", fontsize=7.2, style="italic", va="center")

    box(ax, 0.0, 2.55, 1.3, 0.85, "Command", ["key, nonce, mode", "valid / ready"])
    box(ax, 0.0, 1.25, 1.3, 1.0, "Input stream", ["128-bit AD or payload",
                                                  "keep[15:0], last", "valid / ready"])
    box(ax, 1.75, 0.7, 1.85, 2.7, "AEAD controller", [
        "phase FSM (Fig. 3)", "byte mask, 0x01 padding", "domain separation",
        "key XORs", "tag compare, zeroize", "", "state register S (320 b)"])
    box(ax, 4.4, 1.75, 1.25, 1.55, "Permutation", [
        "own register P (320 b)", "1 round per clock", "round counter", "p12 or p8"])
    box(ax, 6.25, 2.6, 1.3, 0.8, "Payload out", ["data, keep, last", "valid / ready"])
    box(ax, 6.25, 1.5, 1.3, 0.8, "Tag port", ["enc: tag out", "dec: tag in"])
    box(ax, 6.25, 0.15, 1.3, 0.85, "Quarantine", ["external buffer,", "release on commit"],
        dashed=True)

    arrow(ax, (1.3, 2.97), (1.75, 2.97))
    arrow(ax, (1.3, 1.75), (1.75, 1.75))
    arrow(ax, (3.6, 2.95), (4.4, 2.95), "start, S", loff=(0, 0.11))
    arrow(ax, (4.4, 2.1), (3.6, 2.1), "done, P", loff=(0, -0.12))
    poly(ax, [(3.3, 3.4), (3.3, 3.57), (6.05, 3.57), (6.05, 3.0), (6.25, 3.0)],
         "payload beats", lpos=(4.98, 3.57))
    poly(ax, [(3.6, 1.3), (6.05, 1.3), (6.05, 1.9), (6.25, 1.9)], "enc tag", lpos=(4.9, 1.3))
    poly(ax, [(6.25, 1.67), (5.85, 1.67), (5.85, 1.08), (3.6, 1.08)], "dec tag", lpos=(4.9, 1.08))
    poly(ax, [(2.3, 0.7), (2.3, 0.5), (6.25, 0.5)], "commit / discard", lpos=(4.25, 0.5))
    poly(ax, [(7.55, 3.0), (7.72, 3.0), (7.72, 0.72), (7.55, 0.72)])
    ax.text(7.8, 1.85, "decrypted bytes", rotation=90, fontsize=6.8, va="center")
    ax.text(1.55, 0.12, "Each permutation: S is loaded into P on start; P is copied "
            "back to S after done.", ha="left", fontsize=7.0, style="italic")
    save(fig, "fig02_original_architecture")


# --------------------------------------------------------------------------
# Fig. 3 (revised): original controller FSM after the AD-padding fix.
def fig_original_fsm():
    fig, ax = plt.subplots(figsize=(8.15, 5.6))
    ax.set_xlim(-0.35, 7.95)
    ax.set_ylim(-0.4, 5.6)
    ax.axis("off")
    W, H = 1.45, 0.6
    col = [0.0, 2.05, 4.1, 6.15]
    row = [4.5, 3.1, 1.7, 0.3]
    S = {}

    def st(key, c, r, title, sub, fill="white"):
        S[key] = (col[c], row[r])
        box(ax, col[c], row[r], W, H, title, [sub], fill=fill, title_size=7.0 if key == "zero" else 8.0,
            line_size=6.9)

    def at(k, dx, dy):
        x, y = S[k]
        return (x + dx, y + dy)

    st("idle", 0, 0, "IDLE", "await command")
    st("init", 1, 0, "INIT start/wait", "p12, then key XOR")
    st("adw", 2, 0, "AD WAIT", "check kind, keep, last")
    st("adp", 3, 0, "AD p8 start/wait", "absorb one AD block")
    st("done", 0, 1, "DONE", "pulse done")
    st("msgw", 2, 1, "MSG WAIT", "XOR or replace rate")
    st("pad", 3, 1, "AD PAD start/wait", "padded block, p8")
    st("tout", 0, 2, "TAG OUT", "encryption tag")
    st("fin", 1, 2, "FINAL start/wait", "key XOR, p12, tag")
    st("out", 2, 2, "MSG OUTPUT", "hold beat in stalls")
    st("mp8", 3, 2, "MSG p8 start/wait", "after a full block")
    st("zero", 0, 3, "ZEROIZE", "clear all storage")
    st("tin", 1, 3, "TAG IN", "compare tag")

    arrow(ax, at("idle", W, 0.3), at("init", 0, 0.3), "command", loff=(0, 0.11))
    arrow(ax, at("init", W, 0.3), at("adw", 0, 0.3))
    arrow(ax, at("adw", W, 0.42), at("adp", 0, 0.42), "AD beat", loff=(0, 0.1))
    arrow(ax, at("adp", 0.45, H), at("adw", W - 0.45, H), rad=0.55)
    ax.text(col[3] - 0.3, row[0] + H + 0.5, "more AD", ha="center", fontsize=7.0)
    arrow(ax, at("adp", 1.15, 0), at("pad", 1.15, H), "last full", lpos=0.5, loff=(0.07, 0), ha="left")
    fix = "#5a5a5a"
    poly(ax, [at("adw", W, 0.16), (col[3] - 0.15, row[0] + 0.16),
              (col[3] - 0.15, row[1] + 0.45), at("pad", 0, 0.45)], color=fix, lw=1.6)
    ax.text(col[3] - 0.22, row[0] - 0.3, "empty last after AD (fixed)", ha="right",
            fontsize=6.9, color=fix, bbox=dict(fc="white", ec="none", pad=0.4))
    poly(ax, [at("adp", 0.3, 0), (col[3] + 0.3, row[0] - 0.62),
              (col[2] + 1.2, row[0] - 0.62), at("msgw", 1.2, H)])
    ax.text(col[3] + 0.37, row[0] - 0.3, "last partial:\nDSEP", ha="left", va="center",
            fontsize=6.9)
    arrow(ax, at("pad", 0, 0.18), at("msgw", W, 0.18), "DSEP", loff=(0, 0.1))
    arrow(ax, at("adw", 0.3, 0), at("msgw", 0.3, H), "empty AD: DSEP only", lpos=0.45,
          loff=(-0.32, 0), ha="right")
    arrow(ax, at("msgw", 0.3, 0), at("out", 0.3, H), "payload beat", lpos=0.5,
          loff=(-0.32, 0), ha="right")
    poly(ax, [at("mp8", 0.8, H), (col[3] + 0.8, row[2] + H + 0.22),
              (col[2] + 1.2, row[2] + H + 0.22), at("msgw", 1.2, 0)],
         "not last", lpos=(col[3] + 0.25, row[2] + H + 0.22))
    arrow(ax, at("out", W, 0.3), at("mp8", 0, 0.3), "full", loff=(0, 0.1))
    arrow(ax, at("out", 0, 0.3), at("fin", W, 0.3), "partial", loff=(0, 0.1))
    poly(ax, [at("msgw", 0, 0.3), (col[1] + 1.05, row[1] + 0.3), at("fin", 1.05, H)],
         "empty last: pad", lpos=(col[1] + 0.95, row[1] + 0.3))
    poly(ax, [at("mp8", 0.8, 0), (col[3] + 0.8, row[2] - 0.32),
              (col[1] + 1.25, row[2] - 0.32), at("fin", 1.25, 0)],
         "last full: pad block", lpos=(col[2] + 0.75, row[2] - 0.32))
    arrow(ax, at("fin", 0.4, 0), at("tin", 0.4, H), "decrypt", lpos=0.4, loff=(-0.05, 0),
          ha="right")
    arrow(ax, at("fin", 0, 0.3), at("tout", W, 0.3), "encrypt", loff=(0, 0.1))
    arrow(ax, at("tout", 0.78, 0), at("zero", 0.78, H))
    arrow(ax, at("tin", 0, 0.3), at("zero", W, 0.3))
    poly(ax, [at("zero", 0, 0.3), (-0.2, row[3] + 0.3), (-0.2, row[1] + 0.3),
              at("done", 0, 0.3)])
    arrow(ax, at("done", 0.78, H), at("idle", 0.78, 0), "next command", lpos=0.5,
          loff=(0.08, 0), ha="left")
    ax.text(3.75, -0.2, "START states request one permutation; WAIT states hold until its "
            "registered done.  TAG IN pulses commit or discard.\nProtocol errors in "
            "AD WAIT or MSG WAIT go to ZEROIZE (not drawn).  Gray: transition added "
            "by the AD padding fix.", ha="center", va="center", fontsize=6.8,
            style="italic")
    save(fig, "fig03_original_fsm")


# --------------------------------------------------------------------------
# New: buffered three-round core (Section XIII).
def fig_buffered_architecture():
    fig, ax = canvas(7.62, 3.55)
    ax.add_patch(Rectangle((1.3, 0.2), 5.0, 3.2, fill=False, ls=":", lw=0.9))
    ax.text(1.37, 3.29, "G_ROUNDS_PER_CYCLE = 3,  G_BUFFERING_ENABLE = true",
            fontsize=7.0, style="italic", va="center")

    box(ax, 0.0, 1.55, 1.05, 0.95, "Input stream", ["data, kind", "keep, last"])
    box(ax, 1.5, 1.4, 1.1, 1.25, "Input FIFO", ["2 entries:", "data, kind,", "keep, last"],
        fill=CHANGED)
    box(ax, 2.95, 1.05, 1.6, 1.95, "AEAD controller", [
        "same phase FSM", "state register S", "launches p8 on the",
        "output-enqueue edge"], fill=CHANGED)
    box(ax, 2.95, 0.35, 1.6, 0.5, "Tag and commit", [], title_size=8.0)
    box(ax, 4.95, 1.85, 1.2, 1.3, "Permutation", ["register P", "3 rounds per clock",
                                                 "p8 = 3+3+2", "p12 = 3+3+3+3"],
        fill=CHANGED)
    box(ax, 4.95, 0.65, 1.2, 0.95, "Output FIFO", ["2 entries:", "data, keep, last"],
        fill=CHANGED)
    box(ax, 6.65, 0.65, 0.85, 0.95, "Quarantine", [], dashed=True, title_size=7.8)

    arrow(ax, (1.05, 2.02), (1.5, 2.02))
    arrow(ax, (2.6, 2.02), (2.95, 2.02), "head", loff=(0, 0.1))
    arrow(ax, (4.55, 2.8), (4.95, 2.8), "start", loff=(0, 0.1))
    arrow(ax, (4.95, 2.15), (4.55, 2.15), "done", loff=(0, -0.11))
    arrow(ax, (4.55, 1.25), (4.95, 1.25), "push", loff=(0, 0.1))
    arrow(ax, (6.15, 1.12), (6.65, 1.12))
    arrow(ax, (3.75, 1.05), (3.75, 0.85))
    poly(ax, [(4.55, 0.5), (7.07, 0.5), (7.07, 0.65)], "commit / discard",
         lpos=(5.55, 0.5))
    ax.text(3.8, 0.02, "Every port follows ready/valid rules: unaccepted data is held, "
            "and a full queue is never overwritten.", ha="center", fontsize=7.0,
            style="italic")
    save(fig, "fig_xiii_buffered_architecture")


# --------------------------------------------------------------------------
# New: the three-round combinational chain and round grouping.
def fig_round_chain():
    fig, ax = canvas(7.8, 3.15)
    box(ax, 0.1, 1.65, 0.8, 0.85, "P", ["320-bit", "register"], round_=False,
        title_size=9, line_size=7.1)
    xs = [1.3, 2.75, 4.2]
    for i, x in enumerate(xs):
        box(ax, x, 1.65, 1.1, 0.85, f"round lane {i}",
            ["S-box + diffusion", "round constant"], title_size=8.3, line_size=7.1)
    box(ax, 5.75, 1.65, 0.65, 0.85, "load\nmux", round_=False, title_size=8)
    for start, end in [(0.9, 1.3), (2.4, 2.75), (3.85, 4.2), (5.3, 5.75)]:
        arrow(ax, (start, 2.075), (end, 2.075))
    poly(ax, [(6.4, 2.075), (6.62, 2.075), (6.62, 2.85), (0.5, 2.85), (0.5, 2.5)],
         "next P on clock edge", lpos=(3.4, 2.85), size=7.5)
    arrow(ax, (7.1, 1.85), (6.4, 1.85))
    ax.text(7.13, 1.85, "S on start", va="center", fontsize=7.2)
    ax.text(4.75, 1.38, "lane 2 bypassed on the p8 tail", ha="center", fontsize=7.1)
    for y, name, groups in [(0.72, "p8 round indices", ["4-6", "7-9", "10-11"]),
                             (0.18, "p12 round indices", ["0-2", "3-5", "6-8", "9-11"])]:
        ax.text(0.1, y + 0.15, name, va="center", fontsize=8)
        for i, label in enumerate(groups):
            x = 2.05 + i * 1.02
            ax.add_patch(Rectangle((x, y), 0.95, 0.3, fc=CHANGED if label == "10-11" else "white", ec="black", lw=0.9))
            ax.text(x + 0.475, y + 0.15, label, ha="center", va="center", fontsize=8)
    ax.text(6.45, 0.6, "one box\n= one clock", ha="center", va="center", fontsize=7.5)
    save(fig, "fig_xiii_round_chain")


# --------------------------------------------------------------------------
# New: folded core datapath (Section XIV).
def fig_fold_architecture():
    fig, ax = canvas(7.7, 4.6)
    box(ax, 0.25, 2.0, 0.58, 2.0, "load\nmux", ["HOLD", "R3", "TAIL", "XF"],
        round_=False, title_size=7.8, line_size=7)
    box(ax, 1.2, 3.0, 0.8, 0.8, "S", ["320 bits"], fill=CHANGED, round_=False, title_size=9)
    for i, x in enumerate([2.45, 3.9, 5.35]):
        box(ax, x, 3.15, 1.0, 0.5, f"lane {i}", title_size=8.5)
    for a, b in [(0.83, 1.2), (2.0, 2.45), (3.45, 3.9), (4.9, 5.35)]:
        arrow(ax, (a, 3.4), (b, 3.4))
    poly(ax, [(6.35, 3.4), (6.6, 3.4), (6.6, 4.25), (0.54, 4.25), (0.54, 4.0)],
         "R3", lpos=(3.4, 4.25), size=8)
    box(ax, 1.2, 1.75, 1.5, 0.8, "XOR-only leg", ["command, key, DSEP", "absorb fallback"], title_size=8.2)
    arrow(ax, (1.2, 2.15), (0.83, 2.15), "XF", loff=(0, 0.12))
    box(ax, 3.35, 1.75, 1.65, 0.8, "Tail absorb", ["encrypt: XOR", "decrypt: replace rate"], fill=CHANGED, title_size=8.3)
    arrow(ax, (4.4, 3.15), (4.4, 2.55), "R2", loff=(0.15, 0))
    poly(ax, [(3.35, 2.35), (3.1, 2.35), (3.1, 2.78), (0.83, 2.78)],
         "TAIL", lpos=(2.45, 2.78), size=7.5)
    box(ax, 1.2, 0.35, 1.5, 0.65, "Input queue", ["2 entries, decoded"], fill=CHANGED, title_size=8.3)
    arrow(ax, (1.95, 1.0), (1.95, 1.75))
    poly(ax, [(2.7, 0.68), (3.8, 0.68), (3.8, 1.75)], "head", lpos=(3.3, 0.68))
    box(ax, 5.45, 1.65, 1.8, 0.95, "Output tap and queue", ["rate before absorb XOR data", "mask valid bytes; 2 entries"], title_size=8.0, line_size=7.0)
    poly(ax, [(4.7, 3.15), (5.15, 3.15), (5.15, 2.35), (5.45, 2.35)])
    ax.text(5.2, 3.02, "R2 rate", ha="center", fontsize=7.1, va="top")
    poly(ax, [(2.7, 0.5), (6.3, 0.5), (6.3, 1.65)], "queued data / keep / last", lpos=(5.4, 0.5), size=7.2)
    arrow(ax, (7.25, 2.1), (7.65, 2.1))
    ax.text(7.35, 1.0, "provisional\noutput", ha="center", fontsize=7.1)
    ax.text(0.25, 0.05, "Output fallback selects the rate from S. Tag, command and controller wiring are omitted.", fontsize=7.2)

    save(fig, "fig_xiv_fold_architecture")


# --------------------------------------------------------------------------
# New: clock-by-clock steady-state schedule per full payload block.
def fig_block_schedule():
    rows = [
        ("1 round / clock", ["A", "O", "L"] + ["r"] * 8 + ["C"], "12"),
        ("3 rounds / clock", ["A", "O", "L", "R3", "R3", "R2", "C"], "7"),
        ("3 rounds + FIFOs", ["A", "L+O", "R3", "R3", "R2", "C"], "6"),
        ("folded absorb", ["R3", "R3", "T"], "3"),
    ]
    fig, ax = canvas(7.2, 2.35)
    cw, rh, x0 = 0.42, 0.34, 1.45
    for c in range(12):
        ax.text(x0 + c * cw + cw / 2, 2.15, str(c + 1), ha="center", fontsize=7.4)
    ax.text(x0 + 12 * cw + 0.35, 2.15, "clocks", ha="center", fontsize=7.4)
    for r, (name, cells, total) in enumerate(rows):
        y = 1.7 - r * 0.45
        ax.text(0.0, y + rh / 2, name, va="center", fontsize=8.2)
        for c, cell in enumerate(cells):
            rounds = cell.startswith(("R", "r", "T"))
            fill = "white" if not rounds else (CHANGED if cell == "T" else LIGHT)
            ax.add_patch(Rectangle((x0 + c * cw, y), cw, rh, fc=fill, ec="black", lw=0.8,
                                   hatch="///" if not rounds else None))
            ax.text(x0 + c * cw + cw / 2, y + rh / 2, cell, ha="center", va="center",
                    fontsize=7.2, bbox=dict(fc="white", ec="none", pad=0.3)
                    if not rounds else None)
        ax.text(x0 + 12 * cw + 0.35, y + rh / 2, total, ha="center", va="center",
                fontsize=8.6, fontweight="bold")
    ax.text(0.0, -0.08,
            "Hatched: no round work.  A absorb (XOR, mask, pad); O output handshake; "
            "L launch (copy S into P); C completion (copy P back);\n"
            "r one round; R3/R2 three or two rounds; T two tail rounds plus absorption "
            "of the next block.  Measured with always-ready traffic.",
            fontsize=7.0, va="top")
    save(fig, "fig_xiv_block_schedule")


# --------------------------------------------------------------------------
# New: folded-core controller (states of ascon_aead128_fold).
def self_loop(ax, x, y, label, side="right", color="black"):
    """Loop on the right edge of a box at x, between heights y and y - 0.3."""
    p, q = (x, y), (x, y - 0.3)
    ax.add_patch(FancyArrowPatch(p, q, arrowstyle="-|>", mutation_scale=10, lw=1.0,
                                 color=color, connectionstyle="arc3,rad=-1.9",
                                 shrinkA=1, shrinkB=1))
    ax.text(x + 0.38, y - 0.15, label, ha="left", va="center", fontsize=6.8)


def fig_fold_fsm():
    fig, ax = plt.subplots(figsize=(8.45, 3.75))
    ax.set_xlim(-0.35, 8.8)
    ax.set_ylim(-0.65, 3.6)
    ax.axis("off")
    W, H = 1.4, 0.6
    col = [0.0, 1.85, 3.7, 5.55]
    row = [2.75, 1.5, 0.25]
    S = {}

    def st(key, c, r, title, sub, fill="white"):
        S[key] = (col[c], row[r])
        box(ax, col[c], row[r], W, H, title, [sub], fill=fill, title_size=7.0 if key == "zero" else 8.0,
            line_size=6.9)

    def at(k, dx, dy):
        x, y = S[k]
        return (x + dx, y + dy)

    st("idle", 0, 0, "F_IDLE", "load IV, key, nonce")
    st("init", 1, 0, "F_INIT", "p12 as 4 x R3")
    st("adabs", 2, 0, "F_AD_ABS", "absorb-only clock")
    st("adp8", 3, 0, "F_AD_P8", "R3, R3, TAIL")
    st("mabs", 2, 1, "F_MSG_ABS", "absorb-only clock")
    st("mp8", 3, 1, "F_MSG_P8", "R3, R3, TAIL", fill=CHANGED)
    st("fin", 2, 2, "F_FINAL", "p12 as 4 x R3, tag")
    st("tag", 1, 2, "F_TAG_OUT / IN", "tag gated in decrypt")
    st("zero", 0, 2, "F_ZEROIZE, DONE", "clear storage")

    arrow(ax, at("idle", W, 0.3), at("init", 0, 0.3), "command", loff=(0, 0.1))
    arrow(ax, at("init", W, 0.3), at("adabs", 0, 0.3), "AD pending", loff=(0, 0.1))
    arrow(ax, at("adabs", W, 0.42), at("adp8", 0, 0.42))
    arrow(ax, at("adp8", 0.3, H), at("adabs", W - 0.3, H), rad=0.6)
    ax.text(col[3] - 0.15, row[0] + H + 0.27, "next AD not queued", ha="center",
            fontsize=6.8)
    self_loop(ax, col[3] + W, row[0] + 0.45, "next AD or pad\nblock folded")
    poly(ax, [at("init", 0.75, 0), (col[1] + 0.75, row[1] + 0.45), at("mabs", 0, 0.45)])
    ax.text(col[1] + 0.82, row[1] + 0.85, "empty AD\nseen in p12", ha="center",
            fontsize=6.8, bbox=dict(fc="white", ec="none", pad=0.4))
    arrow(ax, at("adp8", 0.3, 0), at("mabs", W - 0.2, H), "AD done;\nwait",
          lpos=0.55, loff=(-0.4, 0.05), size=6.8)
    arrow(ax, at("adp8", 1.1, 0), at("mp8", 1.1, H), "DSEP, fold\nfull payload",
          lpos=0.5, loff=(0.5, 0), size=6.8)
    poly(ax, [at("adabs", 0.28, 0), (col[2] + 0.28, row[1] + H)],
         "empty AD", lpos=(col[2] + 0.25, row[1] + H + 0.3), size=6.7)
    poly(ax, [at("adp8", W, 0.08), (8.5, row[0] + 0.08),
              (8.5, 0.1), (col[2] + W - 0.15, 0.1), at("fin", W - 0.15, 0)],
         "AD done; fold partial / empty payload", lpos=(6.2, -0.01), size=6.7)
    arrow(ax, at("mabs", W, 0.42), at("mp8", 0, 0.42), "full", loff=(0, 0.1), size=6.6)
    arrow(ax, at("mp8", 0, 0.16), at("mabs", W, 0.16), "stall", loff=(0, -0.1), size=6.6)
    self_loop(ax, col[3] + W, row[1] + 0.45, "next block folded\n(steady state)")
    arrow(ax, at("mabs", 0.5, 0), at("fin", 0.5, H), "partial or\nempty last",
          lpos=0.5, loff=(-0.42, 0), size=6.8)
    poly(ax, [at("mp8", 0.75, 0), (col[3] + 0.75, row[2] + 0.3), at("fin", W, 0.3)],
         "last full / next partial", lpos=(col[3] + 0.45, row[2] + 0.3))
    arrow(ax, at("fin", 0, 0.3), at("tag", W, 0.3))
    arrow(ax, at("tag", 0, 0.3), at("zero", W, 0.3))
    arrow(ax, at("zero", 0.75, H), at("idle", 0.75, 0), "next command", lpos=0.5,
          loff=(0.08, 0), ha="left")
    ax.text(3.7, -0.43, "Absorb-only states handle first beats and tail fallback. Group advances, waits and errors are omitted; errors enter F_ZEROIZE.",
            ha="center", fontsize=6.8, style="italic")
    save(fig, "fig_xiv_fold_fsm")


if __name__ == "__main__":
    fig_original_architecture()
    fig_original_fsm()
    fig_buffered_architecture()
    fig_round_chain()
    fig_fold_architecture()
    fig_block_schedule()
    fig_fold_fsm()
    print("wrote", sorted(p.name for p in OUT.glob("*.png")))
