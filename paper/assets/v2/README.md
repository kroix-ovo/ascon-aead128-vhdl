# Print figures

Regenerate from the repository root with `python paper/make_figures.py`, then
rebuild the Word report with `python paper/build_paper.py`. The generator needs
Matplotlib and Pillow; the report builder uses python-docx. It does not run
simulation, synthesis or hardware programming.

Each PNG is grayscale with 300-dpi metadata and at least 2,100 pixels across,
so insertion at seven inches retains at least 300 pixels per inch. Gray fill
identifies changed logic. Hatching identifies schedule clocks without rounds.
The report captions describe omitted control wiring and grouped FSM states.

| Figure | File | Report section |
|---|---|---|
| 2 | fig02_original_architecture.png | III |
| 3 | fig03_original_fsm.png | V |
| 4 | fig_xiii_round_chain.png | XIII.A |
| 5 | fig_xiii_buffered_architecture.png | XIII.A |
| 6 | fig_xiv_block_schedule.png | XIII.E |
| 7 | fig_xiv_fold_architecture.png | XIV.A |
| 8 | fig_xiv_fold_fsm.png | XIV.A |

Figures 2 and 3 show the original engine with the later AD-padding and tag
output fixes. Figures 4–6 describe its unrolling and buffering. Figures 7 and 8
show `ascon_aead128_fold`. The original PNGs in the parent assets directory are
retained as historical files and are no longer inserted as Figures 2 and 3.

The diagrams were checked against `rtl/ascon_aead128_core.vhd` and
`rtl/ascon_permutation.vhd`. Schedule counts come from the saved baseline and
fold studies. The +1.373 ns result discussed in XIV.A is the state-to-output-queue
path class, not an independent timing measurement of every tail path.
