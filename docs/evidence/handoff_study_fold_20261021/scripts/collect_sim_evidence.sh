#!/usr/bin/env bash
# Copy SMALL simulation summaries (no dumps, no weights) into the fold-study evidence dir.
# Refuses to overwrite any existing evidence file.
set -euo pipefail
S=$HOME/ascon_fold_scratch
WT=/mnt/c/Users/Symok/Downloads/ascon-aead128-vhdl-main/worktrees/ascon-weight-stream-handoff
E=$WT/docs/evidence/handoff_study_fold_20261021
mkdir -p "$E"
put() { # put <dest-name> : stdin -> file, never overwriting
  test ! -e "$E/$1" || { echo "refusing to overwrite $E/$1"; exit 1; }
  cat > "$E/$1"
}
cd "$S"
python3 - <<'EOF' | put weight_file_runs.json
import json, glob
rows = [json.load(open(p)) for p in sorted(glob.glob('runs/*/*/result.json'))]
print(json.dumps(rows, indent=1))
EOF
cat runs/traffic/results.json | put traffic_results.json
cat runs/traffic/summary.txt | put traffic_summary.txt
python3 wt/scripts/kat_stats.py | put kat_textio_cycle_stats.txt
python3 wt/scripts/fold_cycle_model.py runs/traffic/results.json "$E/weight_file_runs.json" | put cycle_model_check.txt
{ cat cocotb_all_1.txt; echo; echo "== test_fold (final module: 2 tests)"; for n in fold_trace2; do grep -E "TESTS=|PASS |FAIL " cocotb/$n/log.txt | sed 's/\x1b\[[0-9;]*m//g'; done; grep -h "checked groups" cocotb/fold_trace2/log.txt | sed 's/.*checked/checked/'; } | put cocotb_matrix.txt
cat netlist_1.txt | put netlist_tests.txt
{ cat make_equiv.txt; echo; echo "== make vhdl-textio-fold-test"; tail -1 make_equiv/build/ghdl-textio-fold/simulation_results.txt; } | put make_targets.txt
{ echo "Pre-fix test_ascon on buffered configs (unmodified test_ascon.py; same 3 failures for u3-buffered and u3-fold)"; for n in buf_ascon_pre fold_ascon_pre; do echo "### $n"; grep -E "TESTS=|FAIL " cocotb/$n/log.txt | sed 's/\x1b\[[0-9;]*m//g'; done; LINES_MAX=40 bash wt/scripts/show_fail.sh buf_ascon_pre; } | put test_ascon_buffered_prefix_failures.txt
for c in u1 u3 u3-buffered u3-fold; do tail -1 runs/kat_textio/$c/simulation_results.txt | sed "s/^/$c /"; done | put kat_textio_totals.txt
cat wt/source_sha256_lf.txt | put source_sha256_lf_scratch.txt
python3 - <<'EOF2' | put framing_probe.txt
import json, os
rows = json.load(open(os.path.expanduser('~/ascon_fold_scratch/runs/framing_probe/results.json')))
print('AD-only split framing vs payload-only split framing (16 B AD, 16 B PT); checked = match with SP 800-232 reference')
for r in rows:
    print(r['scenario'], r['config'], r['direction'], r['checked'], 'cycles', r['cycles'])
EOF2
{ bash wt/scripts/netlist_identity.sh; bash wt/scripts/netlist_diff_show.sh; } | put netlist_identity.txt
bash wt/scripts/board_fold_sim.sh > board_fold_sim.txt 2>&1
{ echo "Board RTL copies (G_FOLDED_ABSORB forced on in ascon_weight_selftest/ascon_demo_top copies), GHDL:"; cat board_fold_sim.txt; } | put board_fold_sim.txt
for n in buf_ascon fold_ascon buf_ascon_d11 fold_ascon_d11; do echo "### $n"; grep -h "later than the unbuffered" cocotb/$n/log.txt | sed 's/.*buffered core/buffered core/'; done | put test_ascon_error_latency.txt
bash wt/scripts/source_sha.sh | put source_and_artifact_sha256.txt
mkdir -p "$E/scripts"
for f in "$WT"/build/handoff_fold/scripts/*; do b=$(basename "$f"); test ! -e "$E/scripts/$b" && cp "$f" "$E/scripts/$b"; done
{ ghdl --version | head -1; python3 --version; /mnt/c/Users/Symok/Downloads/ascon-aead128-vhdl-main/worktrees/ascon-weight-stream-3rpc/build/linux-venv/bin/python -c 'import cocotb, sys; print("cocotb", cocotb.__version__, "python", sys.version.split()[0])'; iverilog -V 2>&1 | head -1; echo "verilator (netlist sims): $(/home/kroix/tools/oss-cad-suite/bin/verilator --version)"; echo "ghdl synth (Verilog translation only): $(/home/kroix/tools/oss-cad-suite/bin/ghdl --version | head -1)"; uname -r; grep PRETTY /etc/os-release; } | put tool_versions.txt
ls -la "$E"
