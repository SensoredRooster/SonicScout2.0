# Runs in the tester's interactive (non-elevated) session inside the QA VM.
param([int]$SetupTimeoutMinutes = 40, [string]$Out = 'C:\QA\out')
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory $Out -Force | Out-Null
Start-Transcript (Join-Path $Out ("drive-" + (Get-Date -Format HHmmss) + ".txt")) -Force | Out-Null
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$root = [Windows.Automation.AutomationElement]::RootElement
function Find-ById([string]$id, [int]$timeoutSec = 60) {
    $cond = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $e = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $cond)
        if ($e) { return $e }
        Start-Sleep -Milliseconds 700
    }
    return $null
}
function Get-Text($e) { if ($e) { $e.Current.Name } else { '<missing>' } }
function Invoke-El($e) { $e.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke() }

$exe = 'C:\Program Files\SonicScout\SonicScout.exe'
if (-not (Get-Process SonicScout -ErrorAction SilentlyContinue)) { Start-Process $exe }
$consent = Find-ById 'OwnershipConsentCheckBox' 240
if (-not $consent) { "Setup window did not appear"; $s = $null }
else {
    Start-Sleep 3
    $combo = Find-ById 'DefaultOutputComboBox' 5
    "Selected output: " + (Get-Text $combo)
    try { $sel = $combo.GetCurrentPattern([Windows.Automation.SelectionPattern]::Pattern).Current.GetSelection(); "Selection: " + ($sel | % { $_.Current.Name }) } catch {}
    $toggle = $consent.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
    if ($toggle.Current.ToggleState -ne 'On') { $toggle.Toggle() }
    Invoke-El (Find-ById 'BeginSetupButton' 10)
    $deadline = (Get-Date).AddMinutes($SetupTimeoutMinutes)
    $last = ''
    while ((Get-Date) -lt $deadline) {
        $summary = Get-Text (Find-ById 'SummaryText' 5)
        $step = Get-Text (Find-ById 'StepText' 5)
        if ("$step|$summary" -ne $last) { "$(Get-Date -Format HH:mm:ss) $step | $summary"; $last = "$step|$summary" }
        $done = Find-ById 'DoneButton' 1
        $begin = Find-ById 'BeginSetupButton' 1
        if ($summary -match 'Setup complete|summary:|All checks passed|Restart Windows|incomplete|error' -and $begin -and $begin.Current.IsEnabled) { break }
        if ($summary -match 'Setup complete|All checks passed') { break }
        Start-Sleep 5
    }
    # Dump checklist rows
    $list = Find-ById 'CheckList' 3
    if ($list) {
        $items = $list.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)
        ($items | % { $_.Current.Name } | ? { $_ } | Select -Unique) -join "`n" | Set-Content (Join-Path $Out 'setup-checklist.txt')
    }
    "FINAL: $step | $summary"
    $done = Find-ById 'DoneButton' 3
    if ($done -and $done.Current.IsEnabled) { Invoke-El $done }
}
Stop-Transcript | Out-Null
