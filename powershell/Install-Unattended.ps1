# One setup. No menu, no Peace, no VB-CABLE, no Device Selector for the user.
# Order: ASIO Bridge Hi-Fi Cable, keep Potato, Equalizer APO, HeSuVi, ReaPlugs, LFX/GFX, LEQ short.
$ErrorActionPreference = 'Continue'
if ($args -contains '-FinishOnly') {
    # defined later; fall through after functions by jumping to bind only
    $FinishOnly = $true
} else { $FinishOnly = $false }
$root = Split-Path $PSScriptRoot -Parent
$installers = Join-Path $root 'tools\SonicScoutCSharp\installers'
New-Item -ItemType Directory -Force -Path $installers | Out-Null
$log = Join-Path $env:TEMP 'SonicScout-Setup.log'
$report = Join-Path ([Environment]::GetFolderPath('Desktop')) 'SonicScout-Setup.log'
function Log($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg
    Add-Content -Path $log -Value $line
    Add-Content -Path $report -Value $line
    Write-Host $line
}
function Publish-Report {
    Copy-Item $log $report -Force -ErrorAction SilentlyContinue
    Log "Report saved to $report"
}

function Close-SetupDialogs {
    Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -match 'DeviceSelector|Configurator|EqualizerAPO|HeSuVi' -or $_.MainWindowTitle -match 'Device Selector|Equalizer APO|HeSuVi'
    } | ForEach-Object {
        Log "Closing $($_.ProcessName) so the user does not have to click."
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    }
}

function Get-File($url, $dest) {
    if ((Test-Path -LiteralPath $dest) -and ((Get-Item $dest).Length -gt 100000)) { return $true }
    Log "Downloading $(Split-Path $dest -Leaf)"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $wc = New-Object Net.WebClient
        $wc.Headers.Add('User-Agent', 'Mozilla/5.0')
        $wc.DownloadFile($url, $dest)
    } catch {
        Log "Download failed: $($_.Exception.Message)"
        return $false
    }
    if (-not (Test-Path $dest)) { return $false }
    $bytes = [System.IO.File]::ReadAllBytes($dest)
    if ($bytes.Length -lt 100000 -or $bytes[0] -ne 77 -or $bytes[1] -ne 90) {
        Log "Downloaded file is not an installer. Removing it."
        Remove-Item $dest -Force -ErrorAction SilentlyContinue
        return $false
    }
    return $true
}

Log 'SONIC SCOUT SETUP'
if ($FinishOnly) {
    Log 'Finishing after restart. No installers, no clicks.'
}
if (-not $FinishOnly) {
Log 'Hi-Fi Cable, Equalizer APO, HeSuVi, ReaPlugs, LEQ. No choices.'

$hifi = Join-Path $installers 'HIFI_CABLE_Setup_x64.exe'
if (-not (Test-Path $hifi)) {
    $zip = Join-Path $installers 'VBHIFI_Driver.zip'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        (New-Object Net.WebClient).DownloadFile('https://download.vb-audio.com/Download_CABLE/HiFiCableAsioBridgeSetup_v1007.zip', $zip)
        Expand-Archive $zip -DestinationPath (Join-Path $installers 'VBHIFI') -Force
        $found = Get-ChildItem (Join-Path $installers 'VBHIFI') -Recurse -Filter '*Setup*.exe' | Select-Object -First 1
        if ($found) { Copy-Item $found.FullName $hifi -Force }
    } catch { Log "Hi-Fi Cable download failed: $($_.Exception.Message)" }
}
if (Test-Path $hifi) {
    Log 'Installing ASIO Bridge Hi-Fi Cable'
    Start-Process -FilePath $hifi -ArgumentList '-i -h' -Wait
} else { Log 'FAIL Hi-Fi Cable installer missing' }

Log 'Keeping existing Voicemeeter. Not installing another mixer.'

$eapo = Join-Path $installers 'EqualizerAPO_Setup.exe'
if (-not (Get-File 'https://sourceforge.net/projects/equalizerapo/files/1.4.2/EqualizerAPO-x64-1.4.2.exe/download' $eapo)) {
    Log 'FAIL Equalizer APO installer missing'
} else {
    Log 'Installing Equalizer APO'
    $eapoRoot = Join-Path $env:ProgramFiles 'EqualizerAPO'
    $proc = Start-Process -FilePath $eapo -ArgumentList "/S /D=$eapoRoot" -PassThru
    for ($i = 0; $i -lt 90 -and -not $proc.HasExited; $i++) {
        Close-SetupDialogs
        Start-Sleep -Seconds 2
    }
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    Close-SetupDialogs
}

