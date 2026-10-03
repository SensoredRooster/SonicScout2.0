# Unattended Sonic Scout setup. No Peace. No VB-CABLE. No menu.
# Order: ASIO Bridge Hi-Fi Cable, keep existing Voicemeeter, Equalizer APO, HeSuVi, ReaPlugs, LEQ short.
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
$installers = Join-Path $root 'tools\SonicScoutCSharp\installers'
New-Item -ItemType Directory -Force -Path $installers | Out-Null

function Get-File($url, $dest) {
    if (Test-Path -LiteralPath $dest) { return $dest }
    Write-Host "Downloading $dest"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    (New-Object Net.WebClient).DownloadFile($url, $dest)
    return $dest
}

Write-Host 'SONIC SCOUT UNATTENDED SETUP'
Write-Host 'Hi-Fi Cable, then Equalizer APO, HeSuVi, ReaPlugs, LEQ. No Peace. No VB-CABLE.'

$hifi = Join-Path $installers 'HIFI_CABLE_Setup_x64.exe'
if (-not (Test-Path $hifi)) {
    $zip = Join-Path $installers 'VBHIFI_Driver.zip'
    Get-File 'https://download.vb-audio.com/Download_CABLE/HiFiCableAsioBridgeSetup_v1007.zip' $zip
    Expand-Archive $zip -DestinationPath (Join-Path $installers 'VBHIFI') -Force
    $found = Get-ChildItem (Join-Path $installers 'VBHIFI') -Recurse -Filter '*Setup*.exe' | Select-Object -First 1
    if ($found) { Copy-Item $found.FullName $hifi -Force }
}
if (Test-Path $hifi) {
    Write-Host 'Installing ASIO Bridge Hi-Fi Cable...'
    Start-Process -FilePath $hifi -ArgumentList '-i -h' -Wait
}

Write-Host 'Voicemeeter Potato is kept if it is already installed. A second mixer is not installed.'

$eapo = Join-Path $installers 'EqualizerAPO_Setup.exe'
if (-not (Test-Path $eapo)) {
    Get-File 'https://sourceforge.net/projects/equalizerapo/files/1.4.2/EqualizerAPO-x64-1.4.2.exe/download' $eapo
}
if (Test-Path $eapo) {
    Write-Host 'Installing Equalizer APO...'
    $eapoRoot = Join-Path $env:ProgramFiles 'EqualizerAPO'
    Start-Process -FilePath $eapo -ArgumentList "/S /D=$eapoRoot" -Wait
}

$hesuvi = Join-Path $installers 'HeSuVi.exe'
if (-not (Test-Path $hesuvi)) {
    Get-File 'https://sourceforge.net/projects/hesuvi/files/HeSuVi_2.0.0.1.exe/download' $hesuvi
}
if (Test-Path $hesuvi) {
    Write-Host 'Installing HeSuVi...'
    Start-Process -FilePath $hesuvi -ArgumentList '/S' -Wait
}

$reaplugs = Join-Path $installers 'reaplugs_x64.exe'
if (-not (Test-Path $reaplugs)) {
    Get-File 'https://www.reaper.fm/reaplugs/reaplugs236_x64-install.exe' $reaplugs
}
if (Test-Path $reaplugs) {
    Write-Host 'Installing ReaPlugs...'
    Start-Process -FilePath $reaplugs -ArgumentList '/S' -Wait
}

Write-Host 'LEQ release time is set to short on the Hi-Fi Cable device after reboot.'
Write-Host 'Done. Restart the PC. Enhancements and spatial sound stay off on Hi-Fi Cable.'

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
        $backup = Join-Path $childRoot $_.PSChildName
        New-Item -Path $backup -Force | Out-Null
        $current = Get-ItemProperty -Path $fxKey
        foreach ($slot in 1, 2, 5, 6) {
            $valueName = "$fx,$slot"
            if ($current.PSObject.Properties.Name -contains $valueName) {
                New-ItemProperty -Path $backup -Name $valueName -Value $current.$valueName -PropertyType String -Force | Out-Null
            }
        }
        New-ItemProperty -Path $fxKey -Name "$fx,1" -Value $preMix -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $fxKey -Name "$fx,2" -Value $postMix -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $fxKey -Name "$fx,5" -Value $preMix -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $fxKey -Name "$fx,6" -Value $postMix -PropertyType String -Force | Out-Null
        Write-Host "LFX/GFX bound on $name"
        $bound++
    }
    if ($bound -eq 0) { Write-Host 'Hi-Fi Cable endpoint not found yet. Restart, then run setup again.' }
    Restart-Service Audiosrv -Force -ErrorAction SilentlyContinue
}

Enable-EapoOnHiFiCable
