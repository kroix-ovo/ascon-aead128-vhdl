#!/usr/bin/env bash
# Tag-output gate regression: sync, cocotb matrix, negative control on ungated RTL.
set -uo pipefail
B=/mnt/c/Users/Symok/Downloads/ascon-aead128-vhdl-main/worktrees/ascon-weight-stream-handoff/build/handoff_fold/scripts
S=$HOME/ascon_fold_scratch
bash $B/sync.sh
W=$S/wt/scripts
R="bash $W/cocotb_run.sh"
{
$R tf_u1_ascon -- --rounds-per-cycle 1 --module test_ascon &
$R tf_u3_ascon -- --rounds-per-cycle 3 --module test_ascon &
$R tf_buf_ascon -- --rounds-per-cycle 3 --buffering --module test_ascon &
$R tf_fold_ascon -- --rounds-per-cycle 3 --buffering --folded --module test_ascon &
wait
$R tf_u1_kat FULL_KAT=1 -- --rounds-per-cycle 1 --module test_ascon &
$R tf_buf_kat FULL_KAT=1 -- --rounds-per-cycle 3 --buffering --module test_ascon &
$R tf_buf_d11 -- --rounds-per-cycle 3 --buffering --input-depth 1 --output-depth 1 --module test_ascon &
$R tf_fold_kat FULL_KAT=1 -- --rounds-per-cycle 3 --buffering --folded --module test_ascon &
wait
$R tf_buf_stream FULL_KAT=1 -- --rounds-per-cycle 3 --buffering --module test_stream &
$R tf_fold_stream FULL_KAT=1 -- --rounds-per-cycle 3 --buffering --folded --module test_stream &
$R tf_u1_cycles -- --rounds-per-cycle 1 --module test_cycles &
$R tf_u3_cycles -- --rounds-per-cycle 3 --module test_cycles &
$R tf_buf_cycles -- --rounds-per-cycle 3 --buffering --module test_cycles &
$R tf_fold_cycles -- --rounds-per-cycle 3 --buffering --folded --module test_cycles &
wait
} 2>&1
# Negative control: restore the ungated assignment and expect the new test to fail.
cp -r $S/wt $S/wt_ungated_tmp
sed -i "s/^  tag_out_o       <= tag_reg when decrypt_reg = '0' else (others => '0');/  tag_out_o       <= tag_reg;/" $S/wt_ungated_tmp/rtl/ascon_aead128_core.vhd
grep -n "^  tag_out_o       <= tag_reg;" $S/wt_ungated_tmp/rtl/ascon_aead128_core.vhd
mv $S/wt $S/wt_gated_tmp && mv $S/wt_ungated_tmp $S/wt
$R tf_neg_u3 -- --rounds-per-cycle 3 --module test_ascon
$R tf_neg_buf -- --rounds-per-cycle 3 --buffering --module test_ascon
rm -rf $S/wt && mv $S/wt_gated_tmp $S/wt
echo ALL_DONE
