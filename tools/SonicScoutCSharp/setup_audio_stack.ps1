param(
    [ValidateSet('Preflight', 'Install')]
    [string]$Mode = 'Install',
    [switch]$Quiet,
    [switch]$NonInteractive,
    [switch]$OwnershipAccepted,
    [ValidateSet('Auto', 'Yes', 'No')]
    [string]$WaveLinkRouting = 'Auto',
    [ValidateSet('Auto', 'Yes', 'No')]
    [string]$VoicemeeterFallback = 'Auto'
)

$ErrorActionPreference = 'Stop'

$script:Stages = [System.Collections.Generic.List[object]]::new()
$script:ScriptRootPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:InstallersDirectory = Join-Path $script:ScriptRootPath 'installers'
$script:LogDirectory = Join-Path $env:LOCALAPPDATA 'SonicScout\logs'

if (-not $Quiet) {
    Write-Host 'Sonic Scout audio setup package: 2026.08.21.4'
}

function Write-Stage {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$State,
        [Parameter(Mandatory = $true)][string]$Detail
    )

    $entry = [pscustomobject]@{
        timestamp = (Get-Date).ToString('o')
        name = $Name
        state = $State
        detail = $Detail
    }
    $script:Stages.Add($entry)

    if (-not $Quiet) {
        $prefix = "[{0}] {1}" -f $State, $Name
        Write-Host "$prefix - $Detail"
    }
}

function Ensure-LogDirectory {
    if (-not (Test-Path $script:LogDirectory)) {
        New-Item -Path $script:LogDirectory -ItemType Directory -Force | Out-Null
    }
}

