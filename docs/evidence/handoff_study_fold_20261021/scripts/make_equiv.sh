#!/usr/bin/env bash
# The CI "make" targets that do not need Vivado, run on the synced scratch tree with system GHDL.
set -uo pipefail
S=$HOME/ascon_fold_scratch
V=/mnt/c/Users/Symok/Downloads/ascon-aead128-vhdl-main/worktrees/ascon-weight-stream-3rpc/build/linux-venv/bin/python
export PYTHONDONTWRITEBYTECODE=1
D=$S/make_equiv; rm -rf "$D"; mkdir -p "$D"
cp -r "$S/wt/rtl" "$S/wt/verification" "$D/"
cd "$D"
echo "== python compileall"; $V -m compileall -q verification >/dev/null && echo PASS
echo "== model-test"; PYTHONPATH=verification/model $V -m pytest -q -p no:cacheprovider verification/model 2>&1 | tail -2
echo "== test_adapter_export.py"; (cd verification && $V test_adapter_export.py 2>&1 | tail -2)
echo "== permutation-test u1"; $V verification/run_permutation.py 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E "TESTS=" | tail -1
echo "== permutation-test u3"; $V verification/run_permutation.py --rounds-per-cycle 3 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E "TESTS=" | tail -1
echo "== weight-file-test (default config)"; $V verification/run_weight_file.py --ghdl ghdl 2>&1 | tail -2
mkdir -p build/board-selftest build/board-demo
echo "== board-selftest"
(cd build/board-selftest && ghdl -a --std=08 ../../rtl/ascon_pkg.vhd ../../rtl/ascon_permutation.vhd ../../rtl/ascon_aead128_core.vhd ../../rtl/ascon_selftest_vectors.vhd ../../rtl/ascon_weight_selftest.vhd ../../verification/vhdl/tb_weight_selftest.vhd && ghdl --elab-run --std=08 tb_weight_selftest --assert-level=error 2>&1 | tail -3; echo "rc=${PIPESTATUS[0]}")
echo "== board-demo-test"
(cd build/board-demo && ghdl -a --std=08 ../../rtl/ascon_pkg.vhd ../../rtl/ascon_permutation.vhd ../../rtl/ascon_aead128_core.vhd ../../rtl/ascon_demo_top.vhd ../../rtl/ascon_demo_autotest.vhd ../../verification/vhdl/tb_weight_demo.vhd && ghdl --elab-run --std=08 tb_weight_demo --assert-level=error 2>&1 | tail -3; echo "rc=${PIPESTATUS[0]}"; ghdl --elab-run --std=08 tb_weight_demo -gG_ROUNDS_PER_CYCLE=1 -gG_BUFFERING_ENABLE=false --assert-level=error 2>&1 | tail -3; echo "rc=${PIPESTATUS[0]}")
echo MAKE_EQUIV_DONE
