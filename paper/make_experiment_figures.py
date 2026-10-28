"""Draw the pipeline and multicore experiments with the repository figure tool.

Run python paper/make_experiment_figures.py. Uses make_figures.py primitives;
does not regenerate or alter the earlier figures. PNGs are print resolution.
"""
from make_figures import canvas, box, arrow, poly, save, CHANGED


def pipeline_rounds():
    fig, ax = canvas(8.0, 5.5)
    rows = [
        (4.3, 'A and A_ctrl2', [('Constant + S-box + diffusion', 'writes P on one edge')], '12 clocks per block'),
        (2.7, 'B and D', [('Constant + S-box', 'sbox_reg 320 b'), ('Diffusion', 'writes P on second edge')], '20 clocks per block'),
        (1.1, 'C', [('Constant + input XORs', 's1_reg 320 b'), ('Chi + output XORs', 's2_reg 320 b'), ('Diffusion', 'writes P on third edge')], '28 clocks per block'),
    ]
    for y, name, stages, cycles in rows:
        ax.text(0, y + .87, name, weight='bold', fontsize=10)
        box(ax, 0, y, 1.15, .65, 'P register', ['320-bit state'], title_size=8)
        n = len(stages)
        width = (6.4 - .28 * (n - 1)) / n
        for i, (title, detail) in enumerate(stages):
            x = 1.5 + i * (width + .28)
            box(ax, x, y, width, .65, title, [detail], fill=CHANGED if n > 1 else 'white', title_size=7.8)
            arrow(ax, (1.15 if i == 0 else x-.28, y+.325), (x, y+.325))
        poly(ax, [(7.9, y+.325), (8.0, y+.325), (8.0, y-.23), (.58, y-.23), (.58, y)])
        ax.text(4.1, y-.40, 'Completed round feeds the next round; repeat eight times for p8', ha='center', fontsize=7.8)
        ax.text(7.9, y+.87, cycles, ha='right', fontsize=9)
    ax.text(4, .12, 'Block schedule: accept/absorb + output + load + 8 dependent rounds + capture', ha='center', fontsize=9)
    save(fig, 'fig_xv_pipeline_rounds')


def pipeline_control():
    fig, ax = canvas(8.0, 3.7)
    box(ax, 0, 2.5, 1.2, .8, 'Input beat', ['data, keep, last'])
    box(ax, 1.65, 2.5, 2.0, .8, 'Local keep decode', ['per-lane masks and enables'], fill=CHANGED)
    box(ax, 4.15, 2.5, 1.6, .8, 'Core state S', ['320-bit register'])
    box(ax, 6.2, 2.5, 1.65, .8, 'Round engine P', ['unchanged one-round', '320-bit register'])
    arrow(ax, (1.2, 2.9), (1.65, 2.9))
    arrow(ax, (3.65, 2.9), (4.15, 2.9))
    arrow(ax, (5.75, 3.03), (6.2, 3.03))
    arrow(ax, (6.2, 2.73), (5.75, 2.73))
    box(ax, 1.65, .75, 2.0, .85, 'One-hot controller', ['same external schedule'], fill=CHANGED)
    box(ax, 4.15, .75, 1.6, .85, 'Tree tag compare', ['5 logic levels'], fill=CHANGED)
    box(ax, 6.2, .75, 1.65, .85, 'Authentication', ['commit or discard'])
    poly(ax, [(2.65, 1.6), (2.65, 2.15), (3.9, 2.15), (3.9, 2.7), (4.15, 2.7)])
    arrow(ax, (4.95, 2.5), (4.95, 1.6))
    arrow(ax, (5.75, 1.17), (6.2, 1.17))
    ax.text(4, .22, 'A_ctrl1: local decode. A_ctrl2: all three gray changes. D: same fixes with B round engine.', ha='center', fontsize=8.7)
    save(fig, 'fig_xv_pipeline_control')


def multicore():
    fig, ax = canvas(8.0, 5.1)
    box(ax, 0, 3.75, 1.6, .85, 'Layer source', ['12 authenticated chunks', 'scatter/gather views'])
    box(ax, 2.0, 3.75, 3.5, .85, 'Shared input arbitration and framing', ['128 bits per clock across all lanes', '96-byte AD and unique nonce per chunk'])
    arrow(ax, (1.6, 4.17), (2.0, 4.17))
    box(ax, 5.9, 3.75, 2.0, .85, 'Transaction control', ['key, identity, length', 'abort / reset / status'])
    for i, x in enumerate([0, 2.1, 4.2, 6.3]):
        box(ax, x, 1.7, 1.6, 1.2, f'Lane {i}', ['RX boundary queue', 'folded 3+3+2 core', 'TX boundary queue'], fill=CHANGED, title_size=9)
        poly(ax, [(3.75, 3.75), (3.75, 3.3), (x+.8, 3.3), (x+.8, 2.9)])
        poly(ax, [(6.9, 3.75), (6.9, 3.07), (x+1.35, 3.07), (x+1.35, 2.9)], dashed=True, lw=.7)
        poly(ax, [(x+.8, 1.7), (x+.8, 1.3), (3.75, 1.3), (3.75, 1.0)])
    box(ax, 2.0, .2, 3.5, .8, 'Shared output collector', ['128 bits per clock; chunk and offset retained'])
    box(ax, 5.9, .2, 2.0, .8, 'Trusted quarantine', ['release only on commit', 'invalidate on discard'])
    arrow(ax, (5.5, .6), (5.9, .6))
    ax.text(.0, .6, 'G_CORES = 1, 2 or 4\nFour lanes shown', fontsize=8.3, va='center')
    ax.text(4, 4.91, 'Independent chunks run concurrently; each lane reuses its folded round chain', ha='center', fontsize=9)
    save(fig, 'fig_xvi_multicore')


if __name__ == '__main__':
    import argparse
    from pathlib import Path
    import make_figures
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path, help='Override paper/assets/v2')
    parser.add_argument('--pipeline-only', action='store_true')
    args = parser.parse_args()
    if args.output_dir:
        make_figures.OUT = args.output_dir
    pipeline_rounds()
    pipeline_control()
    if not args.pipeline_only:
        multicore()
