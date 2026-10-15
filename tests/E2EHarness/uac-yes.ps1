# Answers a pending UAC prompt in the VM with Alt+Y (QA only). Returns "approved"/"none".
$q=if($env:SS_QA_DIR){$env:SS_QA_DIR}else{'C:\Users\brand\Documents\SonicScout-QA-2026-10-14'}; $vb='C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'; $n='SonicScout-Phase0-E2E-20261014'
$has = "$(& "$q\e2e\gx-host.ps1" -Script 'if(Get-Process consent -EA SilentlyContinue){"CONSENT"}')"
if ($has -notmatch 'CONSENT') { 'none'; return }
for ($t=0; $t -lt 4; $t++) {
  Start-Sleep 8
  & $vb controlvm $n keyboardputscancode 38; Start-Sleep -Milliseconds 300; & $vb controlvm $n keyboardputscancode 15; Start-Sleep -Milliseconds 300; & $vb controlvm $n keyboardputscancode 95; & $vb controlvm $n keyboardputscancode b8
  Start-Sleep 30
  $has = "$(& "$q\e2e\gx-host.ps1" -Script 'if(Get-Process consent -EA SilentlyContinue){"CONSENT"}')"
  if ($has -notmatch 'CONSENT') { "approved (try $t)"; return }
}
'still pending'

