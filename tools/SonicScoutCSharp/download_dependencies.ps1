param([ValidateSet('all','vb-cable','equalizer-apo','reaplugs','hi-fi-cable','hesuvi')][string]$Component='all')
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$root=Join-Path $PSScriptRoot 'installers'
New-Item $root -ItemType Directory -Force | Out-Null
$sources=@{
    'vb-cable'=@('https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack45.zip','VBCABLE_Driver.zip','VBCABLE')
    'equalizer-apo'=@('https://sourceforge.net/projects/equalizerapo/files/1.4.2/EqualizerAPO-x64-1.4.2.exe/download','EqualizerAPO_Setup.exe','')
    'reaplugs'=@('https://www.reaper.fm/reaplugs/reaplugs236_x64-install.exe','reaplugs_x64.exe','')
    'hi-fi-cable'=@('https://download.vb-audio.com/Download_CABLE/HiFiCableAsioBridgeSetup_v1007.zip','VBHIFI_Driver.zip','VBHIFI')
    'hesuvi'=@('https://sourceforge.net/projects/hesuvi/files/HeSuVi_2.0.0.1.exe/download','HeSuVi.exe','')
}
try {
    $components=if ($Component -eq 'all') { @('vb-cable','equalizer-apo','reaplugs','hesuvi') } else { @($Component) }
    foreach ($name in $components) {
        $spec=$sources[$name]
        $path=Join-Path $root $spec[1]
        $part="$path.part"
        Write-Host "Downloading $name..."
        Invoke-WebRequest -UseBasicParsing -Uri $spec[0] -OutFile $part -TimeoutSec 120
        $bytes=[IO.File]::ReadAllBytes($part)
        $magic=if ($spec[2]) { @(80,75) } else { @(77,90) }
        if ($bytes.Length -lt 1024 -or $bytes[0] -ne $magic[0] -or $bytes[1] -ne $magic[1]) { throw "$name download is not a Windows installer/package." }
        Move-Item -LiteralPath $part -Destination $path -Force
        if ($spec[2]) {
            $extract=Join-Path $root $spec[2]
            Expand-Archive -LiteralPath $path -DestinationPath $extract -Force
            $setup=@(Get-ChildItem $extract -Recurse -File -Filter '*Setup*x64.exe')
            if ($name -eq 'vb-cable' -and ($setup.Count -eq 0 -or @(Get-ChildItem $extract -Recurse -File -Filter '*.inf').Count -eq 0)) { throw 'Incomplete VB-Cable driver package.' }
        }
        Write-Host "$name package ready."
    }
    exit 0
} catch { Write-Error $_; exit 1 }
