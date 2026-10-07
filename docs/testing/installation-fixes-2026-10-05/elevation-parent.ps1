$ErrorActionPreference='Stop'
if($env:COMPUTERNAME -ne 'SONICSCOUT-QA'){throw 'Guest-only QA fixture'}
$Mode='Install';$DryRun=$false;$Quiet=$true;$NonInteractive=$true;$OwnershipAccepted=$true;$WaveLinkRouting='No';$VoicemeeterFallback='No'
$script:ScriptPath='C:\QA\elevation-worker.ps1'
function Test-Administrator { return $false }
function Write-Stage {param($Name,$State,$Detail) throw $Detail}
function Save-SetupHistory {}
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
        $windowStyle = if ($Quiet) { 'Hidden' } else { 'Normal' }
        # Wait for the elevated installer, not vendor GUI/browser descendants
        # that may remain open after installation and verification are complete.
        $child = Start-Process powershell.exe -ArgumentList $arguments -Verb RunAs -WindowStyle $windowStyle -PassThru
        $child.WaitForExit()
        exit $child.ExitCode
    } catch {
        Write-Stage -Name 'Administrator access' -State 'BLOCKED' -Detail "Administrator access was cancelled or unavailable. Retry and accept the Windows prompt. $($_.Exception.Message)"
        Save-SetupHistory
        exit 1
    }
}
Request-ElevationIfNeeded
