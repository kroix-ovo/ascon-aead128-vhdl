#!/usr/bin/env bash
# SHA-256 of every changed/new source: working copy (CRLF as checked out on Windows) and LF-normalised content.
WT=/mnt/c/Users/Symok/Downloads/ascon-aead128-vhdl-main/worktrees/ascon-weight-stream-handoff
cd "$WT"
echo "base commit: 8b886c075241d4f599f0a299f114b5fae133291e (codex/ascon-weight-stream-handoff-study)"
echo "columns: sha256(working copy)  sha256(LF-normalised)  path"
for f in rtl/ascon_pkg.vhd rtl/ascon_permutation.vhd rtl/ascon_aead128_core.vhd \
         verification/vhdl/tb_ascon_aead128.vhd verification/vhdl/tb_weight_file.vhd \
         verification/run.py verification/compare_stream.py verification/simulate_weight_file.py verification/simulate_adapter.py \
         verification/cocotb/test_ascon.py verification/cocotb/test_fold.py verification/cocotb/test_cycles.py \
         verification/cocotb/test_stream.py verification/model/ascon_ref.py \
         vivado/route_stream.tcl Makefile .github/workflows/verify.yml; do
  a=$(sha256sum "$f" | cut -d' ' -f1); b=$(sed 's/\r$//' "$f" | sha256sum | cut -d' ' -f1)
  echo "$a  $b  $f"
done
echo
echo "HEAD (8b886c0) LF blobs of the RTL for comparison:"
for f in rtl/ascon_pkg.vhd rtl/ascon_permutation.vhd rtl/ascon_aead128_core.vhd; do
  echo "$(sed 's/\r$//' build/handoff_sim/src_head/$(basename $f) | sha256sum | cut -d' ' -f1)  $f (HEAD)"
done
echo
echo "pinned KAT: $(sha256sum verification/vectors/LWC_AEAD_KAT_128_128.txt | cut -d' ' -f1)"
echo "adapter export: $(sha256sum /home/kroix/projects/SAGE_Adapter_Experiment/llmc-gpt2/runs/adapter_fp32_200/export/adapter_weights.bin | cut -d' ' -f1)"
echo "adapter checkpoint: $(sha256sum /home/kroix/projects/SAGE_Adapter_Experiment/llmc-gpt2/runs/adapter_fp32_200/adapter_params_00000200.bin | cut -d' ' -f1)"
echo "small-llama payload: $(sha256sum $HOME/ascon_handoff_scratch/data/trained_weights_fp32.bin | cut -d' ' -f1)"
echo
echo "Vivado source snapshots:"; cat build/handoff_fold/vivado/src_v2/sha256.txt
echo "Board snapshot (LF copies with G_FOLDED_ABSORB forced in selftest and demo):"; cat build/handoff_fold/board/src_snapshot/sha256.txt
