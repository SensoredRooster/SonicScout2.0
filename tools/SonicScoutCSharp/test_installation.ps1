# Regression tests run in a temporary fake installation tree. No drivers or host audio changes.
$ErrorActionPreference='Stop'
$source=Get-Content (Join-Path $PSScriptRoot 'setup_audio_stack.ps1') -Raw
$testRoot=Join-Path $env:TEMP ('SonicScout-install-tests-'+[guid]::NewGuid().ToString('N'))
New-Item $testRoot -ItemType Directory | Out-Null
$tokens=$null; $parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$parseErrors)
if ($parseErrors) { throw 'Installer syntax errors.' }
$replacements=@{
    'Test-EqualizerApoEndpointBinding'='function Test-EqualizerApoEndpointBinding { $true }'
    'Get-SystemState'='function Get-SystemState { [pscustomobject]@{ EqualizerApoInstalled=$true; EqualizerApoFilesReady=$true; VirtualRouteAvailable=$true; HiFiCableDetected=$true; WaveLinkAvailable=$false; SoundBlasterAvailable=$false; VoicemeeterInstalled=$false; VoicemeeterEndpointDetected=$false; AudioServiceRunning=$true; EndpointNames=@("SonicScout2.0") } }'
    'Get-EndpointDetail'='function Get-EndpointDetail { "Simulated healthy endpoint" }'
    'Test-Administrator'='function Test-Administrator { $true }'
}
$functions=$ast.FindAll({param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst]},$true)
foreach ($function in ($functions | Sort-Object {$_.Extent.StartOffset} -Descending)) {
    if ($replacements.ContainsKey($function.Name)) {
        $source=$source.Substring(0,$function.Extent.StartOffset)+$replacements[$function.Name]+$source.Substring($function.Extent.EndOffset)
    }
}
$scriptPath=Join-Path $testRoot 'setup_audio_stack.ps1'
Set-Content $scriptPath $source -Encoding UTF8
$fakeProgramFiles=Join-Path $testRoot 'ProgramFiles'
$fakeLogs=Join-Path $testRoot 'LocalAppData'
$fakeProgramData=Join-Path $testRoot 'ProgramData'
$files=@('VSTPlugins\ReaPlugs\reajs.dll','VSTPlugins\ReaPlugs\reaeq.dll','VSTPlugins\ReaPlugs\reacomp.dll','VSTPlugins\ReaPlugs\reagate.dll','VSTPlugins\ReaPlugs\readelay.dll','VSTPlugins\ReaPlugs\JS\Effects\SonicScout2.0\ss_spatial_engine.jsfx','VSTPlugins\SonicScout2.0\ss_spatial_engine_bravo_v2_0_0.dll','EqualizerAPO\config\HeSuVi\hesuvi.txt','EqualizerAPO\config\HeSuVi\conv.txt','EqualizerAPO\config\HeSuVi\hrir\EAC_Default.wav','EqualizerAPO\config\SonicScout2.0\library\version.txt','EqualizerAPO\config\config.txt')
foreach ($file in $files) {
    $path=Join-Path $fakeProgramFiles $file
    New-Item (Split-Path $path -Parent) -ItemType Directory -Force | Out-Null
    Set-Content $path 'SonicScout2.0\active-config'
}
$oldProgramFiles=$env:ProgramFiles; $oldLocalAppData=$env:LOCALAPPDATA
function Invoke-FakeInstall([string]$mode) {
    $command = '$env:ProgramFiles = ''{0}''; $env:LOCALAPPDATA = ''{1}''; $env:ProgramData = ''{4}''; function Get-CimInstance {{ [pscustomobject]@{{LastBootUpTime=[datetime]''2020-01-01T00:00:00Z''}} }}; & ''{2}'' -Mode {3} -NonInteractive -OwnershipAccepted; exit $LASTEXITCODE' -f $fakeProgramFiles,$fakeLogs,$scriptPath,$mode,$fakeProgramData
    $wrapper=Join-Path $testRoot "child-$mode.ps1"
    Set-Content $wrapper ("Import-Module Microsoft.PowerShell.Utility`r`n"+$command) -Encoding UTF8
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper
}
try {
    $before=Get-ChildItem $fakeProgramFiles -Recurse -File | ForEach-Object { "$($_.FullName):$($_.LastWriteTimeUtc.Ticks):$([Convert]::ToBase64String([Security.Cryptography.SHA256]::Create().ComputeHash([IO.File]::ReadAllBytes($_.FullName))))" }
    $importMarker=Join-Path $testRoot 'unexpected-import.txt'
    $fakeMain=Join-Path $testRoot 'Install-SonicScout2.0.ps1'
    Set-Content $fakeMain ("Set-Content '$importMarker' 'unexpected mutation'; throw 'Preflight imported configuration'")
    Invoke-FakeInstall Preflight
    if ($LASTEXITCODE -ne 0) { throw 'Healthy preflight should pass.' }
    $after=Get-ChildItem $fakeProgramFiles -Recurse -File | ForEach-Object { "$($_.FullName):$($_.LastWriteTimeUtc.Ticks):$([Convert]::ToBase64String([Security.Cryptography.SHA256]::Create().ComputeHash([IO.File]::ReadAllBytes($_.FullName))))" }
    if (Compare-Object $before $after) { throw 'Preflight changed installation files.' }
    if (Test-Path $fakeLogs) { throw 'Preflight wrote setup history.' }
    if (Test-Path $importMarker) { throw 'Preflight imported configuration helpers.' }
    Write-Host 'PASS: healthy preflight is read-only and does not import/mutate configuration.'
    Set-Content $scriptPath ($source.Replace('function Test-EqualizerApoEndpointBinding { $true }','function Test-EqualizerApoEndpointBinding { $false }')) -Encoding UTF8
    Invoke-FakeInstall Preflight
    if ($LASTEXITCODE -ne 2) { throw 'Installed files with no endpoint APO registration must not pass.' }
    if (Test-Path $fakeLogs) { throw 'Unbound endpoint preflight wrote setup history.' }
    Set-Content $scriptPath $source -Encoding UTF8
    Write-Host 'PASS: installed files without endpoint APO registration do not return success.'
    $bindingDefinition=($functions | Where-Object Name -eq 'Test-EqualizerApoEndpointBinding').Extent.Text
    $registryMocks=@'
$script:bind16=$false
function Get-ChildItem { param($Path,$ErrorAction) @([pscustomobject]@{PSPath='C:\fake\r8'},[pscustomobject]@{PSPath='C:\fake\r16'}) }
function Get-ItemProperty { param($Path,$ErrorAction)
    if ($Path -match 'Properties$' -and $Path -notmatch 'FxProperties$') {
        $name=if($Path -match 'r16'){'SonicScout2.0 +'}else{'SonicScout2.0'}
        return [pscustomobject]@{'{a45c254e-df1c-4efd-8020-67d146a850e0},2'=$name}
    }
    if($Path -match 'FxProperties$') {
        if($Path -notmatch 'r16' -or $script:bind16){return [pscustomobject]@{Effect='{11111111-1111-1111-1111-111111111111}'}}
        return [pscustomobject]@{}
    }
    return [pscustomobject]@{DeviceState=1}
}
function Get-Item { param($Path,$ErrorAction)
    $server=[pscustomobject]@{}
    Add-Member -InputObject $server -MemberType ScriptMethod -Name GetValue -Value {param($name) 'C:\Program Files\EqualizerAPO\EqualizerAPO.dll'}
    return $server
}
'@
    $bindingModule=New-Module -ScriptBlock ([scriptblock]::Create($registryMocks+"`r`n"+$bindingDefinition+"`r`nExport-ModuleMember -Function Test-EqualizerApoEndpointBinding"))
    if (& $bindingModule { Test-EqualizerApoEndpointBinding }) { throw 'A single bound endpoint must not mask the unbound second playback endpoint.' }
    if (-not (& $bindingModule { $script:bind16=$true; Test-EqualizerApoEndpointBinding })) { throw 'Both registered endpoints should pass binding verification.' }
    Write-Host 'PASS: APO verification requires registration on both virtual playback endpoints.'
    Remove-Module $bindingModule
    Remove-Item -LiteralPath $fakeMain
    $marker=Join-Path $fakeProgramData 'SonicScout\installation-restart.txt'
    New-Item (Split-Path $marker -Parent) -ItemType Directory -Force | Out-Null
    Set-Content $marker ([datetime]'2020-01-01T00:00:00Z').ToUniversalTime().ToString('o')
    Invoke-FakeInstall Preflight
    if ($LASTEXITCODE -ne 2) { throw 'Pending restart must block success.' }
    Set-Content $marker ([datetime]'2019-01-01T00:00:00Z').ToUniversalTime().ToString('o')
    Invoke-FakeInstall Preflight
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $marker)) { throw 'After reboot preflight should pass without deleting the marker.' }
    Write-Host 'PASS: restart is required until boot changes; preflight does not delete the marker.'
    Invoke-FakeInstall Install
    if ($LASTEXITCODE -ne 2) { throw 'Missing main installer must fail, even with healthy dependencies.' }
    Write-Host 'PASS: failed configuration does not return success.'
    # Function-only import must return without displaying a menu or requesting elevation.
    $main=Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'powershell\Install-SonicScout2.0.ps1'
    $module=New-Module -ArgumentList $main -ScriptBlock { param($path) . $path; Export-ModuleMember -Function @() }
    $bundle=& $module { Get-BundledLibraryPath }
    if (-not (Test-Path (Join-Path $bundle 'version.txt'))) { throw 'Imported helpers cannot resolve bundled library.' }
    Write-Host 'PASS: legacy helper import returns without executing its menu.'
    $elevation=($functions | Where-Object Name -eq 'Request-ElevationIfNeeded').Extent.Text
    $argumentLog=Join-Path $testRoot 'elevation-arguments.txt'
    $elevationTest=Join-Path $testRoot 'elevation-test.ps1'
    $mock=@'
