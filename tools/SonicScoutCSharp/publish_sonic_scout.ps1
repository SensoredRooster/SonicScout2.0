param([string]$OutputPath = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'SonicScout'))
$ErrorActionPreference = 'Stop'
$destination = [IO.Path]::GetFullPath($OutputPath)
$parent = Split-Path $destination -Parent
if (-not (Split-Path $destination -Leaf) -or $destination -eq [IO.Path]::GetPathRoot($destination)) { throw 'Choose an application folder, not a drive root.' }
$stage = Join-Path $parent ('SonicScout-publish-' + [guid]::NewGuid().ToString('N'))
$backup = "$destination.previous-$(Get-Date -Format yyyyMMdd-HHmmss)"
New-Item $stage -ItemType Directory -Force | Out-Null
try {
    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { throw 'Publishing from source requires the .NET 8 SDK. Install it, then retry.' }
    & dotnet publish (Join-Path $PSScriptRoot 'SonicScout.CSharp.csproj') -c Release -r win-x64 --self-contained true -o $stage
    if ($LASTEXITCODE -ne 0) { throw "Publish failed (exit $LASTEXITCODE). Existing output has been preserved." }
    $leqProject = Join-Path (Split-Path $PSScriptRoot -Parent) 'LEQControlPanel\src\LEQControlPanel\LEQControlPanel.csproj'
    & dotnet publish $leqProject -c Release -r win-x64 --self-contained true -o (Join-Path $stage 'companion')
    if ($LASTEXITCODE -ne 0) { throw 'LEQ companion publish failed. Existing output preserved.' }
    foreach ($file in @('SonicScout.exe','SonicScout.SonicPass.exe','hostfxr.dll','Install-SonicScout.bat','setup_audio_stack.ps1','Install-SonicScout2.0.ps1','download_dependencies.ps1','library\version.txt','hrir\EAC_Default.wav')) {
        if (-not (Test-Path -LiteralPath (Join-Path $stage $file))) { throw "Incomplete package: $file is missing." }
    }
    # Unzip the complete vendor package; never separate setup from its INF/SYS/CAT files.
    $cableZip = Join-Path $stage 'installers\VBCABLE_Driver.zip'
    if (Test-Path $cableZip) { Expand-Archive $cableZip (Join-Path $stage 'installers\VBCABLE') -Force }
    $cable = Join-Path $stage 'installers\VBCABLE\VBCABLE_Setup_x64.exe'
    if (-not (Test-Path $cable)) { throw 'The bundled VB-Cable archive has no x64 setup executable.' }
    if (Test-Path -LiteralPath $destination) { Move-Item -LiteralPath $destination -Destination $backup }
    try { Move-Item -LiteralPath $stage -Destination $destination }
    catch { if (Test-Path -LiteralPath $backup) { Move-Item -LiteralPath $backup -Destination $destination }; throw }
    Write-Host "Published to $destination. Run Install-SonicScout.bat there."
    if (Test-Path $backup) { Write-Host "Previous build preserved at $backup" }
} catch { Write-Error $_; exit 1 }

