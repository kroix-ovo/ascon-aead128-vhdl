# Board-integrated (MMCM + demo + self-test, both cores folded) route at a given MMCM divider; no bitstream.
# usage: powershell -File run_board.ps1 <divider>   (12 => 83.333 MHz, 10 => 100 MHz)
param([int]$Divider)
$b = 'C:\Users\Symok\Downloads\ascon-aead128-vhdl-main\worktrees\ascon-weight-stream-handoff\build\handoff_fold\board'
$src = "$b\src_snapshot"
$out = "$b\route_div$Divider"
New-Item -ItemType Directory -Force $out | Out-Null
# Vivado debug-hub generation needs a short temp path (<146 chars): run from build.
Set-Location (Split-Path (Split-Path $b))
& C:\Xilinx\Vivado\2023.2\bin\vivado.bat -mode batch -nojournal -log "$out\vivado.log" -source "$b\route_weight_board_nobit.tcl" -tclargs $out $src $Divider *> "$out\stdout.txt"
"board div=$Divider exit=$LASTEXITCODE"