function Save-SetupHistory {
    Ensure-LogDirectory
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $jsonPath = Join-Path $script:LogDirectory "audio-setup-report-$stamp.json"
    $historyPath = Join-Path $script:LogDirectory 'audio-setup-history.log'

    $report = [pscustomobject]@{
        mode = $Mode
        createdAt = (Get-Date).ToString('o')
        installersDirectory = $script:InstallersDirectory
        machineName = $env:COMPUTERNAME
        userName = $env:USERNAME
        stages = $script:Stages
    }

    $report | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath -Encoding UTF8

    Add-Content -Path $historyPath -Value ("`n===== Sonic Scout audio setup run {0} ({1}) =====" -f (Get-Date), $Mode)
    foreach ($stage in $script:Stages) {
        Add-Content -Path $historyPath -Value ("[{0}] {1} - {2}" -f $stage.state, $stage.name, $stage.detail)
    }

    if (-not $Quiet) {
        Write-Host "Saved setup report: $jsonPath"
    }
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Request-ElevationIfNeeded {
    if ($Mode -ne 'Install') {
        return
    }

    if (Test-Administrator) {
        return
    }

    if (-not $Quiet) {
        Write-Host "Requesting administrator elevation for dependency installation..."
    }

    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`" -Mode Install"
    if ($Quiet) {
        $arguments += " -Quiet"
    }

    Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -Verb RunAs | Out-Null
    exit 0
}

function Read-YesNo {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [bool]$DefaultYes = $false
    )

    $suffix = if ($DefaultYes) { "[Y/n]" } else { "[y/N]" }
    $value = Read-Host "$Prompt $suffix"
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $DefaultYes
    }

    return $value.Trim().StartsWith('y', [StringComparison]::OrdinalIgnoreCase)
}

function Get-InstalledSoftwareNames {
    $uninstallRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $names = foreach ($root in $uninstallRoots) {
        Get-ItemProperty -Path $root -ErrorAction SilentlyContinue |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_.DisplayName) } |
            Select-Object -ExpandProperty DisplayName
    }

    return $names | Sort-Object -Unique
}

function Get-AudioEndpointNames {
    $names = [System.Collections.Generic.List[string]]::new()

    $pnpDeviceCommand = Get-Command Get-PnpDevice -ErrorAction SilentlyContinue
    if ($null -ne $pnpDeviceCommand) {
        try {
            Get-PnpDevice -Class AudioEndpoint -Status OK -ErrorAction Stop |
                ForEach-Object {
                    if (-not [string]::IsNullOrWhiteSpace($_.FriendlyName)) {
                        $names.Add($_.FriendlyName)
                    }
                }
        }
        catch {
        }
    }

    try {
        Get-CimInstance Win32_SoundDevice -ErrorAction Stop |
            ForEach-Object {
                if (-not [string]::IsNullOrWhiteSpace($_.Name)) {
                    $names.Add($_.Name)
                }
            }
    }
    catch {
    }

    return $names |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique
}

function Get-AudioEndpoints {
    $pnpDeviceCommand = Get-Command Get-PnpDevice -ErrorAction SilentlyContinue
    if ($null -eq $pnpDeviceCommand) {
        return @()
    }

    try {
        return @(Get-PnpDevice -Class AudioEndpoint -ErrorAction Stop |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_.FriendlyName) } |
            Select-Object Status, FriendlyName, InstanceId)
    }
    catch {
        return @()
    }
}

function Test-EqualizerApoFiles {
    $apoRoot = 'C:\Program Files\EqualizerAPO'
    return (Test-Path (Join-Path $apoRoot 'config\config.txt')) -and
        ((Test-Path (Join-Path $apoRoot 'EqualizerAPO.dll')) -or
         (Test-Path (Join-Path $apoRoot 'Editor.exe')))
}

function Get-EndpointDetail {
    $endpoints = Get-AudioEndpoints
    if ($endpoints.Count -eq 0) {
        return 'Audio endpoint details unavailable.'
    }

    return (($endpoints | ForEach-Object { "$($_.FriendlyName) [$($_.Status)]" }) -join '; ')
}

function Test-Match {
    param(
        [string[]]$Values,
        [string[]]$Patterns
    )

    foreach ($value in $Values) {
        foreach ($pattern in $Patterns) {
            if ($value -like "*$pattern*") {
                return $true
            }
        }
    }

    return $false
}

function Get-SystemState {
    $installedSoftware = Get-InstalledSoftwareNames
    $endpointNames = Get-AudioEndpointNames
    $apoFilesReady = Test-EqualizerApoFiles
    $audioService = Get-Service -Name Audiosrv -ErrorAction SilentlyContinue

    return [pscustomobject]@{
        EqualizerApoInstalled = $apoFilesReady
        EqualizerApoFilesReady = $apoFilesReady
        VirtualRouteAvailable = Test-Match -Values $endpointNames -Patterns @('Sonic Scout', 'Hi-Fi Cable', 'HIFI Cable', 'VB-Audio', 'VB-Cable', 'CABLE Input', 'Virtual Cable')
        HiFiCableDetected = Test-Match -Values $endpointNames -Patterns @('Hi-Fi Cable', 'HIFI Cable', 'VB-Audio Hi-Fi')
        WaveLinkAvailable = (Test-Match -Values $installedSoftware -Patterns @('Wave Link', 'Elgato')) -or (Test-Match -Values $endpointNames -Patterns @('Wave Link', 'Elgato'))
        SoundBlasterAvailable = (Test-Match -Values $installedSoftware -Patterns @('Sound Blaster', 'Creative')) -or (Test-Match -Values $endpointNames -Patterns @('Sound Blaster', 'Creative'))
        VoicemeeterInstalled = Test-Match -Values $installedSoftware -Patterns @('Voicemeeter')
        VoicemeeterEndpointDetected = Test-Match -Values $endpointNames -Patterns @('Voicemeeter')
        AudioServiceRunning = $null -ne $audioService -and $audioService.Status -eq 'Running'
        EndpointNames = $endpointNames
    }
}

function Find-InstallerFile {
    param(
        [Parameter(Mandatory = $true)][string[]]$Patterns
    )

    if (-not (Test-Path $script:InstallersDirectory)) {
        return $null
    }

    $files = foreach ($pattern in $Patterns) {
        Get-ChildItem -Path $script:InstallersDirectory -File -Recurse -Filter $pattern -ErrorAction SilentlyContinue
    }

    return $files |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

function Download-Installer {
    param(
        [Parameter(Mandatory = $true)][string]$Component
    )

    $downloader = Join-Path $script:ScriptRootPath 'auto_setup_dependencies.bat'
    if (-not (Test-Path $downloader)) {
        return $false
    }

    Write-Stage -Name 'Dependency download' -State 'RUNNING' -Detail "Downloading required $Component installer."
    $command = 'call "{0}" /download-only {1}' -f $downloader, $Component
    $process = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/d', '/c', $command) -Wait -PassThru
    return $process.ExitCode -eq 0
}

function Invoke-InstallerStage {
    param(
        [Parameter(Mandatory = $true)][string]$StageName,
        [Parameter(Mandatory = $true)][scriptblock]$IsInstalled,
        [Parameter(Mandatory = $true)][string[]]$InstallerPatterns,
        [Parameter(Mandatory = $true)][string]$MissingDetail,
        [string]$DownloadComponent,
        [switch]$Required
    )

    if (& $IsInstalled) {
        Write-Stage -Name $StageName -State 'READY' -Detail "$StageName already detected."
        return $true
    }

    if ($Mode -eq 'Preflight') {
        $state = if ($Required) { 'UPDATE' } else { 'READY' }
        Write-Stage -Name $StageName -State $state -Detail $MissingDetail
        return $false
    }

    $installer = Find-InstallerFile -Patterns $InstallerPatterns
    if ($null -eq $installer -and -not [string]::IsNullOrWhiteSpace($DownloadComponent)) {
        if (Download-Installer -Component $DownloadComponent) {
            $installer = Find-InstallerFile -Patterns $InstallerPatterns
        }
    }
    if ($null -eq $installer) {
        Write-Stage -Name $StageName -State 'UPDATE' -Detail "$MissingDetail Place the installer in $($script:InstallersDirectory)."
        return $false
    }

    Write-Stage -Name $StageName -State 'RUNNING' -Detail "Launching installer: $($installer.Name)"
    try {
        if ($installer.Extension -ieq '.msi') {
            $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$($installer.FullName)`" /passive /norestart" -Wait -PassThru
        }
        else {
            $process = Start-Process -FilePath $installer.FullName -Wait -PassThru
        }
    }
    catch {
        Write-Stage -Name $StageName -State 'ERROR' -Detail "Installer failed to launch: $($_.Exception.Message)"
        return $false
    }

    if ($process.ExitCode -ne 0) {
        Write-Stage -Name $StageName -State 'ERROR' -Detail "Installer exited with code $($process.ExitCode)."
        return $false
    }

    Start-Sleep -Seconds 2
    if (& $IsInstalled) {
        Write-Stage -Name $StageName -State 'FIXED' -Detail "$StageName detected after install."
        return $true
    }

    Write-Stage -Name $StageName -State 'UPDATE' -Detail "$StageName installer completed, but dependency is still not detected."
    return $false
}

