#!/usr/bin/env bash
# Attribute the split-framing discrepancy: AD-only split vs payload-only split.
set -uo pipefail
S=$HOME/ascon_fold_scratch
B=/mnt/c/Users/Symok/Downloads/ascon-aead128-vhdl-main/worktrees/ascon-weight-stream-handoff/build/handoff_fold/scripts
rm -rf $S/runs/framing_probe; mkdir -p $S/runs/framing_probe
PYTHONDONTWRITEBYTECODE=1 python3 $B/run_traffic.py $S/runs/framing_probe 5207435946358666000 framing_ad16_split_only,framing_pt16_split_only > $S/runs/framing_probe/stdout.txt 2>&1
echo "exit=$?"
python3 - <<'EOF'
import json, os
rows = json.load(open(os.path.expanduser('~/ascon_fold_scratch/runs/framing_probe/results.json')))
for r in rows:
    print(r['scenario'], r['config'], r['direction'], r['checked'], 'cycles', r['cycles'])
EOF
