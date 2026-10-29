# Ascon research report

The Word and PDF report in this directory includes the dependent p8 pipeline
experiment, controller fixes, folded multicore study and architecture diagrams.
Report updates are published on main as well as the relevant experiment branch.

The report studies multiple implementation snapshots. The experimental RTL is on
[ascon-p8-pipeline](https://github.com/kroix-ovo/ascon-aead128-vhdl/tree/ascon-p8-pipeline)
and [ascon-fold-multicore](https://github.com/kroix-ovo/ascon-aead128-vhdl/tree/ascon-fold-multicore).
The folded absorption and controller security fixes are on
[ascon-weight-stream-fold-absorb](https://github.com/kroix-ovo/ascon-aead128-vhdl/tree/ascon-weight-stream-fold-absorb).
The report's references to those implementations do not claim that main's RTL
contains the experimental changes. Source hashes and branch references identify
each measured design.

Regenerate the report with `python paper/build_paper.py` (python-docx).
The builder uses preserved evidence; it does not rerun simulations or routing.
Generate diagrams with `python paper/make_figures.py` and
`python paper/make_experiment_figures.py` (Matplotlib and Pillow).
The pipeline summary, full-adapter simulation, routed timing, assumed memory
service and bounded physical fixture remain distinct evidence scopes.
