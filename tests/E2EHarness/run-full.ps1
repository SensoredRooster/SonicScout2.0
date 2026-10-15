param([string]$Build='build9')
$q=if($env:SS_QA_DIR){$env:SS_QA_DIR}else{'C:\Users\brand\Documents\SonicScout-QA-2026-10-14'}; $vb='C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'; $n='SonicScout-Phase0-E2E-20261014'; $pw=(gc "$q\vm-password.txt")
$log="$q\e2e\run-$Build.log"; function L($m){ $s="$(Get-Date -Format HH:mm:ss) $m"; Add-Content $log $s; Add-Content "$q\progress.md" "- $(Get-Date -Format 'HH:mm') [$Build runner] $m" }
function G($s){ & "$q\e2e\gx-host.ps1" -Script $s 2>&1 }
function WaitGC{ for($i=0;$i -lt 30;$i++){ Start-Sleep 30; & $vb guestcontrol $n run --username tester --password $pw --exe 'C:\Windows\System32\cmd.exe' -- cmd /c whoami 2>&1 | Out-Null; if($LASTEXITCODE -eq 0){ return $true } }; $false }
L "start; waiting for guest"; if(-not (WaitGC)){ L "FAIL guest control never ready"; exit 1 }
& $vb guestcontrol $n --username tester --password $pw mkdir --parents C:\QA\out 2>&1 | Out-Null
foreach($f in "$q\$Build\SonicScout-Setup.exe","$q\probe\SonicScout.E2EProbe.exe","$q\e2e\drive-app.ps1","$q\e2e\verify.ps1","$q\e2e\uia-dump.ps1"){ & $vb guestcontrol $n --username tester --password $pw copyto --target-directory C:\QA\ $f 2>&1 | Out-Null }
G 'foreach($t in @(@("SSInstall","powershell -NoProfile -WindowStyle Hidden -Command Start-Process C:\QA\SonicScout-Setup.exe -ArgumentList /S"),@("SSDrive","powershell -NoProfile -ExecutionPolicy Bypass -File C:\QA\drive-app.ps1"),@("SSVerify","powershell -NoProfile -ExecutionPolicy Bypass -File C:\QA\verify.ps1"),@("SSUia","powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\QA\uia-dump.ps1"))){ schtasks /Create /TN $t[0] /TR $t[1] /SC ONCE /ST 23:59 /IT /RL LIMITED /F | Out-Null }; schtasks /Run /TN SSInstall' | Out-Null
Start-Sleep 40; L ("UAC1 " + (& "$q\e2e\uac-yes.ps1"))
for($i=0;$i -lt 15;$i++){ Start-Sleep 20; if("$(G 'if(-not (Get-Process SonicScout-Setup -EA SilentlyContinue) -and (Test-Path "C:\Program Files\SonicScout\SonicScout.exe")){"DONE"}')" -match 'DONE'){break} }; L "installed"
G 'schtasks /Run /TN SSDrive' | Out-Null
for($i=0;$i -lt 15;$i++){ Start-Sleep 25; $r = & "$q\e2e\uac-yes.ps1"; if("$r" -match 'approved|still'){ break } }; L "UAC2 $r"
for($i=0;$i -lt 40;$i++){ Start-Sleep 40; $o = G 'Get-ChildItem C:\QA\out\drive-*.txt | Select -Last 1 | % { Get-Content $_ -Tail 1 }'; if("$o" -match 'STEP 3'){break} }; L "pass1: $o"
L ("runonce: " + (G '(Get-ItemProperty HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce -EA SilentlyContinue).SonicScoutResumeSetup'))
G 'shutdown /r /t 5' | Out-Null; Start-Sleep 150; WaitGC | Out-Null; Start-Sleep 240
L ("post-reboot: " + ((G '"BOOT "+(Get-CimInstance Win32_OperatingSystem).LastBootUpTime; Get-Process SonicScout*,consent -EA SilentlyContinue | % { "$($_.Name) $($_.StartTime)" }') -join '; '))
$u = G 'schtasks /Run /TN SSUia | Out-Null; Start-Sleep 40; Get-Content C:\QA\out\uia.txt | Select-String "WINDOW|STEP|Setup complete|BLOCKED" | % Line | Select -First 4'; L ("uia: " + ($u -join ' | '))
G 'Remove-Item C:\QA\out\verify.json -EA SilentlyContinue; schtasks /Run /TN SSVerify | Out-Null' | Out-Null; Start-Sleep 200
G 'for($i=0;$i -lt 60;$i++){ if(Test-Path C:\QA\out\verify.json){break}; Start-Sleep 10 }; Start-Sleep 2; Get-Content C:\QA\out\verify.json -Raw' | Out-File "$q\e2e\verify-$Build.json" -Encoding utf8
$j=(Get-Content "$q\e2e\verify-$Build.json" -Raw) | ConvertFrom-Json; $p=$j.probe | ConvertFrom-Json
$checks=[ordered]@{ eapoKey=$j.eapoKey; editor=$j.editor; deviceSelector=$j.deviceSelector; clsids=(@($j.PSObject.Properties | ? { $_.Name -like 'clsid*' -and $_.Value -like '*EqualizerAPO.dll' }).Count -eq 2); apoOnCable=(@($j.endpoints | ? { $_.name -like 'SonicScout2.0*' -and $_.lfx }).Count -ge 1); include=$j.configIncludesUserFile; running=(@($j.statusesDuringTone) -contains 'RUNNING'); notAdmin=(-not ($j.statusDuringTone | ConvertFrom-Json).elevated -and -not $j.isAdminShell); tone=($p.ok -and $p.dbfs -gt -40); no8889=(-not $j.hresultHits) }
$checks.GetEnumerator() | % { L "check $($_.Key)=$($_.Value)" }; L ("probe dbfs=$($p.dbfs) statuses=" + ($j.statusesDuringTone -join ','))
& $vb guestcontrol $n --username tester --password $pw copyto --target-directory C:\QA\ "$q\e2e\user-flow.ps1" 2>&1 | Out-Null
G 'schtasks /Create /TN SSUser /TR "powershell -NoProfile -ExecutionPolicy Bypass -File C:\QA\user-flow.ps1" /SC ONCE /ST 23:59 /IT /RL LIMITED /F | Out-Null; schtasks /Run /TN SSUser' | Out-Null; L "user flow started"
for($i=0;$i -lt 40;$i++){ Start-Sleep 30; $u = G 'if(Test-Path C:\QA\out\user.json){ Get-Content C:\QA\out\user.txt | Select-String "RESULT" | % Line }'; if("$u" -match 'RESULT'){ break } }
G 'Get-Content C:\QA\out\user.txt -Raw' | Out-File "$q\e2e\user-$Build.txt" -Encoding utf8
foreach($x in $u){ L "user $x"; if("$x" -match 'RESULT (\w+)=(\w+)'){ $checks["user_$($Matches[1])"] = ($Matches[2] -eq 'True') } }
if(-not $u){ $checks["user_flow"]=$false; L "user flow produced no result" }
if(@($checks.Values | ? { -not $_ }).Count -eq 0){ L "RESULT PASS" } else { L "RESULT FAIL" }



