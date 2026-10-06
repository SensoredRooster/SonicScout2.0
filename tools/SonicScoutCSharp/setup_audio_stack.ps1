param(
    [ValidateSet('Preflight', 'Install')]
    [string]$Mode = 'Install',
    [switch]$Quiet,
    [switch]$NonInteractive,
    [switch]$OwnershipAccepted,
    [switch]$DryRun,
    [ValidateSet('Auto', 'Yes', 'No')]
    [string]$WaveLinkRouting = 'Auto',
    [ValidateSet('Auto', 'Yes', 'No')]
    [string]$VoicemeeterFallback = 'Auto'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:Stages = [System.Collections.Generic.List[object]]::new()
$script:DryRunPlannedInstalls = @{}
$script:ScriptPath = $PSCommandPath
$script:ScriptRootPath = $PSScriptRoot
$script:RestartRequired = $false
$script:InstallersDirectory = Join-Path $script:ScriptRootPath 'installers'
$script:LogDirectory = Join-Path $env:LOCALAPPDATA 'SonicScout\logs'
$script:RestartMarker = Join-Path $env:ProgramData 'SonicScout\installation-restart.txt'

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

function Write-DryRunTrace {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][string]$Detail
    )

    $entry = [pscustomobject]@{
        timestamp = (Get-Date).ToString('o')
        name = $Name
        state = 'DRYRUN'
        detail = "WOULD $Action : $Detail"
    }
    $script:Stages.Add($entry)

    if (-not $Quiet) {
        Write-Host "[DRYRUN] $Name - WOULD $Action : $Detail"
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

    # DRY RUN NEVER ELEVATES. The whole point of the flag is to walk the code
    # path on the current token, so relaunching elevated would defeat it and
    # also fire a second UAC prompt for something that changes nothing.
    if ($DryRun) {
        if (-not $Quiet) {
            Write-Host "[DRYRUN] Would request administrator elevation for dependency installation."
        }
        return
    }

    if (Test-Administrator) {
        return
    }

    if (-not $Quiet) {
        Write-Host "Requesting administrator elevation for dependency installation..."
    }

    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$script:ScriptPath`" -Mode Install -WaveLinkRouting $WaveLinkRouting -VoicemeeterFallback $VoicemeeterFallback"
    if ($Quiet) {
        $arguments += " -Quiet"
    }

    if ($NonInteractive) { $arguments += ' -NonInteractive' }
    if ($OwnershipAccepted) { $arguments += ' -OwnershipAccepted' }
    try {
        $child = Start-Process powershell.exe -ArgumentList $arguments -Verb RunAs -Wait -PassThru
        exit $child.ExitCode
    } catch {
        Write-Stage -Name 'Administrator access' -State 'BLOCKED' -Detail "Administrator access was cancelled or unavailable. Retry and accept the Windows prompt. $($_.Exception.Message)"
        Save-SetupHistory
        exit 1
    }
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
        VirtualRouteAvailable = Test-Match -Values $endpointNames -Patterns @('SonicScout2.0', 'Sonic Scout', 'Hi-Fi Cable', 'HIFI Cable', 'VB-Audio', 'VB-Cable', 'CABLE Input', 'Virtual Cable')
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

    $files = @($files | Where-Object {
        if ($_.Name -match '(?i)^VBCABLE.*Setup') {
            $_.Name -match '(?i)x64' -and
            @(Get-ChildItem $_.DirectoryName -File -Filter '*.inf').Count -gt 0 -and
            @(Get-ChildItem $_.DirectoryName -File -Filter '*.sys').Count -gt 0
        } else { $true }
    })
    return $files |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

function Download-Installer {
    param(
        [Parameter(Mandatory = $true)][string]$Component
    )

    $downloader = Join-Path $script:ScriptRootPath 'auto_setup_dependencies.bat'
    if ($DryRun) {
        Write-DryRunTrace -Name 'Dependency download' -Action 'download' -Detail "Would request $Component from $downloader."
        return $false
    }

    if (-not (Test-Path $downloader)) {
        return $false
    }

    Write-Stage -Name 'Dependency download' -State 'RUNNING' -Detail "Downloading required $Component installer."
    $downloaderScript = Join-Path $script:ScriptRootPath 'download_dependencies.ps1'
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Component {1}' -f $downloaderScript, $Component.TrimStart('/')
    $process = Start-Process powershell.exe -ArgumentList $arguments -Wait -PassThru
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
        $state = 'UPDATE'
        Write-Stage -Name $StageName -State $state -Detail $MissingDetail
        return $false
    }

    if ($Mode -eq 'Install' -and -not $DryRun -and $StageName -eq 'VB-Cable Base') {
        $archive = Join-Path $script:InstallersDirectory 'VBCABLE_Driver.zip'
        if (Test-Path $archive) { Expand-Archive $archive (Join-Path $script:InstallersDirectory 'VBCABLE') -Force }
    }
    $installer = Find-InstallerFile -Patterns $InstallerPatterns
    if ($null -eq $installer -and $DryRun) {
        $downloader = Join-Path $script:ScriptRootPath 'auto_setup_dependencies.bat'
        if (-not [string]::IsNullOrWhiteSpace($DownloadComponent) -and (Test-Path -LiteralPath $downloader)) {
            $script:DryRunPlannedInstalls[$StageName] = $true
            Write-DryRunTrace -Name $StageName -Action 'download and install' -Detail "No local installer found. Would request $DownloadComponent through $downloader, then install it."
        }
        else {
            Write-DryRunTrace -Name $StageName -Action 'install' -Detail "$MissingDetail No local installer was found in $($script:InstallersDirectory), and no usable download source is available."
        }
        return $false
    }

    if ($null -eq $installer -and -not [string]::IsNullOrWhiteSpace($DownloadComponent)) {
        if (Download-Installer -Component $DownloadComponent) {
            $installer = Find-InstallerFile -Patterns $InstallerPatterns
        }
    }
    if ($null -eq $installer) {
        Write-Stage -Name $StageName -State 'UPDATE' -Detail "$MissingDetail Place the installer in $($script:InstallersDirectory)."
        return $false
    }

    # Best-effort silent arguments, so a fresh install is not a chain of third-party
    # GUI click-throughs.
    #
    # SAFETY CONTRACT: these are applied BEST-EFFORT and the caller still re-verifies
    # with & $IsInstalled afterwards (see the FIXED/UPDATE report at the end of
    # Invoke-InstallerStage). An installer that ignores the flags simply shows its GUI
    # exactly as it did before, so this can never be worse than the old behaviour -- and
    # one that accepts them but fails silently is caught by that same verification
    # instead of being reported as success.
    #
    # Deliberately NOT applied to the VB-Audio / VB-Cable driver pack. It has no
    # reliable silent mode: even with /S it raises a modal "I am aware of the potential
    # risks" consent that must be clicked, so passing the flag only hides the earlier
    # screens while still blocking on that one. It is left fully interactive, and
    # guided through by the stage detail below.
    $script:SilentInstallArguments = @{
        'equalizerapo'  = @('/S')
        'voicemeeter'   = @('/S')
        'reaplugs'      = @('/S')
        'he suvi'       = @('/S')
        'hesuvi'        = @('/S')
    }

    function Get-SilentInstallArguments {
        <#
        .SYNOPSIS
            Maps an installer file name to its silent switches.
        .DESCRIPTION
            Only installers known to accept them get flags. An UNKNOWN installer gets
            nothing, on purpose: guessing a switch for software we know nothing about is
            a worse failure mode than showing its window, and the fallback already
            behaves correctly.
        #>
        param([Parameter(Mandatory)] [string]$FileName)

        $name = $FileName.ToLowerInvariant()
        foreach ($key in $script:SilentInstallArguments.Keys) {
            if ($name -like "*$key*") {
                return $script:SilentInstallArguments[$key]
            }
        }
        return @()
    }

    $isVBAudio = $installer.Name -match '(?i)vb-?(audio|cable)'
    $silentArgs = Get-SilentInstallArguments -FileName $installer.Name

    # DRY RUN: report exactly what would happen and stop. Nothing is downloaded,
    # nothing is launched, and the caller's re-verification below is skipped so
    # the trace never claims a dependency that was not actually installed.
    if ($DryRun) {
        $script:DryRunPlannedInstalls[$StageName] = $true
        if ($installer.Extension -ieq '.msi') {
            $arguments = "/i `"$($installer.FullName)`" /passive /norestart"
            Write-DryRunTrace -Name $StageName -Action 'install' -Detail "Would launch msiexec.exe $arguments."
        }
        elseif ($isVBAudio) {
            Write-DryRunTrace -Name $StageName -Action 'install interactively' -Detail "Would launch $($installer.FullName). VB-Audio has no reliable silent mode; its modal consent must be clicked."
        }
        else {
            $arguments = if ($silentArgs.Count -gt 0) { $silentArgs -join ' ' } else { '(interactive; no known silent switches)' }
            Write-DryRunTrace -Name $StageName -Action 'install' -Detail "Would launch $($installer.FullName) $arguments."
        }
        return $false
    }

    Write-Stage -Name $StageName -State 'RUNNING' -Detail "Launching installer: $($installer.Name)"
    if ($StageName -eq 'Equalizer APO') {
        Write-Stage -Name $StageName -State 'RUNNING' -Detail 'If Device Selector opens, select SonicScout2.0 / CABLE Input playback. Leave unrelated microphones and speakers unchecked. Complete the dialogs, then restart Windows.'
    }
    if ($StageName -eq 'VB-Cable Hi-Fi Route') {
        Write-Stage -Name $StageName -State 'RUNNING' -Detail 'Click Install in the Hi-Fi Cable window, complete its prompts, then close it. Closing without installing leaves this component incomplete.'
    }

    # VB-Audio is named explicitly because it is the one installer that must stay
    # interactive, and saying so here is what turns an unexplained pause into
    # step-by-step guidance.
    try {
        if ($installer.Extension -ieq '.msi') {
            $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$($installer.FullName)`" /passive /norestart" -Wait -PassThru
        }
        elseif ($isVBAudio) {
            Write-Stage -Name $StageName -State 'RUNNING' -Detail @"
VB-Audio driver pack needs one confirmation from you.
  1. A 'VBCABLE driver setup' window will appear. Read the notice.
  2. Click 'Install Driver'.
  3. If Windows asks to allow changes, choose Yes.
  4. Wait for 'Installation complete', then close the window.
Other components may open their own dialogs. Complete each prompt and restart Windows after driver installation.
"@
            $process = Start-Process -WorkingDirectory $installer.DirectoryName -FilePath $installer.FullName -Wait -PassThru
        }
        elseif ($silentArgs.Count -gt 0) {
            $joined = $silentArgs -join ' '
            Write-Stage -Name $StageName -State 'RUNNING' -Detail "Launching installer: $($installer.Name) $joined"
            $process = Start-Process -WorkingDirectory $installer.DirectoryName -FilePath $installer.FullName -ArgumentList $silentArgs -Wait -PassThru
        }
        else {
            $process = Start-Process -WorkingDirectory $installer.DirectoryName -FilePath $installer.FullName -Wait -PassThru
        }
    }
    catch {
        Write-Stage -Name $StageName -State 'ERROR' -Detail "Installer failed to launch: $($_.Exception.Message)"
        return $false
    }

    if ($process.ExitCode -in @(3010,1641)) { $script:RestartRequired = $true }
    elseif ($process.ExitCode -ne 0) {
        Write-Stage -Name $StageName -State 'ERROR' -Detail "Installer exited with code $($process.ExitCode)."
        return $false
    }

    if ($StageName -like '*Cable*' -or $StageName -eq 'Equalizer APO') { $script:RestartRequired = $true }
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
    if ($DryRun) {
        Write-DryRunTrace -Name 'Ownership confirmation' -Action 'request' -Detail 'Would ask the user to authorize routing ownership changes; the dry run continues without applying changes.'
    }
    else {
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
}

$state = Get-SystemState
Write-Stage -Name 'Baseline scan' -State 'READY' -Detail "Detected endpoints: $($state.EndpointNames.Count). $((Get-EndpointDetail))"

# Cable first. Equalizer APO's Device Selector only lists devices that already
# exist, and it is the step a tester cannot guess. Install VB-Cable, let the
# endpoints enumerate, then open E-APO so CABLE Input / SonicScout2.0 is present.
if (-not $state.VirtualRouteAvailable) {
    [void](Invoke-InstallerStage -StageName 'VB-Cable Base' `
        -IsInstalled { (Get-SystemState).VirtualRouteAvailable } `
        -InstallerPatterns @('*VBCABLE*Setup*.exe', '*VB-CABLE*Setup*.exe', '*Virtual*Cable*Setup*.exe') `
        -MissingDetail 'VB-Cable is required for Sonic Scout routing.' `
        -DownloadComponent '/vb-cable')
    $state = Get-SystemState
}

[void](Invoke-InstallerStage -StageName 'Equalizer APO' `
    -IsInstalled { (Get-SystemState).EqualizerApoInstalled } `
    -InstallerPatterns @('EqualizerAPO*.exe', 'EqualizerAPO*.msi', '*Equalizer*APO*.exe', '*Equalizer*APO*.msi') `
    -MissingDetail 'Equalizer APO is required for Sonic Scout filter apply.' `
    -DownloadComponent '/equalizer-apo')

$state = Get-SystemState
$waveLinkRouteAccepted = $state.WaveLinkAvailable
if ($state.WaveLinkAvailable) {
    if ($Mode -eq 'Install') {
        if ($DryRun) {
            if ($NonInteractive) {
                if ($WaveLinkRouting -eq 'Yes') {
                    $waveLinkRouteAccepted = $true
                }
                elseif ($WaveLinkRouting -eq 'No') {
                    $waveLinkRouteAccepted = $false
                }
            }
            else {
                Write-DryRunTrace -Name 'Elgato Wave Link' -Action 'prompt' -Detail 'Would ask whether to use Wave Link routing; simulating the default Yes response.'
                $waveLinkRouteAccepted = $true
            }
        }
        elseif ($NonInteractive) {
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

$state = Get-SystemState
if (-not $state.VirtualRouteAvailable -and -not $compatibleNativeRouteAvailable) {
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
        if ($DryRun) {
            if ($NonInteractive) {
                $installVoicemeeter = $VoicemeeterFallback -ne 'No'
            }
            else {
                Write-DryRunTrace -Name 'Voicemeeter Fallback' -Action 'prompt' -Detail 'Would ask whether to install Voicemeeter; simulating the default Yes response.'
                $installVoicemeeter = $true
            }
        }
        elseif ($NonInteractive) {
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

if (-not $((Get-ChildItem "${env:ProgramFiles}\VSTPlugins\ReaPlugs\*.dll" -ErrorAction SilentlyContinue).Count -ge 5)) {
    [void](Invoke-InstallerStage -StageName 'ReaPlugs' `
        -IsInstalled {
            $reaplugsDlls = @(Get-ChildItem "${env:ProgramFiles}\VSTPlugins\ReaPlugs\*.dll" -ErrorAction SilentlyContinue)
            $reaplugsDlls.Count -ge 5
        } `
        -InstallerPatterns @('reaplugs*.exe', '*reaplugs*install*.exe') `
        -MissingDetail 'ReaPlugs VST effects are required for Sonic Scout.' `
        -DownloadComponent '/reaplugs')
}

[void](Invoke-InstallerStage -StageName 'HeSuVi' `
    -IsInstalled { Test-Path "${env:ProgramFiles}\EqualizerAPO\config\HeSuVi\hesuvi.txt" } `
    -InstallerPatterns @('HeSuVi*.exe') -MissingDetail 'HeSuVi is not installed.' -DownloadComponent '/hesuvi')

$finalState = Get-SystemState
$equalizerApoWouldBeInstalled = $finalState.EqualizerApoInstalled -or (
    $DryRun -and $script:DryRunPlannedInstalls.ContainsKey('Equalizer APO')
)
$readyForTesting = $equalizerApoWouldBeInstalled -and ($finalState.VirtualRouteAvailable -or $waveLinkRouteAccepted -or $finalState.SoundBlasterAvailable -or $finalState.VoicemeeterInstalled -or $finalState.VoicemeeterEndpointDetected)

if ($DryRun -and $script:DryRunPlannedInstalls.ContainsKey('Equalizer APO') -and -not $finalState.EqualizerApoFilesReady) {
    Write-DryRunTrace -Name 'Equalizer APO verification' -Action 'verify' -Detail 'Would verify Equalizer APO config.txt and runtime files after the planned installation; the dry run cannot verify files that were not installed.'
}
elseif (-not $finalState.EqualizerApoFilesReady) {
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

# Startup preflight never imports configuration helpers or writes files.
if ($readyForTesting -and $Mode -eq 'Install') {
    if ($DryRun) {
        Write-DryRunTrace -Name 'APO Configuration' -Action 'configure' -Detail 'Would install bundled library/plugins/HRIR and configure endpoints; no changes made.'
    } else {
        try {
            $mainInstaller = Join-Path $script:ScriptRootPath 'Install-SonicScout2.0.ps1'
            if (-not (Test-Path $mainInstaller)) {
                $mainInstaller = Join-Path (Split-Path (Split-Path $script:ScriptRootPath -Parent) -Parent) 'powershell\Install-SonicScout2.0.ps1'
            }
            if (-not (Test-Path $mainInstaller)) { throw 'Main installer is missing. Extract the complete package and retry.' }
            # Isolate legacy script globals and StrictMode from orchestration.
            $helpers = New-Module -ArgumentList $mainInstaller -ScriptBlock { param($path) . $path }
            $configurationOk = & $helpers {
                $bundle = Get-BundledLibraryPath
                if (-not $bundle) { throw 'The bundled library is missing.' }
                $target = Join-Path $script:SonicScout20Root 'library'
                $installedVersion = Join-Path $target 'version.txt'
                if (-not (Test-Path $installedVersion) -or (Get-Content $installedVersion -Raw) -ne (Get-Content (Join-Path $bundle 'version.txt') -Raw)) {
                    $copy = Invoke-AtomicLibraryLayDown -SourceRoot $bundle -LibraryRoot $target -PreserveOld
                    if (-not $copy.Ok) { throw 'Library installation failed; the previous library was preserved.' }
                }
                if (-not (Install-JsfxPlugins)) { throw 'JSFX plugin installation failed.' }
                if (-not (Install-VstPlugins)) { throw 'VST plugin installation failed.' }
                if (-not (Install-SonicScout20HRIR)) { throw 'HRIR installation failed.' }
                $endpoints = Set-SonicScout20Endpoints -IconBaseUrl '' -IncludeVoicemeeter $false
                if (-not $endpoints.Verified -or -not $endpoints.Render8) { throw 'Endpoints could not be verified. Restart Windows and retry.' }
                $config = Join-Path $env:ProgramFiles 'EqualizerAPO\config\config.txt'
                if (-not (Test-Path $config) -or -not (Select-String -LiteralPath $config -SimpleMatch 'SonicScout2.0\active-config' -Quiet)) {
                    if (-not (Write-InitialConfig -RenderGuid8 $endpoints.Render8 -RenderGuid16 $endpoints.Render16)) { throw 'Could not write the managed configuration.' }
                }
                return $true
            }
            if (-not $configurationOk) { throw 'Configuration did not complete.' }
            Write-Stage -Name 'APO Configuration' -State 'READY' -Detail 'Bundled library, plugins, HRIR and managed configuration verified.'
        } catch {
            Write-Stage -Name 'APO Configuration' -State 'ERROR' -Detail $_.Exception.Message
            $readyForTesting = $false
        }
    }
}

if (-not $DryRun) {
    $requiredFiles = @(
        "${env:ProgramFiles}\VSTPlugins\ReaPlugs\reajs.dll",
        "${env:ProgramFiles}\VSTPlugins\ReaPlugs\JS\Effects\SonicScout2.0\ss_spatial_engine.jsfx",
        "${env:ProgramFiles}\VSTPlugins\SonicScout2.0\ss_spatial_engine_bravo_v2_0_0.dll",
        "${env:ProgramFiles}\EqualizerAPO\config\HeSuVi\hesuvi.txt",
        "${env:ProgramFiles}\EqualizerAPO\config\HeSuVi\hrir\EAC_Default.wav",
        "${env:ProgramFiles}\EqualizerAPO\config\SonicScout2.0\library\version.txt"
    )
    foreach ($file in $requiredFiles) {
        if (-not (Test-Path -LiteralPath $file)) {
            Write-Stage -Name 'Installed assets' -State 'UPDATE' -Detail "Missing required file: $file. Run installation again."
            $readyForTesting = $false
        }
    }
    $config = "${env:ProgramFiles}\EqualizerAPO\config\config.txt"
    if (-not (Test-Path $config) -or -not (Select-String -LiteralPath $config -SimpleMatch 'SonicScout2.0\active-config' -Quiet)) {
        Write-Stage -Name 'Managed configuration' -State 'UPDATE' -Detail 'SonicScout managed configuration is missing. Run installation again.'
        $readyForTesting = $false
    }
    if (@($script:Stages | Where-Object state -in @('ERROR','BLOCKED','UPDATE')).Count -gt 0) { $readyForTesting = $false }
    if ($script:RestartRequired) {
        $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
        New-Item (Split-Path $script:RestartMarker -Parent) -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath $script:RestartMarker -Value $boot -Encoding UTF8
    }
    $pendingRestart = $false
    if (Test-Path -LiteralPath $script:RestartMarker) {
        $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
        $pendingRestart = (Get-Content -LiteralPath $script:RestartMarker -Raw).Trim() -eq $boot
        if (-not $pendingRestart -and $Mode -eq 'Install') { Remove-Item -LiteralPath $script:RestartMarker }
    }
    if ($pendingRestart) {
        Write-Stage -Name 'Restart Windows' -State 'UPDATE' -Detail 'Drivers were installed. Restart Windows, then run Install-SonicScout.bat again to verify and finish.'
        $readyForTesting = $false
    }
}

if ($readyForTesting) {
    if ($DryRun) {
        Write-DryRunTrace -Name 'Final verification' -Action 'verify' -Detail 'Would run final audio-stack checks after the planned installs; no installation was performed or verified.'
    }
    else {
        Write-Stage -Name 'Final verification' -State 'READY' -Detail 'Audio stack order checks passed. System is ready for Sonic Scout tester flow.'
    }
}
else {
    Write-Stage -Name 'Final verification' -State 'UPDATE' -Detail 'Setup did not detect a complete tuned-channel route. Install missing dependencies and rerun setup_audio_stack.ps1.'
}

if ($DryRun) {
    Write-DryRunTrace -Name 'Setup history' -Action 'save' -Detail "Would save the setup report under $script:LogDirectory; no files are written during a dry run."
}
elseif ($Mode -eq 'Install') {
    Save-SetupHistory
}

if ($readyForTesting -and (-not $DryRun -or $finalState.AudioServiceRunning)) {
    exit 0
}

exit 2