Request-ElevationIfNeeded

if ($Mode -eq 'Install') {
    Write-Stage -Name 'Ownership confirmation' -State 'RUNNING' -Detail 'Confirming permission to apply Sonic Scout routing ownership changes.'
    if ($NonInteractive) {
        $ownershipAccepted = $OwnershipAccepted.IsPresent
    }
    else {
        $ownershipAccepted = Read-YesNo -Prompt 'Do you authorize Sonic Scout setup to apply audio routing ownership/settings on this machine?' -DefaultYes $false
    }
    if (-not $ownershipAccepted) {
        $blockedDetail = if ($NonInteractive) { 'Ownership/apply authorization was not provided by the app request.' } else { 'User did not approve ownership/apply authorization.' }
        Write-Stage -Name 'Ownership confirmation' -State 'BLOCKED' -Detail $blockedDetail
        Save-SetupHistory
        exit 1
    }
    Write-Stage -Name 'Ownership confirmation' -State 'READY' -Detail 'Ownership/apply authorization accepted.'
}

$state = Get-SystemState
Write-Stage -Name 'Baseline scan' -State 'READY' -Detail "Detected endpoints: $($state.EndpointNames.Count). $((Get-EndpointDetail))"

[void](Invoke-InstallerStage -StageName 'Equalizer APO' `
    -IsInstalled { (Get-SystemState).EqualizerApoInstalled } `
    -InstallerPatterns @('EqualizerAPO*.exe', 'EqualizerAPO*.msi', '*Equalizer*APO*.exe', '*Equalizer*APO*.msi') `
    -MissingDetail 'Equalizer APO is required for Sonic Scout filter apply.' `
    -DownloadComponent '/equalizer-apo')

