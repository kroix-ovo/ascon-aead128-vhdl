#!/usr/bin/env bash
# Final-RTL regression for the fold study (all GHDL simulation; fresh nonces for every message).
set -uo pipefail
B=/mnt/c/Users/Symok/Downloads/ascon-aead128-vhdl-main/worktrees/ascon-weight-stream-handoff/build/handoff_fold/scripts
S=$HOME/ascon_fold_scratch
cd "$S"
bash $B/sync.sh | tail -1
cp $S/wt/source_sha256_lf.txt $S/final_source_sha256_lf.txt
echo "== KAT TextIO"
for c in "u1 1 false false" "u3 3 false false" "u3-buffered 3 true false" "u3-fold 3 true true"; do bash $B/kat_textio.sh $c & done; wait
python3 $S/wt/scripts/kat_stats.py
echo "== weight files 1KiB"
bash $B/run_batch.sh 1KiB adapter 5207435946358663000 u1 u3 u3-buffered u3-fold
echo "== traffic"
rm -rf runs/traffic; mkdir -p runs/traffic
PYTHONDONTWRITEBYTECODE=1 python3 wt/scripts/run_traffic.py $S/runs/traffic 5207435946358664000 > runs/traffic/stdout.txt 2>&1; echo "traffic exit=$?"
python3 wt/scripts/summarize_traffic.py runs/traffic/results.json /mnt/c/Users/Symok/Downloads/ascon-aead128-vhdl-main/worktrees/ascon-weight-stream-handoff/docs/evidence/handoff_study_baseline_20261021/traffic_results.json > runs/traffic/summary.txt; head -3 runs/traffic/summary.txt
echo "== cocotb matrix"
bash $B/cocotb_all.sh > cocotb_all_1.txt 2>&1; grep -E "^== |TESTS=" cocotb_all_1.txt | sed 's/  */ /g'
bash $B/cocotb_run.sh fold_trace2 -- --rounds-per-cycle 3 --buffering --folded --module test_fold | sed 's/  */ /g'
for n in buf_ascon_pre fold_ascon_pre; do test -d cocotb/$n && echo "(kept pre-fix logs: $n)"; done
echo "== generated Verilog"
bash $B/synth_verilog.sh /home/kroix/tools/oss-cad-suite/bin/ghdl
bash $B/netlist_tests.sh > netlist_1.txt 2>&1; grep -E "^== |TESTS=" netlist_1.txt | sed 's/  */ /g'
echo "== make-equivalent targets"
bash $B/make_equiv.sh > make_equiv.txt 2>&1; cat make_equiv.txt | grep -v "^\s*$"
bash $B/make_fold_target.sh
echo "== netlist identity (existing configs)"
bash $B/netlist_identity.sh; bash $B/netlist_diff_show.sh
echo "== board copies with fold"
bash $B/board_fold_sim.sh 2>&1 | tail -4
echo "== full workloads"
KEEP=--keep-dumps bash $B/run_batch.sh full adapter 5207435946358663100 u3-buffered u3-fold
bash $B/run_batch.sh full llama 5207435946358663200 u3-buffered u3-fold
echo FINAL_REGRESSION_DONE
