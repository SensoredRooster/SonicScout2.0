# Runs non-elevated in the tester session after setup. Produces C:\QA\out\verify.json
param([string]$Out = 'C:\QA\out', [string]$Probe = 'C:\QA\SonicScout.E2EProbe.exe')
New-Item -ItemType Directory $Out -Force | Out-Null
$r = [ordered]@{}
$r.eapoKey = Test-Path 'HKLM:\SOFTWARE\EqualizerAPO'
$root = 'C:\Program Files\EqualizerAPO'
$r.editor = Test-Path "$root\Editor.exe"; $r.deviceSelector = (Test-Path "$root\DeviceSelector.exe") -or (Test-Path "$root\Configurator.exe")
foreach ($c in '{EACD2258-FCAC-4FF4-B36D-419E924A6D79}', '{EC1CC9CE-FAED-4822-828A-82A81A6F018F}') {
    $r["clsid $c"] = [string](Get-ItemProperty "Registry::HKEY_CLASSES_ROOT\CLSID\$c\InprocServer32" -ErrorAction SilentlyContinue).'(default)'
}
$bound = @()
foreach ($ep in Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render') {
    $p = Get-ItemProperty "$($ep.PSPath)\Properties" -ErrorAction SilentlyContinue
    $fx = Get-ItemProperty "$($ep.PSPath)\FxProperties" -ErrorAction SilentlyContinue
    $name = [string]$p.'{a45c254e-df1c-4efd-8020-67d146a850e0},2'
    $state = (Get-ItemProperty $ep.PSPath).DeviceState
    $bound += [pscustomobject]@{ name = $name; state = $state; lfx = [string]$fx.'{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},1'; gfx = [string]$fx.'{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},2' }
}
$r.endpoints = $bound
$cfg = "$root\config\config.txt"
$r.configText = if (Test-Path $cfg) { [string](Get-Content $cfg -Raw) } else { $null }
$userInc = Join-Path $env:LOCALAPPDATA 'SonicScout\eapo\sonicscout.txt'
$r.userInclude = if (Test-Path $userInc) { [string](Get-Content $userInc -Raw) } else { '<missing>' }
$r.configIncludesUserFile = [bool]($r.configText -and $r.configText.ToLower().Contains(("Include: " + $userInc).ToLower()))
$app = Get-Process SonicScout -ErrorAction SilentlyContinue
$r.appRunning = [bool]$app
$r.sonicPassRunning = [bool](Get-Process SonicScout.SonicPass -ErrorAction SilentlyContinue)
$statusFile = Join-Path $env:LOCALAPPDATA 'SonicScout\logs\eq-status.json'
$r.statusBefore = if (Test-Path $statusFile) { [string](Get-Content $statusFile -Raw) } else { '<missing>' }
& $Probe --list | Set-Content (Join-Path $Out 'devices.txt')
$job = Start-Job { param($p) & $p --game 'SonicScout2.0' --output 'Speakers' --seconds 15 } -ArgumentList $Probe
$seen = @()
for ($i = 0; $i -lt 14; $i++) { Start-Sleep 1; if (Test-Path $statusFile) { $seen += ([string](Get-Content $statusFile -Raw) | ConvertFrom-Json).status } }
$r.probe = (Receive-Job $job -Wait -AutoRemoveJob) -join ''
$r.statusesDuringTone = ($seen | Select -Unique)
$r.statusDuringTone = if (Test-Path $statusFile) { [string](Get-Content $statusFile -Raw) } else { '<missing>' }
$logs = @(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'SonicScout') -Recurse -File -Include *.txt, *.log, *.json -ErrorAction SilentlyContinue)
$r.hresultHits = @($logs | Select-String -Pattern '0x8889[0-9A-Fa-f]{4}|88890010|88890004' | % { "$($_.Path):$($_.LineNumber): $($_.Line)" } | Select -First 30)
$r.isAdminShell = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')
$r | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $Out 'verify.json')

