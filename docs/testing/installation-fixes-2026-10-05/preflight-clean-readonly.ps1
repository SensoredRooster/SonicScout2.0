$ErrorActionPreference='Stop'
Get-Process SonicScout -ErrorAction SilentlyContinue | Stop-Process
$files=@('C:\Program Files\EqualizerAPO\config\config.txt','C:\Program Files\EqualizerAPO\config\SonicScout2.0\library\version.txt','C:\Program Files\VSTPlugins\SonicScout2.0\ss_spatial_engine_bravo_v2_0_0.dll','C:\Program Files\EqualizerAPO\config\HeSuVi\hrir\EAC_Default.wav')
function Snapshot-Files { $files | ForEach-Object { $f=Get-Item $_; "$($f.FullName):$($f.LastWriteTimeUtc.Ticks):$((Get-FileHash $_ -Algorithm SHA256).Hash)" } }
function Snapshot-Logs { Get-ChildItem "$env:LOCALAPPDATA\SonicScout\logs" -File | ForEach-Object {"$($_.Name):$($_.LastWriteTimeUtc.Ticks):$($_.Length)"} }
$before=Snapshot-Files; $logs=Snapshot-Logs
& C:\QA\clean-published\setup_audio_stack.ps1 -Mode Preflight
$code=$LASTEXITCODE
if($code -ne 0){throw "Live preflight failed: $code"}
if(Compare-Object $before (Snapshot-Files)){throw 'Live preflight changed installed files'}
if(Compare-Object $logs (Snapshot-Logs)){throw 'Live preflight changed logs'}
'PASS: live unprivileged preflight returned 0 and preserved installed file hashes/timestamps and logs.' | Tee-Object C:\QA\preflight-clean-readonly-result.txt