$Mode='Install'; $DryRun=$false; $Quiet=$true; $NonInteractive=$true; $OwnershipAccepted=$true
$WaveLinkRouting='Yes'; $VoicemeeterFallback='No'
$script:ScriptPath='C:\Test folder\setup_audio_stack.ps1'
function Test-Administrator { $false }
function Start-Process { param($FilePath,$ArgumentList,$Verb,$WindowStyle,[switch]$Wait,[switch]$PassThru)
    Set-Content '__ARGUMENT_LOG__' ($ArgumentList+"`r`nWindowStyle=$WindowStyle")
    [pscustomobject]@{ ExitCode=23 }
}
'@
    Set-Content $elevationTest ($mock.Replace('__ARGUMENT_LOG__',$argumentLog)+"`r`n"+$elevation+"`r`nRequest-ElevationIfNeeded")
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $elevationTest
    if ($LASTEXITCODE -ne 23) { throw 'Elevation lost child exit code.' }
    $arguments=Get-Content $argumentLog -Raw
    foreach ($expected in @('-File "C:\Test folder\setup_audio_stack.ps1"','-Quiet','-NonInteractive','-OwnershipAccepted','-WaveLinkRouting Yes','-VoicemeeterFallback No','WindowStyle=Hidden')) {
        if (-not $arguments.Contains($expected)) { throw "Elevation lost $expected" }
    }
    Write-Host 'PASS: elevation preserves script path, choices, consent and child exit status.'
    $downloadRoot=Join-Path $testRoot 'download-test'
    New-Item (Join-Path $downloadRoot 'installers') -ItemType Directory -Force | Out-Null
    Copy-Item (Join-Path $PSScriptRoot 'download_dependencies.ps1') $downloadRoot
    $existing=Join-Path $downloadRoot 'installers\reaplugs_x64.exe'
    Set-Content $existing 'existing installer'
    $downloadTest=Join-Path $downloadRoot 'invalid-response.ps1'
    $mockDownload=@'
function Invoke-WebRequest { param($Uri,$OutFile,$TimeoutSec,[switch]$UseBasicParsing) Set-Content $OutFile '<html>Download failed</html>' }
& (Join-Path $PSScriptRoot 'download_dependencies.ps1') -Component reaplugs
exit $LASTEXITCODE
'@
    Set-Content $downloadTest $mockDownload
    $ErrorActionPreference='Continue'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $downloadTest 2>$null
    $downloadExit=$LASTEXITCODE
    $ErrorActionPreference='Stop'
    if ($downloadExit -eq 0 -or (Get-Content $existing -Raw).Trim() -ne 'existing installer') { throw 'Invalid download was accepted or replaced an existing installer.' }
    Write-Host 'PASS: HTML download fails and preserves the existing installer.'
} finally { $env:ProgramFiles=$oldProgramFiles; $env:LOCALAPPDATA=$oldLocalAppData }
Write-Host "Regression artifacts: $testRoot"