$state = Get-SystemState
$waveLinkRouteAccepted = $state.WaveLinkAvailable
if ($state.WaveLinkAvailable) {
    if ($Mode -eq 'Install') {
        if ($NonInteractive) {
            if ($WaveLinkRouting -eq 'Yes') {
                $waveLinkRouteAccepted = $true
            }
            elseif ($WaveLinkRouting -eq 'No') {
                $waveLinkRouteAccepted = $false
            }
        }
        else {
            $waveLinkRouteAccepted = Read-YesNo -Prompt 'Elgato Wave Link was detected. Use Wave Link routing for Sonic Scout?' -DefaultYes $true
        }
    }
    $waveLinkState = if ($waveLinkRouteAccepted) { 'READY' } else { 'UPDATE' }
    $waveLinkDetail = if ($waveLinkRouteAccepted) { 'Elgato Wave Link routing selected before virtual-cable or Voicemeeter fallback.' } else { 'Wave Link was detected but not selected for Sonic Scout routing.' }
    Write-Stage -Name 'Elgato Wave Link' -State $waveLinkState -Detail $waveLinkDetail
}

if ($state.SoundBlasterAvailable) {
    Write-Stage -Name 'Creative Sound Blaster' -State 'READY' -Detail 'Sound Blaster native mixer endpoints detected. Voicemeeter fallback is not required.'
}

$compatibleNativeRouteAvailable = $waveLinkRouteAccepted -or $state.SoundBlasterAvailable
if (-not $state.VirtualRouteAvailable -and -not $compatibleNativeRouteAvailable) {
    [void](Invoke-InstallerStage -StageName 'VB-Cable Base' `
        -IsInstalled { (Get-SystemState).VirtualRouteAvailable } `
    -InstallerPatterns @('*VBCABLE*Setup*.exe', '*VB-CABLE*Setup*.exe', '*Virtual*Cable*Setup*.exe') `
        -MissingDetail 'No compatible native or virtual audio route was detected. VB-Cable is recommended.' `
        -DownloadComponent '/vb-cable')
}

$state = Get-SystemState
if (-not $state.HiFiCableDetected -and -not $compatibleNativeRouteAvailable) {
    [void](Invoke-InstallerStage -StageName 'VB-Cable Hi-Fi Route' `
        -IsInstalled { (Get-SystemState).HiFiCableDetected } `
        -InstallerPatterns @('*HIFI*CABLE*Setup*.exe', '*Hi-Fi*CABLE*Setup*.exe', '*VB*Hi*Fi*Cable*.exe') `
        -MissingDetail 'Hi-Fi Cable endpoint is not detected. Tuned channel quality may be reduced without it.' `
        -DownloadComponent '/hi-fi-cable')
}