$hesuvi = Join-Path $installers 'HeSuVi.exe'
if (Get-File 'https://sourceforge.net/projects/hesuvi/files/HeSuVi_2.0.0.1.exe/download' $hesuvi) {
    Log 'Installing HeSuVi'
    $hp = Start-Process -FilePath $hesuvi -ArgumentList '/S' -PassThru
    for ($i = 0; $i -lt 45 -and -not $hp.HasExited; $i++) {
        Close-SetupDialogs
        Start-Sleep -Seconds 2
    }
    if (-not $hp.HasExited) { Stop-Process -Id $hp.Id -Force -ErrorAction SilentlyContinue }
    Close-SetupDialogs
} else { Log 'FAIL HeSuVi installer missing' }

$reaplugs = Join-Path $installers 'reaplugs_x64.exe'
if (Get-File 'https://www.reaper.fm/reaplugs/reaplugs236_x64-install.exe' $reaplugs) {
    Log 'Installing ReaPlugs'
    Start-Process -FilePath $reaplugs -ArgumentList '/S' -Wait
} else { Log 'FAIL ReaPlugs installer missing' }

}
function Enable-EapoOnHiFiCable {
    $preMix = '{EACD2258-FCAC-4FF4-B36D-419E924A6D79}'
    $postMix = '{EC1CC9CE-FAED-4822-828A-82A81A6F018F}'
    $fx = '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d}'
    $nameKey = '{a45c254e-df1c-4efd-8020-67d146a850e0},2'
    $renderRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render'
    $childRoot = 'HKLM:\SOFTWARE\EqualizerAPO\Child APOs'
    New-Item -Path $childRoot -Force | Out-Null
    $bound = 0
    Get-ChildItem $renderRoot -ErrorAction SilentlyContinue | ForEach-Object {
        $props = Join-Path $_.PSPath 'Properties'
        $fxKey = Join-Path $_.PSPath 'FxProperties'
        if (-not (Test-Path $props) -or -not (Test-Path $fxKey)) { return }
        $name = (Get-ItemProperty -Path $props -Name $nameKey -ErrorAction SilentlyContinue).$nameKey
        if ($name -notmatch 'Hi-?Fi|ASIO Bridge') { return }
        New-ItemProperty -Path $fxKey -Name "$fx,1" -Value $preMix -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $fxKey -Name "$fx,2" -Value $postMix -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $fxKey -Name "$fx,5" -Value $preMix -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $fxKey -Name "$fx,6" -Value $postMix -PropertyType String -Force | Out-Null
        $leqKey = '{fc52a749-4be9-4510-896e-966ba6525980},3'
        $leqEnabled = '{fc52a749-4be9-4510-896e-966ba6525980},0'
        $shortRelease = [byte[]](0x03,0,0,0,0x01,0,0,0,0x02,0,0,0)
        $enabled = [byte[]](0x0b,0,0,0,0x01,0,0,0,0xff,0xff,0,0)
        New-ItemProperty -Path $fxKey -Name $leqKey -Value $shortRelease -PropertyType Binary -Force | Out-Null
        New-ItemProperty -Path $fxKey -Name $leqEnabled -Value $enabled -PropertyType Binary -Force | Out-Null
        Log "PASS LFX/GFX and LEQ short on $name"
        $script:boundCount++
        $bound++
    }
    return $bound
}

$script:boundCount = 0
$boundNow = Enable-EapoOnHiFiCable
if ($boundNow -eq 0) {
    Log 'Hi-Fi Cable is not visible yet. Scheduling the finish for the next login.'
    $cmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -FinishOnly"
    New-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'SonicScoutFinish' -Value $cmd -PropertyType String -Force | Out-Null
    Log 'Restarting in 30 seconds. Setup finishes by itself after login.'
    Publish-Report
    for ($left = 30; $left -ge 1; $left--) {
        Write-Host "RESTART IN $left"
        Start-Sleep -Seconds 1
    }
    shutdown /r /t 0 /c "Sonic Scout needs one restart to finish."
    exit 0
}
Log 'PASS setup finished. Hi-Fi Cable is bound. No more clicks.'
Publish-Report
