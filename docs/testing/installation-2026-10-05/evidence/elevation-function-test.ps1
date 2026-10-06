$Mode='Install';$DryRun=$false;$Quiet=$false;$NonInteractive=$true;$OwnershipAccepted=$true
function Test-Administrator { return $false }
function Start-Process { param($FilePath,$ArgumentList,$Verb) Write-Host "MOCKED ELEVATION: exe=$FilePath verb=$Verb arguments=$ArgumentList" }
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

    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`" -Mode Install"
    if ($Quiet) {
        $arguments += " -Quiet"
    }

    Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -Verb RunAs | Out-Null
    exit 0
}
Request-ElevationIfNeeded