$state = Get-SystemState
    if (-not $state.VirtualRouteAvailable -and -not $compatibleNativeRouteAvailable -and -not $state.VoicemeeterInstalled) {
    $installVoicemeeter = $false
    if ($Mode -eq 'Install') {
        if ($NonInteractive) {
            if ($VoicemeeterFallback -eq 'No') {
                $installVoicemeeter = $false
            }
            else {
                $installVoicemeeter = $true
            }
        }
        else {
            $installVoicemeeter = Read-YesNo -Prompt 'No tuned virtual route found. Install Voicemeeter fallback support now?' -DefaultYes $true
        }
    }

    if ($installVoicemeeter) {
        [void](Invoke-InstallerStage -StageName 'Voicemeeter Fallback' `
            -IsInstalled { (Get-SystemState).VoicemeeterInstalled } `
            -InstallerPatterns @('Voicemeeter*.exe', '*Voicemeeter*Setup*.exe') `
            -MissingDetail 'Voicemeeter fallback not detected.')
    }
    else {
        Write-Stage -Name 'Voicemeeter Fallback' -State 'UPDATE' -Detail 'Skipped Voicemeeter install. Tuned channel may remain unavailable on systems without virtual routes.'
    }
}
elseif ($state.VoicemeeterInstalled -or $state.VoicemeeterEndpointDetected) {
    Write-Stage -Name 'Voicemeeter Fallback' -State 'READY' -Detail 'Voicemeeter fallback support already detected.'
}

$finalState = Get-SystemState
$readyForTesting = $finalState.EqualizerApoInstalled -and ($finalState.VirtualRouteAvailable -or $waveLinkRouteAccepted -or $finalState.SoundBlasterAvailable -or $finalState.VoicemeeterInstalled -or $finalState.VoicemeeterEndpointDetected)

if (-not $finalState.EqualizerApoFilesReady) {
    Write-Stage -Name 'Equalizer APO verification' -State 'UPDATE' -Detail 'Equalizer APO was not verified by its config.txt and runtime files.'
}
else {
    Write-Stage -Name 'Equalizer APO verification' -State 'READY' -Detail 'Equalizer APO config.txt and runtime files are present.'
}

if (-not $finalState.AudioServiceRunning) {
    Write-Stage -Name 'Windows audio service' -State 'ERROR' -Detail 'Windows Audio (Audiosrv) is not running. Restart it and rerun setup.'
    $readyForTesting = $false
}
else {
    Write-Stage -Name 'Windows audio service' -State 'READY' -Detail 'Windows Audio service is running.'
}

if ($readyForTesting) {
    Write-Stage -Name 'APO Configuration' -State 'RUNNING' -Detail 'Invoking main installer to configure Equalizer APO endpoints and device binding.'
    
    # Locate and run the main Install-SonicScout2.0.ps1 installer to complete APO configuration
    $mainInstallerPaths = @(
        (Join-Path $script:ScriptRootPath 'Install-SonicScout2.0.ps1'),
        (Join-Path $script:ScriptRootPath '..\..' 'powershell' 'Install-SonicScout2.0.ps1'),
        (Join-Path $script:ScriptRootPath '..' '..' 'powershell' 'Install-SonicScout2.0.ps1')
    )
    
    $mainInstallerPath = $null
    foreach ($path in $mainInstallerPaths) {
        if (Test-Path -LiteralPath $path) {
            $mainInstallerPath = $path
            break
        }
    }
    
    if ($mainInstallerPath) {
        try {
            Write-Stage -Name 'APO Configuration' -State 'RUNNING' -Detail "Found main installer at: $mainInstallerPath"
            
            # Run the main installer in "Preflight" mode to configure APO without requiring full install
            # Pipe it through powershell with elevated privileges to ensure it has admin rights
            $configScript = @"
`$ProgressPreference = 'SilentlyContinue'
& `"$mainInstallerPath`" -Mode Preflight
"@
            $result = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
                '-NoProfile',
                '-ExecutionPolicy', 'Bypass',
                '-Command', $configScript
            ) -Wait -PassThru
            
            if ($result.ExitCode -eq 0) {
                Write-Stage -Name 'APO Configuration' -State 'READY' -Detail 'Equalizer APO endpoints configured and device-scoped config.txt written successfully.'
            } else {
                Write-Stage -Name 'APO Configuration' -State 'UPDATE' -Detail "Main installer exited with code $($result.ExitCode). Run it manually for full configuration."
            }
        } catch {
            Write-Stage -Name 'APO Configuration' -State 'UPDATE' -Detail "Could not invoke main installer: $($_.Exception.Message). Run Install-SonicScout2.0.ps1 manually to complete APO setup."
        }
    } else {
        Write-Stage -Name 'APO Configuration' -State 'UPDATE' -Detail 'Main installer (Install-SonicScout2.0.ps1) not found. Run it manually to complete APO endpoint configuration.'
    }
}

if ($readyForTesting) {
    Write-Stage -Name 'Final verification' -State 'READY' -Detail 'Audio stack order checks passed. System is ready for Sonic Scout tester flow.'
}
else {
    Write-Stage -Name 'Final verification' -State 'UPDATE' -Detail 'Setup did not detect a complete tuned-channel route. Install missing dependencies and rerun setup_audio_stack.ps1.'
}

Save-SetupHistory

if ($readyForTesting) {
    exit 0
}

exit 2
