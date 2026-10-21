$W = 'C:\Users\Symok\Downloads\ascon-aead128-vhdl-main\worktrees\ascon-weight-stream-handoff\build\padfix\vivado'
Set-Location $W
$v = 'C:\Xilinx\Vivado\2023.2\bin\vivado.bat'
$j1 = Start-Process -FilePath $v -ArgumentList @('-mode','batch','-nojournal','-log',"$W\buf_p10.log",'-source',"$W\src\route_stream.tcl",'-tclargs',"$W\buf_p10","$W\src",'3','1','0','10') -PassThru -NoNewWindow
Start-Sleep -Seconds 20
$j2 = Start-Process -FilePath $v -ArgumentList @('-mode','batch','-nojournal','-log',"$W\fold_p10.log",'-source',"$W\src\route_stream.tcl",'-tclargs',"$W\fold_p10","$W\src",'3','1','0','10','1') -PassThru -NoNewWindow
$j1.WaitForExit(); $j2.WaitForExit()
Get-Content "$W\buf_p10\implementation.json"; Get-Content "$W\fold_p10\implementation.json"
