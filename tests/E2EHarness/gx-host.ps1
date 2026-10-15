param([Parameter(Mandatory)][string]$Script, [int]$Timeout=600000)
$q=if($env:SS_QA_DIR){$env:SS_QA_DIR}else{'C:\Users\brand\Documents\SonicScout-QA-2026-10-14'}; $vb='C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'; $n='SonicScout-Phase0-E2E-20261014'; $pw=(gc "$q\vm-password.txt")
$tmp=Join-Path $q 'e2e\gx.ps1'; Set-Content $tmp $Script
& $vb guestcontrol $n --username tester --password $pw copyto --target-directory C:\QA\ $tmp | Out-Null
& $vb guestcontrol $n --username tester --password $pw run --timeout $Timeout --exe C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -- powershell -NoProfile -ExecutionPolicy Bypass -File C:\QA\gx.ps1 2>&1

