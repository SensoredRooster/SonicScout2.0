# ============================================================================
# Install-SonicScout2.0.ps1 -- SonicScout2.0 Audio Stack Installer
# ============================================================================
# Licensed under GPL-3.0 -- https://www.gnu.org/licenses/gpl-3.0.html
# ============================================================================
# Self-contained installer for the SonicScout2.0 audio stack.
# Three paths: Approved Device | DAC/Amp/Onboard | Uninstall
#
# Usage:  irm https://raw.githubusercontent.com/sensoredrooster/SonicScout2.0/main/powershell/Install-SonicScout2.0.ps1 | iex
#    or:  powershell -ExecutionPolicy Bypass -File Install-SonicScout2.0.ps1
#
# This script configures the E-APO starter chain and managed profiles. Routing and
# LEQ device setup remain guided user steps; the SonicScout2.0 app is optional.
# ============================================================================

param(
    # DRY RUN: walk the install path and print what each stage WOULD do, without
    # doing it. Nothing is downloaded, installed, deleted, renamed or rebooted.
    # Reserved for -File invocation; 'irm ... | iex' cannot forward switches.
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# PS 5.1 perf: IWR progress bars tank download speed dramatically
$ProgressPreference = 'SilentlyContinue'

# .NET Framework caps outbound connections at 2 per host and the limit is read when a
# host's ServicePoint is first created, so this has to happen before any download.
# The GitHub release is the fallback for three specs, which overruns 2 as soon as a
# mirror retry fires. BITS has its own transport and is unaffected either way.
try { [System.Net.ServicePointManager]::DefaultConnectionLimit = 12 } catch { }

$script:Version = "1.2"
# Resolve 8.3 short names (e.g. LEDZIU~1) to long form for BITS compatibility
$tempParent = $env:TEMP
if (Test-Path -LiteralPath $tempParent) {
    $resolvedTemp = Get-Item -LiteralPath $tempParent -ErrorAction SilentlyContinue
    if ($resolvedTemp) { $tempParent = $resolvedTemp.FullName }
}
$script:TempPath = Join-Path $tempParent "SonicScout2.0-Setup"
$script:BoxWidth = 70
$script:ScreenWidth = 120
$script:BoxMargin = ' ' * [Math]::Floor(($script:ScreenWidth - $script:BoxWidth - 2) / 2)

$script:HiFiCableRegistryKeys = @(
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\VB:ASIOBridge {17359A74-1236-5467}",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\VB:ASIOBridge {17359A74-1236-5467}",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\VB:HiFiCable {17359A74-1236-5467}",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\VB:HiFiCable {17359A74-1236-5467}"
)

# Non-fatal download failures, keyed by component. Populated by Start-ParallelDownloads.
# Initialized here because Get-Downloads skips that function entirely when nothing needs
# downloading (a fully-installed re-run), and StrictMode forbids reading it unset.
$script:DownloadWarnings = @{}

# Replaced wholesale by Set-SonicScout20Endpoints. Initialized here so the completion summary
# can read .Verified even on a path where the endpoint step never ran. Verified defaults
# to $true: an endpoint step that did not run has not failed.
$script:SonicScout20Endpoints = [pscustomobject]@{ Render8 = $null; Render16 = $null; Capture = $null; Verified = $true }

# Set by Write-InitialConfig when config.txt is written with placeholder Include paths.
# Defaults to $false so a path that never wrote a config does not warn about one.
$script:ConfigIsPlaceholder = $false

# Path of the FOREIGN config.txt backup taken this run, if any. Backup-EAPOConfigFile
# is now called twice on the Install path -- once before E-APO's own setup runs (which
# can replace config.txt) and once before Write-InitialConfig overwrites it -- and only
# the first call sees the user's real file. See Backup-EAPOConfigFile.
$script:ForeignConfigBackup = $null

# Outcome of the SonicScout2.0 plugin removal inside Uninstall-ExistingEAPO. A script
# variable rather than a return value: that function returns a single status string
# the caller switches on, and the plugin result is a SECOND, independent outcome --
# widening the return type would break that switch for no gain. Initialized here so
# the completion box can read it on the many paths where the plugin step never ran
# (no E-APO, so an early NotFound), which StrictMode would otherwise fault on.
#   None       - nothing to remove, or the step was never reached. Reports nothing.
#   Removed    - both folders gone.
#   SkippedSS  - the SonicScout2.0 app is installed and shares them. Nothing deleted.
#   Failed     - at least one folder survived; FailedPaths names the survivors.
$script:PluginRemoval = [pscustomobject]@{
    State       = 'None'
    FailedPaths = @()
}

# ---- 2026.07-Overhaul single-point configuration --------------------------
# Canonical SonicScout2.0 root (E-APO config). Shared by the release extract target,
# the desktop-shortcut TargetPath, and every config.txt include.
$script:SonicScout20Root = Join-Path $env:ProgramFiles "EqualizerAPO\config\SonicScout2.0"

# ---- Backup root resolution ---------------------------------------------
# Cache for the PROVEN-writable backup root, plus whether THIS run created it.
# Resolving a backup root is not a read-only act (it creates the folder and writes a
# probe file to prove usability), so the two are tracked separately: Remove-UnusedBackupRoot
# must only ever delete a root this run created, never one the user already had holding
# previous backups. Declared here so StrictMode cannot fault on the many paths where
# resolution never ran.
$script:BackupRoot = $null
$script:BackupRootCreatedByUs = $false

# R2-hosted assets: endpoint icons, HRIR wavs, and the third-party installer mirror.
$script:AssetBase = "https://raw.githubusercontent.com/sensoredrooster/SonicScout2.0/main"

# R2 mirror base for the library release zip (public SonicScout2.0/ subdir).
$script:LibraryMirrorBase = "https://github.com/sensoredrooster/SonicScout2.0/releases/latest/download"

# Library release (single zip asset). SonicScout2.0 manages its own release asset.
$script:LibraryReleaseApi = "https://api.github.com/repos/sensoredrooster/SonicScout2.0/releases/latest"

# Use the verified GitHub release asset directly. The CDN mirror is retained as a
# fallback for older deployments, but it is not required for a fresh install.
$script:UseGitHubRelease = $true

# The flattened release zip filename; must match what is uploaded to R2 /
# published to GitHub. (During testing this is set to the random test-zip name.)
# Fallback only. The live name is derived from CDN latest-version.txt
# as "SonicScout2.0-$cdnVersion.zip"; keep this in step with the stamp in
# library/version.txt.
$script:LibraryReleaseAsset = 'SonicScout2.0-2026.07.1-Overhaul.zip'

# Anonymous setup counter endpoint. Fire-and-forget; silent on failure.
$script:SetupPingUrl = $null

# ============================================================================
# SECTION 1: Console UI Helpers
# ============================================================================

function Center-Text {
    <#
    .SYNOPSIS
        Centers text within the given width, padding both sides with spaces.
    #>
    param(
        [string]$Text,
        [int]$Width
    )
    $spaces = [Math]::Max(0, $Width - $Text.Length)
    $leftPad = [Math]::Floor($spaces / 2)
    $rightPad = $spaces - $leftPad
    return (' ' * $leftPad) + $Text + (' ' * $rightPad)
}

function Write-CenteredBlock {
    <#
    .SYNOPSIS
        Prints a block of lines centered on screen. Lines are left-aligned
        relative to each other, with the whole block centered horizontally.
    #>
    param(
        [hashtable[]]$Lines,
        [int]$ScreenWidth = $script:ScreenWidth
    )
    $maxLen = ($Lines | ForEach-Object { $_.Text.Length } | Measure-Object -Maximum).Maximum
    $margin = ' ' * [Math]::Max(0, [Math]::Floor(($ScreenWidth - $maxLen) / 2))
    foreach ($l in $Lines) {
        if ($l.ContainsKey('NoNewline') -and $l.NoNewline) {
            Write-Host "$margin$($l.Text)" -ForegroundColor $l.Color -NoNewline
        } else {
            Write-Host "$margin$($l.Text)" -ForegroundColor $l.Color
        }
    }
    return $margin
}

function Write-Banner {
    <#
    .SYNOPSIS
        Displays the SonicScout2.0 installer title banner with version info.
    #>
    $w = 70
    $border = [string]::new([char]0x2550, $w)
    $L = [char]0x2551   # left/right border char
    $blank = ' ' * $w
    # Center the box itself on a 120-column screen
    $m = ' ' * [Math]::Floor(($script:ScreenWidth - $w - 2) / 2)

    Write-Host ""
    Write-Host "$m$([char]0x2554)$border$([char]0x2557)" -ForegroundColor Yellow
    Write-Host "$m$L$(Center-Text 'SonicScout2.0 Manual Installer' $w)$L" -ForegroundColor Yellow
    Write-Host "$m$L$(Center-Text 'updated Jul 2026' $w)$L" -ForegroundColor Yellow
    Write-Host "$m$L$(Center-Text "github.com/sensoredrooster  $([char]0x2022)  v$script:Version" $w)$L" -ForegroundColor Yellow
    Write-Host "$m$L$blank$L" -ForegroundColor Yellow
    # YouTube line (Cyan interior, Yellow borders)
    Write-Host "$m$L" -ForegroundColor Yellow -NoNewline
    Write-Host "$(Center-Text 'Free Video Guide: www.github.com/sensoredrooster' $w)" -ForegroundColor Cyan -NoNewline
    Write-Host "$L" -ForegroundColor Yellow
    # License line (DarkGray interior)
    Write-Host "$m$L" -ForegroundColor Yellow -NoNewline
    Write-Host "$(Center-Text 'Licensed under GPL-3.0' $w)" -ForegroundColor DarkGray -NoNewline
    Write-Host "$L" -ForegroundColor Yellow
    Write-Host "$m$L$blank$L" -ForegroundColor Yellow
    # Release note (DarkGray, 2 lines)
    Write-Host "$m$L" -ForegroundColor Yellow -NoNewline
    Write-Host "$(Center-Text 'Guided Install: VB-CABLE + E-APO audio stack.' $w)" -ForegroundColor DarkGray -NoNewline
    Write-Host "$L" -ForegroundColor Yellow
    Write-Host "$m$L" -ForegroundColor Yellow -NoNewline
    Write-Host "$(Center-Text '2026.07 Overhaul: 16-channel spatial + auto library.' $w)" -ForegroundColor DarkGray -NoNewline
    Write-Host "$L" -ForegroundColor Yellow
    Write-Host "$m$([char]0x255A)$border$([char]0x255D)" -ForegroundColor Yellow
    Write-Host ""
}

function Write-ActionBox {
    <#
    .SYNOPSIS
        Draws a bordered action-required prompt and waits for Enter.
    #>
    param(
        [string[]]$Lines
    )

    $maxLen = ($Lines | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
    $width = [Math]::Max($maxLen + 4, $script:BoxWidth)
    $border = [string]::new([char]0x2550, $width)
    $L = [char]0x2551

    $m = $script:BoxMargin

    Write-Host ""
    Write-Host "$m$([char]0x2554)$border$([char]0x2557)" -ForegroundColor Yellow
    Write-Host "$m$L$(Center-Text 'ACTION REQUIRED' $width)$L" -ForegroundColor Yellow
    Write-Host "$m$L$(' ' * $width)$L" -ForegroundColor Yellow
    foreach ($line in $Lines) {
        Write-Host "$m$L" -ForegroundColor Yellow -NoNewline
        Write-Host "  $line" -NoNewline
        Write-Host "$(' ' * [Math]::Max(0, $width - $line.Length - 2))$L" -ForegroundColor Yellow
    }
    Write-Host "$m$L$(' ' * $width)$L" -ForegroundColor Yellow
    Write-Host "$m$L$(Center-Text 'Press Enter when ready...' $width)$L" -ForegroundColor Yellow
    Write-Host "$m$([char]0x255A)$border$([char]0x255D)" -ForegroundColor Yellow
    Write-Host ""

    Read-Host | Out-Null

    # Instant feedback so the user knows we received the input (no "hang" feeling)
    $frames = @('|','/','-','\')
    for ($i = 0; $i -lt 6; $i++) {
        $frame = $frames[$i % $frames.Count]
        Write-Host "`r$m$frame Working..." -NoNewline -ForegroundColor DarkGray
        Start-Sleep -Milliseconds 120
    }
    Write-Host "`r$m$([char]0x2713) Got it, continuing...          " -ForegroundColor Green
}

function Get-ProgressBar {
    <#
    .SYNOPSIS
        Returns an ASCII progress bar string.
        Percentage mode: filled proportional bar.  Pulse mode: bouncing animation.
    .PARAMETER Width
        Total inner width of the bar (between the brackets).
    .PARAMETER Percent
        0-100 for a determinate bar.  -1 for indeterminate pulse.
    .PARAMETER Frame
        Frame counter driving the pulse animation.
    #>
    param(
        [int]$Width = 28,
        [int]$Percent = -1,
        [int]$Frame = 0
    )
    if ($Percent -ge 0) {
        $filled = [Math]::Floor($Width * [Math]::Min($Percent, 100) / 100)
        if ($filled -ge $Width) {
            $bar = "=" * $Width
        } elseif ($filled -gt 0) {
            $bar = ("=" * ($filled - 1)) + ">"
        } else {
            $bar = ""
        }
        return "[" + $bar.PadRight($Width) + "]"
    }
    # Indeterminate pulse: 5-char slug bouncing left-to-right
    $slug = 5
    $travel = $Width - $slug
    if ($travel -lt 1) { $travel = 1 }
    $pos = $Frame % ($travel * 2)
    if ($pos -ge $travel) { $pos = $travel * 2 - $pos }
    $inner = (" " * $pos) + ("=" * ($slug - 1)) + ">" + (" " * [Math]::Max(0, $Width - $pos - $slug))
    return "[" + $inner.Substring(0, $Width) + "]"
}

function Format-ByteSize {
    <#
    .SYNOPSIS
        Formats a byte count as "12.3 MB" / "482 KB", or "" below 1 KB.
    .PARAMETER Bracket
        Wrap the result in square brackets, matching the download tally's "[12.3 MB]".
        Sub-1-KB still returns "" so the caller emits nothing rather than "[]".
    #>
    param(
        [long]$Bytes,
        [switch]$Bracket
    )
    $s = ""
    if ($Bytes -ge 1MB) { $s = "{0:N1} MB" -f ($Bytes / 1MB) }
    elseif ($Bytes -ge 1KB) { $s = "{0:N0} KB" -f ($Bytes / 1KB) }
    if ($Bracket -and $s) { return "[$s]" }
    return $s
}

function Format-Duration {
    <#
    .SYNOPSIS
        Formats a span of seconds as m:ss, clamped so a nonsense ETA cannot widen the row.
    #>
    param([double]$Seconds)
    if ($Seconds -lt 0) { $Seconds = 0 }
    $t = [int][Math]::Round($Seconds)
    if ($t -ge 6000) { return "99:59+" }
    return "{0}:{1:00}" -f [int]($t / 60), ($t % 60)
}

function Get-ConsolePaint {
    <#
    .SYNOPSIS
        Probes whether this host supports absolute cursor positioning, and returns the
        safe paint width. Enabled = $false means the caller must use the single-line
        `r renderer instead -- i.e. exactly the behaviour that shipped before.
    .DESCRIPTION
        Allowlist, not denylist: only the real console host is known to honour
        RawUI.CursorPosition. The ISE setter throws, VS Code's is a silent no-op that
        would scroll painted rows away, and a redirected stream has no cursor at all.
        Anything unrecognised degrades instead of corrupting the display.

        Width comes from BufferSize (not WindowSize, not $script:ScreenWidth) because
        the buffer is what governs wrapping, and one column is held back so a full-width
        row cannot trip conhost's delayed-wrap flag.
    #>
    $result = @{ Enabled = $false; Width = $script:ScreenWidth - 1 }
    if ("$($Host.Name)" -ne 'ConsoleHost') { return $result }
    try { if ([Console]::IsOutputRedirected) { return $result } } catch { }
    try {
        $rui = $Host.UI.RawUI
        $pos = $rui.CursorPosition
        $rui.CursorPosition = $pos     # the write must round-trip, not just the read
        $w = $rui.BufferSize.Width
        if ($w -lt 40) { return $result }
        $result.Enabled = $true
        $result.Width = $w - 1
    } catch { }
    return $result
}

function Write-BlockLines {
    <#
    .SYNOPSIS
        Repaints an N-line block in place and restores the cursor.
        Returns $false if the host refused, in which case the caller must stop painting.
    .DESCRIPTION
        The block is assumed to occupy the N console rows immediately ABOVE the current
        cursor row. That top row is re-derived from the CURRENT cursor on every call, so
        console scrolling cannot invalidate it -- there is deliberately no saved absolute
        coordinate anywhere.
    .PARAMETER Cache
        Optional array of length N, mutated in place. Rows whose text and colour are
        unchanged since the last call are skipped, which stops completed rows flickering.
    #>
    param(
        [string[]]$Lines,
        [string[]]$Colors,
        [int]$Width,
        [string[]]$Cache = $null
    )
    $n = $Lines.Count
    if ($n -eq 0 -or $Colors.Count -ne $n) { return $false }
    try {
        $rui = $Host.UI.RawUI
        $anchor = $rui.CursorPosition          # struct copy, safe to restore
        $topY = $anchor.Y - $n
        if ($topY -lt 0) { return $false }
        $useCache = ($null -ne $Cache -and $Cache.Count -eq $n)
        for ($r = 0; $r -lt $n; $r++) {
            $txt = $Lines[$r]
            if ($txt.Length -gt $Width) { $txt = $txt.Substring(0, $Width) }
            else { $txt = $txt.PadRight($Width) }
            $sig = $Colors[$r] + '|' + $txt
            if ($useCache -and $Cache[$r] -eq $sig) { continue }
            $pos = $rui.CursorPosition
            $pos.X = 0
            $pos.Y = $topY + $r
            $rui.CursorPosition = $pos
            Write-Host $txt -NoNewline -ForegroundColor $Colors[$r]
            if ($useCache) { $Cache[$r] = $sig }
        }
        $rui.CursorPosition = $anchor
        return $true
    } catch {
        return $false
    }
}

function Write-Wait {
    <#
    .SYNOPSIS
        Shows a spinner while a process or condition is pending.
        Overwrites the same line to avoid scroll spam.
        Optional -Progress scriptblock returns a suffix string (e.g. "[3.2 MB]", "[45%]").
    #>
    param(
        [string]$Message,
        [scriptblock]$Until,
        [int]$TimeoutSeconds = 60,
        [scriptblock]$Progress = $null
    )

    $m = $script:BoxMargin
    $frames = @('|','/','-','\')
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $i = 0
    $pad = $script:ScreenWidth
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $frame = $frames[$i % $frames.Count]
        $suffix = ""
        if ($Progress) { $suffix = " $(& $Progress)" }
        $bar = Get-ProgressBar -Width 20 -Percent -1 -Frame $i
        $line = "$m$frame $Message $bar$suffix"
        Write-Host "`r$($line.PadRight($pad))" -NoNewline -ForegroundColor DarkGray
        if (& $Until) {
            $doneBar = Get-ProgressBar -Width 20 -Percent 100
            $doneLine = "$m$([char]0x2713) $Message $doneBar$suffix"
            Write-Host "`r$($doneLine.PadRight($pad))" -ForegroundColor Green
            return $true
        }
        Start-Sleep -Milliseconds 200
        $i++
    }
    Write-Host "`r$m! $Message (timed out)".PadRight($pad) -ForegroundColor Yellow
    return $false
}

function Write-Completion {
    <#
    .SYNOPSIS
        PATH B completion box -- full DAC/amp/onboard install.
    #>
    param(
        [bool]$SoundControlInstalled = $true,
        [bool]$VoicemeeterInstalled = $true,
        [bool]$VBCableInstalled = $true,
        [bool]$ReaPlugsInstalled = $true,
        [bool]$EapoInstalled = $true,
        [bool]$HeSuViInstalled = $true,
        [bool]$JsfxInstalled = $true,
        [bool]$EndpointsVerified = $true,
        [bool]$ConfigIsPlaceholder = $false
    )
    $w = $script:BoxWidth
    $m = $script:BoxMargin
    $b = [string]::new([char]0x2550, $w)
    $s = [string]::new([char]0x2500, $w - 4)
    $p = { param($t) "$($script:BoxMargin)$([char]0x2551)  $t$(' ' * [Math]::Max(0, $w - $t.Length - 2))$([char]0x2551)" }

    Write-Host ""
    Write-Host "$m$([char]0x2554)$b$([char]0x2557)" -ForegroundColor Green
    Write-Host "$m$([char]0x2551)$(Center-Text "$([char]0x2713)  SETUP COMPLETE" $w)$([char]0x2551)" -ForegroundColor Green
    Write-Host "$m$([char]0x2560)$b$([char]0x2563)" -ForegroundColor Green
    # Per-component marker, following the precedent the LEQ row already set: [!] takes the
    # tick's place inline and the $p pad absorbs the width difference. A row goes Yellow
    # only when something on it needs attention, so an all-good box renders as it did
    # before (no explicit colour, host default).
    $tick = "$([char]0x2713)"
    $mk = { param($ok) if ($ok) { $tick } else { '[!]' } }
    $row = {
        param($text, [bool[]]$flags)
        if ($flags -contains $false) { Write-Host (& $p $text) -ForegroundColor Yellow }
        else { Write-Host (& $p $text) }
    }

    Write-Host (& $p "")
    Write-Host (& $p "Installed:")
    & $row "  $(& $mk $VBCableInstalled) VB-CABLE          $(& $mk $ReaPlugsInstalled) ReaPlugs" @($VBCableInstalled, $ReaPlugsInstalled)
    if ($VoicemeeterInstalled) {
        & $row "  $tick Voicemeeter       $(& $mk $EapoInstalled) E-APO" @($EapoInstalled)
    } else {
        & $row "  $(& $mk $EapoInstalled) E-APO" @($EapoInstalled)
    }
    if ($SoundControlInstalled) {
        & $row "  $(& $mk $HeSuViInstalled) HeSuVi            $tick LEQ Control Panel" @($HeSuViInstalled)
    } else {
        & $row "  $(& $mk $HeSuViInstalled) HeSuVi            [!] LEQ Control Panel" @($false)
        Write-Host (& $p "                         (download from GitHub)") -ForegroundColor Yellow
    }
    & $row "  $(& $mk $JsfxInstalled) JSFX Plugins" @($JsfxInstalled)

    # Action-required states. Printed only when they apply, so a clean run and a future
    # preset-profile path both render without them.
    if (-not $EndpointsVerified) {
        Write-Host (& $p "  [!] Audio endpoint names") -ForegroundColor Yellow
        Write-Host (& $p "      (re-run Setup, or rename in Sound settings)") -ForegroundColor Yellow
    }
    if ($ConfigIsPlaceholder) {
        Write-Host (& $p "  [!] Config not set") -ForegroundColor Yellow
        Write-Host (& $p "      (open config.txt and choose your game and version)") -ForegroundColor Yellow
    }
    Write-Host (& $p "")
    Write-Host (& $p $s) -ForegroundColor DarkGray
    Write-Host (& $p "")
    Write-Host (& $p "Press [s] below to launch LEQ Control Panel")
    Write-Host (& $p "and Device Selector, then follow the video.")
    Write-Host (& $p "")
    if ($VoicemeeterInstalled) {
        Write-Host (& $p "You can remove Voicemeeter later if you")
        Write-Host (& $p "do not need it.")
        Write-Host (& $p "")
    }
    Write-Host (& $p "Press [b] for SonicScout2.0 - automated setup,") -ForegroundColor DarkGray
    Write-Host (& $p "auto-updating, with my own Voicemeeter") -ForegroundColor DarkGray
    Write-Host (& $p "replacement built in.") -ForegroundColor DarkGray
    Write-Host (& $p "")
    Write-Host "$m$([char]0x255A)$b$([char]0x255D)" -ForegroundColor Green
    Write-Host ""

    # Interactive launch options (loops until quit or back)
    while ($true) {
        $menuMargin = Write-CenteredBlock @(
            @{ Text = '[s] Open LEQ Control Panel'; Color = 'White' }
            @{ Text = '[b] SonicScout2.0 - automated, auto-updating, no Voicemeeter'; Color = 'DarkGray' }
            @{ Text = '[m] Back to main menu'; Color = 'DarkGray' }
            @{ Text = '[q] Quit'; Color = 'DarkGray' }
        )
        Write-Host ""

        Write-Host "$menuMargin" -NoNewline
        Write-Host "Choice: " -ForegroundColor Yellow -NoNewline
        $key = Read-Host
        switch ($key.ToLower()) {
            's' {
                $scExe = Join-Path $env:LOCALAPPDATA "Programs\LEQControlPanel\LEQControlPanel.exe"
                if (Test-Path $scExe) {
                    Start-Process $scExe
                    Write-Host "$($script:BoxMargin)Launched LEQ Control Panel." -ForegroundColor Green
                } else {
                    Write-Host "$($script:BoxMargin)LEQ Control Panel not found. Download it from:" -ForegroundColor Yellow
                    Write-Host "$($script:BoxMargin)https://github.com/sensoredrooster/LEQControlPanel/releases" -ForegroundColor Yellow
                }
                Write-Host ""
            }
            'b' {
                Start-Process "https://github.com/sensoredrooster/SonicScout2.0"
                Write-Host "$($script:BoxMargin)Opened in browser." -ForegroundColor Green
                Write-Host ""
            }
            'm' { return 'mainMenu' }
            'q' { return 'quit' }
            default { Write-Host "$($script:BoxMargin)Invalid choice." -ForegroundColor Red; Write-Host "" }
        }
    }
}

function Write-UninstallCompletion {
    <#
    .SYNOPSIS
        PATH C completion box -- uninstall.
    #>
    param(
        [string[]]$RemovedComponents,
        [string[]]$KeptComponents,
        [string[]]$RemovedShortcuts,
        [string[]]$FailedShortcuts
    )

    $w = $script:BoxWidth
    $m = $script:BoxMargin
    $b = [string]::new([char]0x2550, $w)
    $p = { param($t) "$($script:BoxMargin)$([char]0x2551)  $t$(' ' * [Math]::Max(0, $w - $t.Length - 2))$([char]0x2551)" }

    Write-Host ""
    Write-Host "$m$([char]0x2554)$b$([char]0x2557)" -ForegroundColor Green
    Write-Host "$m$([char]0x2551)$(Center-Text "$([char]0x2713)  UNINSTALL COMPLETE" $w)$([char]0x2551)" -ForegroundColor Green
    Write-Host "$m$([char]0x2560)$b$([char]0x2563)" -ForegroundColor Green
    Write-Host (& $p "")
    Write-Host (& $p "Removed:")
    foreach ($comp in $RemovedComponents) {
        Write-Host (& $p "  $([char]0x2713) $comp")
    }
    # The plugin outcome rides $script:PluginRemoval rather than $RemovedComponents.
    # That array also drives the caller's "restart to clear removed drivers" prompt,
    # and a plugin-only removal involves no driver.
    if ($script:PluginRemoval.State -eq 'Removed') {
        Write-Host (& $p "  $([char]0x2713) SonicScout2.0 plugins (VST + JSFX)")
    }
    # Same reasoning as the plugins above: listed here rather than folded into
    # $RemovedComponents, which also drives the caller's "restart to clear removed
    # drivers" prompt -- a deleted .lnk is not a driver and must not ask for one.
    foreach ($sc in $RemovedShortcuts) {
        Write-Host (& $p "  $([char]0x2713) $sc")
    }
    # Anything deliberately left behind is stated, so "uninstall everything" does
    # not imply something was removed when it was not.
    if ($KeptComponents -and $KeptComponents.Count -gt 0) {
        Write-Host (& $p "")
        Write-Host (& $p "Kept (not installed by SonicScout2.0):")
        foreach ($comp in $KeptComponents) {
            Write-Host (& $p "  - $comp")
        }
    }
    # Kept for a different reason than $KeptComponents: those were never ours to
    # remove, these are ours but shared with the app, so they get their own block
    # rather than being folded under "not installed by SonicScout2.0".
    if ($script:PluginRemoval.State -eq 'SkippedSS') {
        Write-Host (& $p "")
        Write-Host (& $p "SonicScout2.0 plugins kept:")
        Write-Host (& $p "  - The SonicScout2.0 app is installed and")
        Write-Host (& $p "    shares them. Uninstall SonicScout2.0")
        Write-Host (& $p "    from the app to remove them.")
    }
    if ($script:PluginRemoval.State -eq 'Failed') {
        Write-Host (& $p "")
        Write-Host (& $p "Could not remove the SonicScout2.0 plugins:") -ForegroundColor Yellow
        foreach ($pluginDir in $script:PluginRemoval.FailedPaths) {
            Write-Host (& $p "  $pluginDir") -ForegroundColor Yellow
        }
        Write-Host (& $p "  Restart, then re-run setup and choose") -ForegroundColor Yellow
        Write-Host (& $p "  [4] to finish removing them.") -ForegroundColor Yellow
    }
    if ($FailedShortcuts -and $FailedShortcuts.Count -gt 0) {
        Write-Host (& $p "")
        Write-Host (& $p "Could not delete these desktop icons:") -ForegroundColor Yellow
        foreach ($sc in $FailedShortcuts) {
            Write-Host (& $p "  $(Split-Path $sc -Leaf)") -ForegroundColor Yellow
        }
        Write-Host (& $p "  Delete them by hand -- they point at") -ForegroundColor Yellow
        Write-Host (& $p "  folders that no longer exist.") -ForegroundColor Yellow
    }
    Write-Host (& $p "")
    Write-Host (& $p "You may also need to set your Windows")
    Write-Host (& $p "default audio device back to your")
    Write-Host (& $p "headphones/DAC.")
    Write-Host (& $p "")
    Write-Host "$m$([char]0x255A)$b$([char]0x255D)" -ForegroundColor Green
    Write-Host ""
}

function Show-ThankYou {
    <#
    .SYNOPSIS
        Displays a credits/thank-you list with links to each developer's page.
    #>
    $w = $script:BoxWidth
    $m = $script:BoxMargin
    $b = [string]::new([char]0x2550, $w)
    $p = { param($t) "$($script:BoxMargin)$([char]0x2551)  $t$(' ' * [Math]::Max(0, $w - $t.Length - 2))$([char]0x2551)" }

    $credits = @(
        @{ Num = '1'; Tool = 'Voicemeeter + VB-CABLE'; Dev = 'Vincent Burel (VB-Audio)'; Url = 'https://shop.vb-audio.com' }
        @{ Num = '2'; Tool = 'ReaPlugs';                  Dev = 'Cockos Inc';               Url = 'https://www.reaper.fm/reaplugs/' }
        @{ Num = '3'; Tool = 'Equalizer APO';             Dev = 'Jonas Thedering';           Url = 'https://sourceforge.net/projects/equalizerapo/' }
        @{ Num = '4'; Tool = 'HeSuVi';                    Dev = 'jak33';                     Url = 'https://sourceforge.net/projects/hesuvi/' }
        @{ Num = '5'; Tool = 'Squig.link';                Dev = 'GadgetryTech';              Url = 'https://www.youtube.com/gadgetrytech' }
        @{ Num = '6'; Tool = 'Install-SonicScout2.0.ps1 + LEQ'; Dev = 'SonicScout2.0';                  Url = 'https://github.com/sensoredrooster/SonicScout2.0' }
    )

    Write-Host ""
    Write-Host "$m$([char]0x2554)$b$([char]0x2557)" -ForegroundColor Yellow
    Write-Host "$m$([char]0x2551)$(Center-Text 'Thank You' $w)$([char]0x2551)" -ForegroundColor Yellow
    Write-Host "$m$([char]0x2560)$b$([char]0x2563)" -ForegroundColor Yellow
    Write-Host (& $p "")
    Write-Host (& $p "This installer depends on tools built by")
    Write-Host (& $p "talented developers. Show them some love:")
    Write-Host (& $p "")
    foreach ($c in $credits) {
        $line = "[$($c.Num)] $($c.Tool) - $($c.Dev)"
        if ($c.Num -eq '6') {
            Write-Host (& $p $line) -ForegroundColor DarkGray
        } else {
            Write-Host (& $p $line)
        }
    }
    Write-Host (& $p "")
    Write-Host "$m$([char]0x255A)$b$([char]0x255D)" -ForegroundColor Yellow
    Write-Host ""

    while ($true) {
        $menuMargin = Write-CenteredBlock @(
            @{ Text = '[1-6] Open developer page'; Color = 'White' }
            @{ Text = '[m] Back to main menu'; Color = 'DarkGray' }
            @{ Text = '[q] Quit'; Color = 'DarkGray' }
        )
        Write-Host ""
        Write-Host "$menuMargin" -NoNewline
        Write-Host "Choice: " -ForegroundColor Yellow -NoNewline
        $key = Read-Host
        $num = 0
        if ([int]::TryParse($key, [ref]$num) -and $num -ge 1 -and $num -le 6) {
            $selected = $credits[$num - 1]
            Start-Process $selected.Url
            Write-Host "$($script:BoxMargin)Opened $($selected.Dev) in browser." -ForegroundColor Green
            Write-Host ""
        }
        elseif ($key -eq 'm' -or $key -eq 'M') { return 'mainMenu' }
        elseif ($key -eq 'q' -or $key -eq 'Q') { return 'quit' }
        else {
            Write-Host "$($script:BoxMargin)Invalid choice." -ForegroundColor Red
            Write-Host ""
        }
    }
}

# ============================================================================
# SECTION 2: Utility Functions
# ============================================================================

# ---- Culture-invariant identity matching -----------------------------------
# PowerShell's -match, -notmatch, -like and -notlike fold case using the CURRENT
# CULTURE. Turkish and Azeri lowercase 'I' to the dotless 'i', so on those locales:
#
#     'VB-AUDIO HI-FI CABLE' -like '*Hi-Fi*'   ->  False
#     'VB:ASIO BRIDGE'       -match 'ASIO Bridge' -> False
#
# Every identity token this script matches on -- Hi-Fi, HiFi, hfvaio, VB-Audio,
# Wave Link, Elgato Virtual, Voicemeeter, ASIO Bridge -- contains an i, and the
# real values arrive uppercased from CIM/registry/pnputil. So on a tr-TR box the
# raw operators silently stop matching.
#
# The worst consequence is not a missed detection. Uninstall-ExistingHiFiCable
# detects via literal registry paths (Test-Path, unaffected) but VERIFIES with the
# device-name match -- so it would clean the registry, no-op every driver-store arm,
# find nothing in the verify pass and report 'Removed' for a driver still installed.
# That is a false verified-removed, the same defect SonicScout2.0 hit in the field.
#
# Use these two for identity tokens. String -eq/-ne need NO conversion: PowerShell
# compares strings ordinally, so 'I' -eq 'i' is True even under tr-TR (which is why
# Get-SonicScout20Endpoints' -ne 'VB-Audio Virtual Cable' was never exposed).
$script:OrdinalRegexOptions = [System.Text.RegularExpressions.RegexOptions]'IgnoreCase,CultureInvariant'

function Test-OrdinalMatch {
    <#
    .SYNOPSIS
        Culture-invariant, case-insensitive regex test. The -match replacement.
    #>
    param([string]$Text, [string]$Pattern)
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    return [regex]::IsMatch($Text, $Pattern, $script:OrdinalRegexOptions)
}

function Test-OrdinalContains {
    <#
    .SYNOPSIS
        Culture-invariant, case-insensitive substring test. The -like "*x*" replacement.
        Uses IndexOf because String.Contains(string, StringComparison) does not exist
        on the .NET Framework build of PowerShell 5.1 that this script runs under.
    #>
    param([string]$Text, [string]$Needle)
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    return ($Text.IndexOf($Needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function Get-OrdinalMatchGroup {
    <#
    .SYNOPSIS
        Culture-invariant capture-group read. The "$x -match p; $Matches[1]" replacement.
        Returns '' when the pattern does not match.
    #>
    param([string]$Text, [string]$Pattern, [int]$Group = 1)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $m = [regex]::Match($Text, $Pattern, $script:OrdinalRegexOptions)
    if (-not $m.Success) { return '' }
    return $m.Groups[$Group].Value
}

function Send-SetupPing {
    <#
    .SYNOPSIS
        Fire-and-forget anonymous setup counter. Called on SUCCESSFUL setup
        completion only. Silent on any failure; never blocks completion beyond a
        short timeout. Sends a mode flag and a SHA-256 hash of the machine GUID
        (never the raw GUID).
    #>
    param([Parameter(Mandatory)][string]$Mode)

    Write-Host ""
    Write-Host "$($script:BoxMargin)Reporting anonymous setup count..." -ForegroundColor DarkGray -NoNewline
    try {
        $raw = ''
        try { $raw = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop).MachineGuid } catch { $raw = '' }
        $machineId = ''
        if ($raw) {
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try {
                $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes([string]$raw))
                $machineId = -join ($hash | ForEach-Object { $_.ToString('x2') })
            } finally { $sha.Dispose() }
        }
        $body = @{ mode = $Mode; machineId = $machineId } | ConvertTo-Json -Compress
        Invoke-RestMethod -Uri $script:SetupPingUrl -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 3 -ErrorAction Stop | Out-Null
        Write-Host " done." -ForegroundColor DarkGray
    } catch {
        # Silent: the counter must never affect setup success.
        Write-Host " skipped." -ForegroundColor DarkGray
    }
}

function Test-AdminPrivilege {
    <#
    .SYNOPSIS
        Verifies the script is running with administrator privileges.
    #>
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host ""
        Write-Host "$($script:BoxMargin)ERROR: This script must be run as Administrator." -ForegroundColor Red
        Write-Host ""
        Write-Host "$($script:BoxMargin)Right-click PowerShell and select 'Run as administrator'," -ForegroundColor White
        Write-Host "$($script:BoxMargin)then run this script again." -ForegroundColor White
        Write-Host ""
        exit 1
    }
}

function Test-SystemCompatibility {
    <#
    .SYNOPSIS
        Checks for ARM64 architecture and Windows S Mode.
    #>
    # ARM64 check
    try {
        $arch = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture
        if ($arch -eq [System.Runtime.InteropServices.Architecture]::Arm64) {
            Write-Host ""
            Write-Host "$($script:BoxMargin)ERROR: ARM64 devices are not supported." -ForegroundColor Red
            Write-Host "$($script:BoxMargin)The audio stack requires an x64 processor." -ForegroundColor White
            Write-Host ""
            exit 1
        }
    } catch {
        # RuntimeInformation not available on very old PS -- skip
    }

    # S Mode check
    try {
        $ciPolicy = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy" -ErrorAction SilentlyContinue
        if ($ciPolicy -and $ciPolicy.SkuPolicyRequired -eq 1) {
            Write-Host ""
            Write-Host "$($script:BoxMargin)ERROR: Windows is in S Mode." -ForegroundColor Red
            Write-Host "$($script:BoxMargin)S Mode blocks third-party software installation." -ForegroundColor White
            Write-Host "$($script:BoxMargin)Switch out of S Mode in Settings > Update & Security > Activation." -ForegroundColor White
            Write-Host ""
            exit 1
        }
    } catch {
        # Registry key may not exist -- not S Mode
    }
}

function Test-PowerShellEdition {
    <#
    .SYNOPSIS
        Refuses to run under PowerShell Core.
    .DESCRIPTION
        Setup depends on Start-BitsTransfer (SourceForge downloads), Get-AppxPackage
        (Wave Link 3 detection) and Get-PnpDevice, none of which load natively in
        PowerShell 7. Without this guard the failures are partial and silent: the
        Get-AppxPackage failure in particular is swallowed, Wave Link goes undetected,
        and the user is offered a Voicemeeter they do not want.

        No #Requires at the top of the file: this script is delivered via
        'irm ... | iex', where a #Requires failure is opaque.
    #>
    # PSEdition is absent before 5.1; ContainsKey keeps that read StrictMode-safe.
    $edition = 'Desktop'
    if ($PSVersionTable.ContainsKey('PSEdition')) { $edition = "$($PSVersionTable.PSEdition)" }

    if ($edition -ne 'Desktop') {
        Write-Host ""
        Write-Host "$($script:BoxMargin)ERROR: This installer requires Windows PowerShell 5.1." -ForegroundColor Red
        Write-Host "$($script:BoxMargin)You are running PowerShell $($PSVersionTable.PSVersion) ($edition), which" -ForegroundColor White
        Write-Host "$($script:BoxMargin)cannot load the BITS, AppX and PnP components setup needs." -ForegroundColor White
        Write-Host "$($script:BoxMargin)Open 'Windows PowerShell' as Administrator and run it again." -ForegroundColor White
        Write-Host ""
        exit 1
    }
}

function Initialize-NativeMethods {
    <#
    .SYNOPSIS
        Loads P/Invoke signatures for window management.
    #>
    if (-not ([System.Management.Automation.PSTypeName]'NativeMethods').Type) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class NativeMethods {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
}
'@
    }
}

function Set-WindowForeground {
    <#
    .SYNOPSIS
        Brings a process's main window to the foreground.
    #>
    param([System.Diagnostics.Process]$Process)
    try {
        Initialize-NativeMethods
        # Wait for window handle to appear
        for ($i = 0; $i -lt 20; $i++) {
            $Process.Refresh()
            if ($Process.MainWindowHandle -ne [IntPtr]::Zero) {
                [NativeMethods]::ShowWindow($Process.MainWindowHandle, 5) | Out-Null  # SW_SHOW
                [NativeMethods]::SetForegroundWindow($Process.MainWindowHandle) | Out-Null
                return
            }
            Start-Sleep -Milliseconds 250
        }
    } catch { } # Window focus is best-effort; failure is non-fatal
}

function Stop-AudioHoldingProcesses {
    <#
    .SYNOPSIS
        Stops Voicemeeter processes so the uninstaller can run cleanly.
    #>
    $vmNames = @('voicemeeter','voicemeeter_x64','voicemeeterpro','voicemeeterpro_x64',
                 'voicemeeter8','voicemeeter8x64','audiorepeater','audiorepeater_x64')

    $procs = @(Get-Process -Name $vmNames -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { return }

    Write-Host "$($script:BoxMargin)Stopping Voicemeeter ($($procs.Count) process(es))..." -ForegroundColor DarkGray
    $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    $null = Write-Wait -Message "Waiting for Voicemeeter to exit" -Until {
        @(Get-Process -Name $vmNames -ErrorAction SilentlyContinue).Count -eq 0
    } -TimeoutSeconds 10
    Start-Sleep -Milliseconds 500
}

function Stop-EAPOEcosystemProcesses {
    <#
    .SYNOPSIS
        Stops Peace, HeSuVi, and E-APO GUI tools so their file locks
        on E-APO DLLs are released before uninstall / folder deletion.
    #>
    $eapoPath = Join-Path $env:ProgramFiles "EqualizerAPO"

    # Processes with unique names -- safe to kill by name alone
    $safeNames = @('Peace', 'HeSuVi', 'Configurator', 'DeviceSelector')

    $killed = @()

    foreach ($name in $safeNames) {
        $procs = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
        if ($procs.Count -gt 0) {
            $procs | Stop-Process -Force -ErrorAction SilentlyContinue
            $killed += $name
        }
    }

    # Editor.exe is too generic to kill by name -- filter by E-APO path
    $editorProcs = @(Get-Process -Name 'Editor' -ErrorAction SilentlyContinue |
        Where-Object {
            try { $_.Path -and $_.Path.StartsWith($eapoPath, [System.StringComparison]::OrdinalIgnoreCase) }
            catch { $false }
        })
    if ($editorProcs.Count -gt 0) {
        $editorProcs | Stop-Process -Force -ErrorAction SilentlyContinue
        $killed += 'Editor'
    }

    if ($killed.Count -eq 0) { return }

    Write-Host "$($script:BoxMargin)Stopped E-APO ecosystem processes: $($killed -join ', ')" -ForegroundColor DarkGray

    $null = Write-Wait -Message "Waiting for E-APO ecosystem processes to exit" -Until {
        $remaining = @(Get-Process -Name $safeNames -ErrorAction SilentlyContinue).Count
        $remaining += @(Get-Process -Name 'Editor' -ErrorAction SilentlyContinue |
            Where-Object {
                try { $_.Path -and $_.Path.StartsWith($eapoPath, [System.StringComparison]::OrdinalIgnoreCase) }
                catch { $false }
            }).Count
        $remaining -eq 0
    } -TimeoutSeconds 10

    Start-Sleep -Milliseconds 500
}

# ============================================================================
# SECTION 3: Download Functions
# ============================================================================

$script:BitsOriginalStartType = $null
$script:BitsWasRunning        = $true

function Ensure-BitsRunning {
    $svc = Get-Service -Name 'BITS' -ErrorAction Stop
    $script:BitsOriginalStartType = $svc.StartType
    $script:BitsWasRunning = ($svc.Status -eq 'Running')

    if ($script:BitsWasRunning) { return }

    if ($svc.StartType -eq 'Disabled') {
        Set-Service -Name 'BITS' -StartupType Manual -ErrorAction Stop
    }
    Start-Service -Name 'BITS' -ErrorAction Stop
}

function Restore-BitsState {
    if ($null -eq $script:BitsOriginalStartType) { return }
    if ($script:BitsWasRunning) { return }
    try {
        Stop-Service -Name 'BITS' -Force -ErrorAction SilentlyContinue
        if ($script:BitsOriginalStartType -eq 'Disabled') {
            Set-Service -Name 'BITS' -StartupType Disabled -ErrorAction SilentlyContinue
        }
    } catch { }
}

$script:SourceForgeMirrors = @(
    "",                          # Default (let SourceForge pick)
    "?use_mirror=autoselect",    # Force autoselect
    "?use_mirror=netcologne",    # Germany
    "?use_mirror=deac-riga",     # Latvia
    "?use_mirror=kent",          # UK
    "?use_mirror=cfhcable"       # US
)

# NOT WIRED UP, deliberately. E-APO is pinned to the CDN copy of 1.4.2 (see its spec in
# Get-Downloads), which is the build SonicScout2.0 bundles and the library configs were
# validated against. This resolver is kept, not deleted, because it is the whole of the
# "go back to whatever SourceForge calls latest" path: set the EAPO spec's UrlResolver
# to this and drop its Url, and the old behaviour returns. Do not delete it as dead code.
$script:EapoUrlResolver = {
    $fallback = "https://sourceforge.net/projects/equalizerapo/files/1.4/EqualizerAPO64-1.4.exe/download"
    $ProgressPreference = 'SilentlyContinue'
    try {
        $rssUrl = "https://sourceforge.net/projects/equalizerapo/rss?path=/"
        $xml = [xml](Invoke-WebRequest -Uri $rssUrl -UseBasicParsing -ErrorAction Stop).Content
        $candidates = @()
        foreach ($item in $xml.rss.channel.Item) {
            $link = $item.link
            if ($link -match 'EqualizerAPO(?:64|-x64)-([\d.]+)\.exe/download$') {
                $verStr = $Matches[1]
                try {
                    $ver = [version]$verStr
                    $candidates += [PSCustomObject]@{ Version = $ver; Url = $link }
                } catch { }
            }
        }
        if ($candidates.Count -gt 0) {
            $best = $candidates | Sort-Object Version -Descending | Select-Object -First 1
            return $best.Url
        }
    } catch { }
    return $fallback
}

$script:VoicemeeterUrlResolver = {
    $fallback = "https://download.vb-audio.com/Download_CABLE/VoicemeeterSetup_v1122.zip"
    $ProgressPreference = 'SilentlyContinue'
    try {
        $page = (Invoke-WebRequest -Uri "https://vb-audio.com/Voicemeeter/index.htm" -UseBasicParsing -ErrorAction Stop).Content
        $m = [regex]::Match($page, 'download\.vb-audio\.com/Download_CABLE/VoicemeeterSetup[^"'']*\.zip', 'IgnoreCase')
        if ($m.Success) { return "https://$($m.Value)" }
    } catch { }
    return $fallback
}

$script:LeqUrlResolver = {
    $ProgressPreference = 'SilentlyContinue'
    try {
        $headers = @{ 'Accept' = 'application/vnd.github+json' }
        $release = Invoke-RestMethod 'https://api.github.com/repos/sensoredrooster/LEQControlPanel/releases/latest' -Headers $headers -ErrorAction Stop
        $asset = $release.assets | Where-Object { $_.name -eq 'LEQControlPanel.exe' } | Select-Object -First 1
        if ($asset) { return $asset.browser_download_url }
    } catch { }
    return $null  # triggers FallbackUrl path
}

function Build-LocalLeqControlPanel {
    <#
    .SYNOPSIS
        Builds LEQ Control Panel from the vendored source at tools/LEQControlPanel
        (SonicScout2.0 repo checkout or release bundle). Returns the published
        single-file exe path, or $null when the source or dotnet SDK is absent.
    .DESCRIPTION
        The vendored source is authoritative: it carries the SonicScout device-name
        fixes that older LEQ Control Panel releases predate. Publish config
        comes from the csproj (PublishSingleFile + SelfContained win-x64).
    #>
    $repoRoot = $null
    # irm | iex has no script file, and StrictMode throws if .Path is read on that
    # command object. A missing path just means "no vendored source", not a failed install.
    if ($PSScriptRoot) {
        $packaged = Join-Path $PSScriptRoot 'companion\LEQControlPanel.exe'
        if (Test-Path -LiteralPath $packaged) { return $packaged }
    }
    $cmdPath = $null
    if ($MyInvocation.MyCommand.PSObject.Properties['Path']) {
        $cmdPath = $MyInvocation.MyCommand.Path
    }
    if ($cmdPath) {
        $repoRoot = Split-Path (Split-Path $cmdPath -Parent) -Parent
    }
    if (-not $repoRoot) { return $null }
    $proj = Join-Path $repoRoot "tools\LEQControlPanel\src\LEQControlPanel\LEQControlPanel.csproj"
    if (-not (Test-Path -LiteralPath $proj)) { return $null }
    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if (-not $dotnet) {
        Write-Host "$($script:BoxMargin)LEQ source present but .NET SDK not found; using download instead." -ForegroundColor DarkGray
        return $null
    }
    Write-Host "$($script:BoxMargin)Building LEQ Control Panel from local source..." -ForegroundColor Cyan
    $outDir = Join-Path $script:TempPath "LEQ-publish"
    try {
        & dotnet publish $proj -c Release -r win-x64 --self-contained -o $outDir --nologo 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { return $null }
        $exe = Join-Path $outDir 'LEQControlPanel.exe'
        if (Test-Path -LiteralPath $exe) { return $exe }
    } catch { }
    return $null
}

function Test-BinaryHeader {
    <#
    .SYNOPSIS
        Returns $true if the file starts with MZ (PE executable) or 7z (7-Zip SFX).
        Used to validate SourceForge downloads returned a real binary, not an HTML page.
    #>
    param([string]$FilePath)
    if (-not (Test-Path $FilePath)) { return $false }
    $header = New-Object byte[] 2
    $fs = [System.IO.File]::OpenRead($FilePath)
    try { $fs.Read($header, 0, 2) | Out-Null } finally { $fs.Close() }
    $str = [System.Text.Encoding]::ASCII.GetString($header)
    return ($str -eq 'MZ' -or $str -eq '7z')
}

function Start-ParallelDownloads {
    <#
    .SYNOPSIS
        Downloads multiple files concurrently using a runspace pool (for direct
        HTTP downloads) and main-thread BITS transfers (for SourceForge).
    .PARAMETER Specs
        Array of hashtables, each with:
          Key          - Identifier for the result (e.g. 'HiFiCable')
          DisplayName  - Friendly name for console output
          OutFile      - Destination file path
          Method       - 'IWR' (Invoke-WebRequest via runspace) or 'BITS' (BITS transfer)
          Url          - Download URL (for IWR) or $null if UrlResolver is set
          BaseUrl      - Base SourceForge URL before mirror suffix (for BITS)
          UrlResolver  - Scriptblock that returns a URL (runs in a runspace), or $null
    #>
    param(
        [hashtable[]]$Specs,
        [int]$TotalCount = 0,
        [string[]]$NonFatalKeys = @()
    )

    if ($Specs.Count -eq 0) { return @{} }

    # -- Runspace pool (for IWR downloads and URL resolution) ------------------
    $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, 6)
    $pool.Open()

    $iwrScript = {
        param($url, $outFile, $prog, $key)
        $ProgressPreference    = 'SilentlyContinue'
        $ErrorActionPreference = 'Stop'
        # Best-effort HEAD purely so the progress row can show a percentage and an ETA.
        # Never fatal: without a total the row falls back to bytes-and-rate, which is
        # still far better than the bouncing bar this replaced. Measured 48-420ms
        # against every source we fetch over IWR.
        try {
            $h = Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -TimeoutSec 8
            if ($h.Headers.ContainsKey('Content-Length')) {
                $len = [int64]($h.Headers['Content-Length'] | Select-Object -First 1)
                if ($len -gt 0) { $prog["$key.total"] = $len }
            }
        } catch { }
        # Hand the timeout clock back to the poller: the HEAD above must not be charged
        # against the spec's TimeoutSec, which is a budget for the transfer.
        $prog["$key.dlstart"] = [datetime]::UtcNow
        Invoke-WebRequest -Uri $url -OutFile $outFile -UseBasicParsing -UserAgent 'Mozilla/5.0'
    }

    # Tracking structures
    $urlJobs  = @{}   # Key -> @{ PS; Handle; Spec }
    $iwrJobs  = @{}   # Key -> @{ PS; Handle }
    $bitsJobs = @{}   # Key -> BITS job object
    $state    = @{}   # Key -> 'resolving' | 'downloading' | 'done' | 'error'
    $errors   = @{}   # Key -> error message
    $sizes    = @{}   # Key -> formatted final file size string (e.g. "[3.2 MB]")
    $started  = @{}   # Key -> [datetime] when download started (for timeout)
    $bitsMirrorIdx = @{}  # Key -> int (current mirror index for retry)
    $fbTried  = @{}   # Key -> $true once FallbackUrl has been started (one shot)
    $results  = @{}   # Key -> OutFile or $null

    # -- Live progress tracking ------------------------------------------------
    # $prog crosses the runspace boundary, so it is synchronized and uses FLAT composite
    # keys that are ALL pre-seeded below: a hashtable that never grows cannot rehash
    # under the reader, and StrictMode can never trip over a missing key. Only the
    # runspace writes it ("<key>.total" from the HEAD, "<key>.dlstart"); bytes-received
    # is read from the partial file on this thread instead.
    $prog      = [hashtable]::Synchronized(@{})
    $bytesPeak = @{}   # Key -> [int64]    high-water byte mark (stall detection)
    $moveAt    = @{}   # Key -> [datetime] when the byte count last increased
    $rate      = @{}   # Key -> [double]   smoothed bytes/sec
    $rateAt    = @{}   # Key -> [datetime] last rate sample
    $rateBytes = @{}   # Key -> [int64]    byte count at the last rate sample
    foreach ($sp in $Specs) {
        $prog["$($sp.Key).total"]   = [int64]0
        $prog["$($sp.Key).dlstart"] = [int64]0
        $bytesPeak[$sp.Key] = [int64]0
        $moveAt[$sp.Key]    = [datetime]::UtcNow
        $rate[$sp.Key]      = [double]0
        $rateAt[$sp.Key]    = [datetime]::UtcNow
        $rateBytes[$sp.Key] = [int64]0
    }

    # -- Helper: zero a key's progress counters --------------------------------
    # Every restart path (mirror rotation, FallbackUrl) reuses the SAME key, so without
    # this the bar would run backwards or sit on a stale byte count from the dead attempt.
    $resetProg = {
        param($key)
        $prog["$key.total"]   = [int64]0
        $prog["$key.dlstart"] = [int64]0
        $bytesPeak[$key] = [int64]0
        $moveAt[$key]    = [datetime]::UtcNow
        $rate[$key]      = [double]0
        $rateAt[$key]    = [datetime]::UtcNow
        $rateBytes[$key] = [int64]0
    }

    # -- Helper: start an IWR download in a runspace ---------------------------
    $startIwr = {
        param($key, $url, $outFile)
        & $resetProg $key
        $ps = [PowerShell]::Create()
        $ps.RunspacePool = $pool
        $null = $ps.AddScript($iwrScript).AddArgument($url).AddArgument($outFile).AddArgument($prog).AddArgument($key)
        $iwrJobs[$key] = @{ PS = $ps; Handle = $ps.BeginInvoke() }
        $state[$key]   = 'downloading'
        $started[$key] = [datetime]::UtcNow
    }

    # -- Helper: start a BITS download -----------------------------------------
    $startBits = {
        param($key, $baseUrl, $outFile, $mirrorIdx)
        & $resetProg $key
        $mirror = $script:SourceForgeMirrors[$mirrorIdx]
        $url = $baseUrl + $mirror
        Remove-Item $outFile -Force -ErrorAction SilentlyContinue
        $bitsJobs[$key] = Start-BitsTransfer -Source $url -Destination $outFile -Asynchronous -ErrorAction Stop
        $bitsMirrorIdx[$key] = $mirrorIdx
        $state[$key]   = 'downloading'
        $started[$key] = [datetime]::UtcNow
    }

    # -- Phase A: Fire URL-resolution runspaces --------------------------------
    foreach ($spec in $Specs) {
        if ($spec.UrlResolver) {
            $ps = [PowerShell]::Create()
            $ps.RunspacePool = $pool
            $null = $ps.AddScript($spec.UrlResolver)
            $urlJobs[$spec.Key] = @{ PS = $ps; Handle = $ps.BeginInvoke(); Spec = $spec }
            $state[$spec.Key] = 'resolving'
            $started[$spec.Key] = [datetime]::UtcNow
        }
    }

    # -- Phase B: Fire all downloads with known URLs ---------------------------
    foreach ($spec in $Specs) {
        if ($spec.UrlResolver) { continue }  # started above, will download after resolve
        if ($spec.Method -eq 'BITS') {
            try {
                & $startBits $spec.Key $spec.BaseUrl $spec.OutFile 0
            } catch {
                # BITS failed to start -- fall back to IWR
                $fbUrl = if ($spec.FallbackUrl) { $spec.FallbackUrl }
                         elseif ($spec.BaseUrl) { $spec.BaseUrl }
                         else { $spec.Url }
                try { & $startIwr $spec.Key $fbUrl $spec.OutFile }
                catch { $state[$spec.Key] = 'error'; $errors[$spec.Key] = "BITS and IWR both failed: $_" }
            }
        } else {
            & $startIwr $spec.Key $spec.Url $spec.OutFile
        }
    }

    # -- Phase C: Polling loop with live per-file progress --------------------
    $fi = 0
    $m = $script:BoxMargin
    $pad = $script:ScreenWidth
    $total = if ($TotalCount -gt 0) { $TotalCount } else { $Specs.Count }
    $skipped = $total - $Specs.Count
    $blockStart = [datetime]::UtcNow

    # $paint has to exist before the try so the finally can read it under StrictMode.
    $cp = Get-ConsolePaint
    $paint = @{
        On    = $cp.Enabled
        W     = $cp.Width
        LastW = $cp.Width
        Rows  = ($Specs.Count + 1)
        Cache = (New-Object -TypeName 'string[]' -ArgumentList ($Specs.Count + 1))
    }

    # A row is 2 + glyph + 18-char name + 26-char bar + 2 + up to 40 of detail. On a
    # window too narrow for that, give up indent rather than let a row wrap -- wrapping
    # turns one row into two and destroys the block arithmetic Write-BlockLines relies on.
    $rowNeed = 90
    $ind = $script:BoxMargin
    if (($cp.Width - $ind.Length) -lt $rowNeed) {
        $room = $cp.Width - $rowNeed
        if ($room -lt 0) { $room = 0 }
        $ind = ' ' * $room
    }

    # -- The live block --------------------------------------------------------
    # One header row plus one row per spec, FIXED for the whole run: finished items
    # become a static row in place, so the block never changes height and the cursor
    # arithmetic stays valid. Invoked with &, so only hashtable mutations propagate --
    # $paint.On = $false works, a plain scalar assignment would not.
    $render = {
        param([bool]$Final)

        $lines  = New-Object -TypeName 'string[]' -ArgumentList $paint.Rows
        $colors = New-Object -TypeName 'string[]' -ArgumentList $paint.Rows
        $nowU   = [datetime]::UtcNow

        $doneCount = @($state.Values | Where-Object { $_ -eq 'done' -or $_ -eq 'error' }).Count + $skipped
        $hdrPct = 0
        if ($total -gt 0) { $hdrPct = [int](100 * $doneCount / $total) }
        $lines[0] = "$ind  Downloading $doneCount/$total " + (Get-ProgressBar -Width 24 -Percent $hdrPct) +
                    "  " + (Format-Duration ($nowU - $blockStart).TotalSeconds)
        $colors[0] = if ($Final) { 'Green' } else { 'DarkGray' }

        $ri = 1
        foreach ($sp in $Specs) {
            $k = $sp.Key
            $st = 'queued'
            if ($state.ContainsKey($k)) { $st = $state[$k] }

            # -- Bytes so far, and a total if one is known --------------------
            $got = [int64]0
            $tot = [int64]0
            if ($bitsJobs.ContainsKey($k)) {
                # Live COM-backed properties; no Get-BitsTransfer refetch needed. Both are
                # UInt64, so cast before any arithmetic or a subtraction underflows to ~1.8e19.
                # BytesTotal reads BG_SIZE_UNKNOWN (UInt64::MaxValue) until BITS has the
                # response headers -- using that as a denominator pins the bar at 0% forever.
                try {
                    $bjr = $bitsJobs[$k]
                    $got = [int64]$bjr.BytesTransferred
                    $bt  = $bjr.BytesTotal
                    if ($bt -gt 0 -and $bt -ne [uint64]::MaxValue) { $tot = [int64]$bt }
                } catch { }
            } elseif ($st -eq 'downloading') {
                # IWR streams to disk, so the partial file's length IS the byte count.
                # BITS is excluded above because it writes to a .BITxxxx.tmp sidecar and
                # only renames on Complete-BitsTransfer.
                $partial = Get-Item $sp.OutFile -ErrorAction SilentlyContinue
                if ($partial) { $got = [int64]$partial.Length }
                $pt = $prog["$k.total"]
                if ($pt -gt 0) { $tot = [int64]$pt }
            }

            if ($got -gt $bytesPeak[$k]) {
                $bytesPeak[$k] = $got
                $moveAt[$k]    = $nowU
            }
            # Sample the rate about once a second and smooth it, so the readout does not
            # jitter between frames.
            $dt = ($nowU - $rateAt[$k]).TotalSeconds
            if ($dt -ge 1.0) {
                $inst = ($got - $rateBytes[$k]) / $dt
                if ($inst -lt 0) { $inst = 0 }
                if ($rate[$k] -le 0) { $rate[$k] = $inst }
                else { $rate[$k] = (0.6 * $rate[$k]) + (0.4 * $inst) }
                $rateAt[$k]    = $nowU
                $rateBytes[$k] = $got
            }

            # -- Row ------------------------------------------------------------
            $glyph  = ' '
            $color  = 'DarkGray'
            $bar    = ' ' * 26
            $detail = ''
            if ($st -eq 'done') {
                $glyph  = [char]0x2713
                $color  = 'Green'
                $bar    = Get-ProgressBar -Width 24 -Percent 100
                # $sizes carries the tally's bracketed form; the row already has a
                # bracketed bar beside it, so drop them here.
                if ($sizes.ContainsKey($k)) { $detail = "$($sizes[$k])".Trim('[', ']') }
            } elseif ($st -eq 'error') {
                # No bar on a failed row -- the message takes that column, so it reads
                # like the plain tally instead of trailing 26 blank spaces.
                $glyph = '!'
                $bar   = ''
                if ($NonFatalKeys -contains $k) {
                    $color  = 'Yellow'
                    $detail = 'FAILED (non-fatal, will prompt later)'
                } else {
                    $color  = 'Red'
                    $detail = 'FAILED'
                }
            } elseif ($st -eq 'resolving') {
                $bar    = Get-ProgressBar -Width 24 -Percent -1 -Frame ($fi * 2)
                $detail = 'finding latest version...'
                $el = ($nowU - $started[$k]).TotalSeconds
                if ($el -ge 5) { $detail += "  {0:N0}s" -f $el }
            } elseif ($got -le 0) {
                $bar    = Get-ProgressBar -Width 24 -Percent -1 -Frame ($fi * 2)
                $detail = 'connecting...'
            } elseif ($tot -gt 0) {
                # Hold at 99 until the state actually flips, so a row never reads 100%
                # while it is still spinning.
                $pct = [int](100 * $got / $tot)
                if ($pct -gt 99) { $pct = 99 }
                if ($pct -lt 0) { $pct = 0 }
                $bar    = Get-ProgressBar -Width 24 -Percent $pct
                # Pad the whole "x/y MB" run rather than its parts, so a 3-digit total
                # does not open a gap before the unit.
                $detail = "{0,-15} {1,3}%" -f ("{0:N1}/{1:N1} MB" -f ($got / 1MB), ($tot / 1MB)), $pct
                if ($rate[$k] -gt 0) {
                    $detail += "  {0,5:N1} MB/s" -f ($rate[$k] / 1MB)
                    $detail += "  " + (Format-Duration (($tot - $got) / $rate[$k]))
                }
            } else {
                # No Content-Length (HEAD failed, or a chunked response). Bytes and rate
                # still prove it is moving, which is the whole point. Same column widths
                # as above so rows stay aligned with their neighbours.
                $bar    = Get-ProgressBar -Width 24 -Percent -1 -Frame ($fi * 2)
                $detail = "{0,-15}    " -f ("{0:N1} MB" -f ($got / 1MB))
                if ($rate[$k] -gt 0) { $detail += "  {0,5:N1} MB/s" -f ($rate[$k] / 1MB) }
            }

            $lines[$ri]  = "$ind  $glyph $($sp.DisplayName.PadRight(18))$bar  $detail"
            $colors[$ri] = $color
            $ri++
        }

        # A resize reflows rows that are already on screen, so the saved geometry is
        # stale: re-reserve a fresh block instead of painting into the wrong rows.
        $wNow = $paint.W
        try { $wNow = $Host.UI.RawUI.BufferSize.Width - 1 } catch { }
        if ($wNow -ne $paint.LastW -and $wNow -gt 0) {
            $paint.W = $wNow
            $paint.LastW = $wNow
            for ($i = 0; $i -lt $paint.Rows; $i++) { $paint.Cache[$i] = $null }
            for ($i = 0; $i -lt $paint.Rows; $i++) { Write-Host "" }
        }
        if (-not (Write-BlockLines -Lines $lines -Colors $colors -Width $paint.W -Cache $paint.Cache)) {
            $paint.On = $false
        }
    }

    if ($paint.On) {
        # Reserve the rows the block will own. Every frame re-derives its top row
        # RELATIVE to the cursor, so scrolling can never invalidate this.
        for ($i = 0; $i -lt $paint.Rows; $i++) { Write-Host "" }
    } else {
        # Print what we're about to download
        $nameList = ($Specs | ForEach-Object { $_.DisplayName }) -join ', '
        Write-Host "$m  Downloading: $nameList" -ForegroundColor DarkGray
    }

    try {

    # NOTHING inside this loop may write to the console except $render. Any stray output
    # scrolls the reserved rows out from under the cursor arithmetic, and the next frame
    # then repaints over live text. Keep new diagnostics out of here.
    while (@($state.Values | Where-Object { $_ -ne 'done' -and $_ -ne 'error' }).Count -gt 0) {

        # -- Check URL-resolution completions ----------------------------------
        foreach ($key in @($urlJobs.Keys)) {
            $uj = $urlJobs[$key]
            if ($uj.Handle.IsCompleted) {
                $resolvedUrl = $null
                try {
                    $out = $uj.PS.EndInvoke($uj.Handle)
                    if ($out -and $out.Count -gt 0) { $resolvedUrl = $out[$out.Count - 1] }
                } catch { }
                $uj.PS.Dispose()
                $spec = $uj.Spec
                $urlJobs.Remove($key)

                if (-not $resolvedUrl) {
                    if ($spec.FallbackUrl) {
                        # Resolver returned nothing -- use FallbackUrl via IWR
                        try { & $startIwr $key $spec.FallbackUrl $spec.OutFile }
                        catch { $state[$key] = 'error'; $errors[$key] = "URL resolution and fallback both failed: $_" }
                    } else {
                        $state[$key] = 'error'
                        $errors[$key] = 'URL resolution failed'
                    }
                    continue
                }

                # Start the actual download
                if ($spec.Method -eq 'BITS') {
                    $spec.BaseUrl = $resolvedUrl
                    try {
                        & $startBits $key $resolvedUrl $spec.OutFile 0
                    } catch {
                        # BITS failed to start -- fall back to IWR
                        $fbUrl = if ($spec.FallbackUrl) { $spec.FallbackUrl }
                                 elseif ($resolvedUrl)  { $resolvedUrl }
                                 else { $spec.Url }
                        try { & $startIwr $key $fbUrl $spec.OutFile }
                        catch { $state[$key] = 'error'; $errors[$key] = "BITS and IWR both failed: $_" }
                    }
                } else {
                    $spec.Url = $resolvedUrl
                    & $startIwr $key $resolvedUrl $spec.OutFile
                }
            }
        }

        # -- Check IWR completions ---------------------------------------------
        foreach ($key in @($iwrJobs.Keys)) {
            $ij = $iwrJobs[$key]
            if ($ij.Handle.IsCompleted) {
                $spec = $Specs | Where-Object { $_.Key -eq $key }
                $iwrErr = $null
                try {
                    $ij.PS.EndInvoke($ij.Handle)
                    if (-not ((Test-Path $spec.OutFile) -and (Get-Item $spec.OutFile).Length -gt 0)) {
                        throw "File missing or empty after download"
                    }
                    # SourceForge serves an HTML interstitial instead of the file often
                    # enough that the BITS lane has always screened for it. The check
                    # belongs to the URL, not the transport, so it travels with any spec
                    # that SourceForge can answer -- which now includes IWR fallbacks.
                    if ($spec.RequireBinary -and -not (Test-BinaryHeader $spec.OutFile)) {
                        throw "Server returned a non-binary body (probably an HTML page)"
                    }
                    $fileLen = (Get-Item $spec.OutFile).Length
                    $sizes[$key] = Format-ByteSize -Bytes $fileLen -Bracket
                    $state[$key] = 'done'
                } catch {
                    $iwrErr = "$_"
                }
                $ij.PS.Dispose()
                $iwrJobs.Remove($key)

                # A failed IWR download used to be terminal: FallbackUrl was reachable
                # only from the resolver and BITS lanes. That was survivable while the
                # primary was SourceForge-over-BITS, but with the CDN as primary it would
                # make a CDN outage fatal for a load-bearing component. One shot only,
                # guarded by $fbTried, so a fallback that fails the same way cannot loop.
                if ($iwrErr) {
                    if ($spec.FallbackUrl -and -not $fbTried.ContainsKey($key)) {
                        $fbTried[$key] = $true
                        Remove-Item $spec.OutFile -Force -ErrorAction SilentlyContinue
                        try { & $startIwr $key $spec.FallbackUrl $spec.OutFile }
                        catch {
                            $state[$key]  = 'error'
                            $errors[$key] = "$iwrErr; fallback failed: $_"
                        }
                    } else {
                        $state[$key]  = 'error'
                        $errors[$key] = $iwrErr
                    }
                }
            }
        }

        # -- Check BITS completions (with mirror fallback) ---------------------
        foreach ($key in @($bitsJobs.Keys)) {
            $bj = $bitsJobs[$key]
            $spec = $Specs | Where-Object { $_.Key -eq $key }

            if ($bj.JobState -eq 'Transferred') {
                Complete-BitsTransfer $bj
                if (Test-BinaryHeader $spec.OutFile) {
                    $fileLen = (Get-Item $spec.OutFile -ErrorAction SilentlyContinue).Length
                    $sizes[$key] = Format-ByteSize -Bytes $fileLen -Bracket
                    $state[$key] = 'done'
                } else {
                    # Got HTML instead of binary -- try next mirror
                    Remove-Item $spec.OutFile -Force -ErrorAction SilentlyContinue
                    $nextIdx = $bitsMirrorIdx[$key] + 1
                    if ($nextIdx -lt $script:SourceForgeMirrors.Count) {
                        try {
                            & $startBits $key $spec.BaseUrl $spec.OutFile $nextIdx
                        } catch {
                            $state[$key] = 'error'
                            $errors[$key] = "BITS mirror retry failed: $_"
                        }
                    } elseif ($spec.FallbackUrl) {
                        # All mirrors returned HTML -- try CDN fallback via IWR
                        try { & $startIwr $key $spec.FallbackUrl $spec.OutFile }
                        catch { $state[$key] = 'error'; $errors[$key] = "All mirrors and CDN fallback failed: $_" }
                    } else {
                        $state[$key] = 'error'
                        $errors[$key] = "All SourceForge mirrors returned non-binary content"
                    }
                }
                $bitsJobs.Remove($key)
            } elseif ($bj.JobState -eq 'Error' -or $bj.JobState -eq 'TransientError') {
                Remove-BitsTransfer $bj -ErrorAction SilentlyContinue
                $bitsJobs.Remove($key)
                $nextIdx = $bitsMirrorIdx[$key] + 1
                if ($nextIdx -lt $script:SourceForgeMirrors.Count) {
                    try {
                        & $startBits $key $spec.BaseUrl $spec.OutFile $nextIdx
                    } catch {
                        $state[$key] = 'error'
                        $errors[$key] = "BITS mirror retry failed: $_"
                    }
                } elseif ($spec.FallbackUrl) {
                    # All mirrors failed -- try CDN fallback via IWR
                    try { & $startIwr $key $spec.FallbackUrl $spec.OutFile }
                    catch { $state[$key] = 'error'; $errors[$key] = "All mirrors and CDN fallback failed: $_" }
                } else {
                    $state[$key] = 'error'
                    $errors[$key] = "All SourceForge mirrors failed"
                }
            }
        }

        # -- Timeout check -----------------------------------------------------
        foreach ($key in @($started.Keys)) {
            $elapsed = ([datetime]::UtcNow - $started[$key]).TotalSeconds
            if ($state[$key] -eq 'resolving' -and $elapsed -gt 120) {
                # Cancel timed-out URL resolver
                if ($urlJobs.ContainsKey($key)) {
                    try { $urlJobs[$key].PS.Stop() } catch { }
                    try { $urlJobs[$key].PS.Dispose() } catch { }
                    $urlJobs.Remove($key)
                }
                $toSpec = $Specs | Where-Object { $_.Key -eq $key }
                if ($toSpec.FallbackUrl) {
                    # Resolver timed out -- use FallbackUrl via IWR
                    try { & $startIwr $key $toSpec.FallbackUrl $toSpec.OutFile }
                    catch { $state[$key] = 'error'; $errors[$key] = "URL resolution timed out and fallback failed: $_" }
                } else {
                    $state[$key] = 'error'
                    $errors[$key] = 'URL resolution timed out (120s)'
                }
            }
            elseif ($state[$key] -eq 'downloading') {
                # The IWR runspace stamps this once its HEAD is done, so the Content-Length
                # probe is not charged against a budget meant for the transfer. Idempotent.
                $ds = $prog["$key.dlstart"]
                if ($ds -is [datetime] -and $ds -gt $started[$key]) {
                    $started[$key] = $ds
                    $elapsed = ([datetime]::UtcNow - $ds).TotalSeconds
                }

                $dlSpec = $Specs | Where-Object { $_.Key -eq $key }
                $dlTimeout = if ($dlSpec.TimeoutSec) { $dlSpec.TimeoutSec } else { 120 }

                # Now that bytes are tracked, a dead socket can fail in 90s instead of
                # burning the whole wall budget (600s for LEQ). Only ever applied while
                # the transport says it should be moving: BITS backs off and retries on
                # its own from Queued/Connecting, and killing it there would turn a
                # recoverable condition into a hard failure.
                $stalled = $false
                if ($bitsJobs.ContainsKey($key)) {
                    $js = ''
                    try { $js = "$($bitsJobs[$key].JobState)" } catch { }
                    if ($js -ne 'Transferring') { $moveAt[$key] = [datetime]::UtcNow }
                    else { $stalled = (([datetime]::UtcNow - $moveAt[$key]).TotalSeconds -gt 90) }
                } else {
                    $stalled = ($bytesPeak[$key] -gt 0 -and
                                ([datetime]::UtcNow - $moveAt[$key]).TotalSeconds -gt 90)
                }

                if ($elapsed -gt $dlTimeout -or $stalled) {
                    # Cancel timed-out download
                    if ($iwrJobs.ContainsKey($key)) {
                        $iwrJobs[$key].PS.Stop()
                        $iwrJobs[$key].PS.Dispose()
                        $iwrJobs.Remove($key)
                    }
                    if ($bitsJobs.ContainsKey($key)) {
                        Remove-BitsTransfer $bitsJobs[$key] -ErrorAction SilentlyContinue
                        $bitsJobs.Remove($key)
                    }
                    $state[$key] = 'error'
                    $errors[$key] = if ($stalled) { "Download stalled (no data for 90s)" }
                                    else { "Download timed out ($($dlTimeout)s)" }
                }
            }
        }

        # -- Render progress ---------------------------------------------------
        if ($paint.On) {
            & $render $false
        } else {
            $doneCount = @($state.Values | Where-Object { $_ -eq 'done' -or $_ -eq 'error' }).Count + $skipped
            $bar = Get-ProgressBar -Width 30 -Percent -1 -Frame $fi
            $line = "$m  Downloading $doneCount/$total $bar"
            Write-Host "`r$($line.PadRight($pad))" -NoNewline -ForegroundColor DarkGray
        }

        Start-Sleep -Milliseconds 250
        $fi++
    }

    # -- Print final results per item -----------------------------------------
    if ($paint.On) {
        # The block already shows every row's outcome; one last paint settles it and
        # it stays in the scrollback exactly as it stands.
        & $render $true
        Write-Host ""
    } else {
        $doneBar = Get-ProgressBar -Width 30 -Percent 100
        Write-Host "`r$("$m  Downloading $total/$total $doneBar".PadRight($pad))" -ForegroundColor Green
        foreach ($spec in $Specs) {
            $s = $state[$spec.Key]
            $name = $spec.DisplayName
            if ($s -eq 'done') {
                $icon = [char]0x2713
                $szLabel = if ($sizes.ContainsKey($spec.Key)) { " $($sizes[$spec.Key])" } else { "" }
                Write-Host "$m  $icon $name$szLabel" -ForegroundColor Green
            } elseif ($NonFatalKeys -contains $spec.Key) {
                Write-Host "$m  ! $name FAILED (non-fatal, will prompt later)" -ForegroundColor Yellow
            } else {
                Write-Host "$m  ! $name FAILED" -ForegroundColor Red
            }
        }
    }

    } finally {
        # -- Cleanup (always runs, even on exception) --------------------------
        # Every frame ends with the cursor restored below the block, so this only has to
        # catch a throw mid-paint -- but leaving the cursor stranded inside the block
        # would have the retry menu draw over live rows.
        if ($paint.On) {
            try {
                if ($Host.UI.RawUI.CursorPosition.X -ne 0) { Write-Host "" }
            } catch { }
        }
        foreach ($key in @($iwrJobs.Keys)) {
            try { $iwrJobs[$key].PS.Stop() } catch { }
            try { $iwrJobs[$key].PS.Dispose() } catch { }
        }
        foreach ($key in @($bitsJobs.Keys)) {
            Remove-BitsTransfer $bitsJobs[$key] -ErrorAction SilentlyContinue
        }
        $pool.Close()
        $pool.Dispose()
    }

    # -- Error check -----------------------------------------------------------
    # Separate non-fatal errors (e.g. SoundControl) from fatal ones
    $script:DownloadWarnings = @{}
    if ($errors.Count -gt 0) {
        $fatalErrors = @{}
        foreach ($entry in @($errors.GetEnumerator())) {
            if ($NonFatalKeys -contains $entry.Key) {
                $script:DownloadWarnings[$entry.Key] = $entry.Value
            } else {
                $fatalErrors[$entry.Key] = $entry.Value
            }
        }
        if ($fatalErrors.Count -gt 0) {
            $msg = ($fatalErrors.GetEnumerator() | ForEach-Object { "$($_.Key): $($_.Value)" }) -join "; "
            throw "Failed to download: $msg"
        }
    }

    # -- Build result hashtable ------------------------------------------------
    $results = @{}
    foreach ($spec in $Specs) {
        if ($script:DownloadWarnings.ContainsKey($spec.Key)) {
            $results[$spec.Key] = $null
        } else {
            $results[$spec.Key] = $spec.OutFile
        }
    }
    return $results
}

function Get-Downloads {
    <#
    .SYNOPSIS
        Downloads components for installation. Skips already-installed components.
        Downloads run in parallel for speed.
    .PARAMETER IncludeVirtualAudio
        If set, includes VB-CABLE and Voicemeeter (PATH B: DAC/amp/onboard).
        If not set, downloads shared components only (PATH A: approved device).
    .PARAMETER WantVoicemeeter
        Whether Voicemeeter is wanted at all. Defaults to true for backwards
        compatibility. Independent of IncludeVirtualAudio so a user who already
        runs Wave Link or Voicemeeter Banana/Potato can take the rest of the
        stack without a mixer being installed underneath them.
    #>
    param(
        [switch]$IncludeVirtualAudio,
        [bool]$WantVoicemeeter = $true
    )

    if (-not (Test-Path $script:TempPath)) {
        New-Item -ItemType Directory -Path $script:TempPath -Force | Out-Null
    }

    # SoundControlPresent is NOT a download path -- it records "already installed,
    # nothing to fetch", which $files.SoundControl (a temp file path) cannot express:
    # a null there means the download FAILED, and the caller reacts accordingly.
    $files = @{
        VBCable             = $null
        Voicemeeter         = $null
        ReaPlugs            = $null
        EAPO                = $null
        HeSuVi              = $null
        SoundControl        = $null
        SoundControlPresent = $false
    }

    # -- Detect what is already installed ------------------------------------
    $reaplugsDlls = @(Get-ChildItem "${env:ProgramFiles}\VSTPlugins\ReaPlugs\*.dll" -ErrorAction SilentlyContinue)
    $skipReaPlugs = ($reaplugsDlls -and $reaplugsDlls.Count -ge 5)
    # E-APO has NO skip. It is fetched and re-run even when already installed, because
    # its setup is the only thing that reopens Device Selector -- and [1] Install has
    # just removed the retired Hi-Fi Cable an existing E-APO was very likely still bound
    # to, then laid down VB-CABLE in its place. Re-running it is also what creates the
    # SonicScout2.0 folder icon, its .url files and the desktop shortcut, none of which an
    # existing-E-APO user used to get. E-APO's installer handles installing over itself.
    # $eapoPresent only words the message below.
    $eapoPresent = Test-Path (Join-Path $env:ProgramFiles "EqualizerAPO\config")
    $skipHeSuVi = Test-Path (Join-Path $env:ProgramFiles "EqualizerAPO\config\HeSuVi")
    # LEQ is a ~200 MB fetch, so a re-run must not repeat it. The presence check
    # targets the exact path Install-SoundControl copies to, which is also what the
    # completion menu launches and what Uninstall-SoundControl removes.
    $leqExe = Join-Path $env:LOCALAPPDATA "Programs\LEQControlPanel\LEQControlPanel.exe"
    $skipSoundControl = Test-Path -LiteralPath $leqExe

    # BITS is started further down, and only if a spec actually asks for it. It used to
    # be started here whenever E-APO or HeSuVi was wanted, which is now exactly the wrong
    # gate: both fetch from the CDN over IWR, so starting BITS would buy nothing and cost
    # a measured 4.2s service cold start on a PC where BITS is stopped.

    if ($IncludeVirtualAudio) {
        # VB-CABLE presence is a POSITIVE check: the endpoints must actually
        # resolve. Get-SonicScout20Endpoints matches the interface description
        # 'VB-Audio Virtual Cable' exactly, so the retired Hi-Fi Cable (which
        # enumerates as "VB-Audio Hi-Fi Cable") cannot masquerade as an installed
        # cable and silently suppress the install.
        #
        # HEALTHY means all three: 8ch render + 16ch render + capture. A clean
        # VB-CABLE v45 ships all three Active, and the 16ch render is what the
        # spatial profiles need -- so "some endpoint exists" is not good enough.
        $eps = Get-SonicScout20Endpoints
        $vbAny     = [bool]($eps.Render8 -or $eps.Render16 -or $eps.Capture)
        $vbHealthy = [bool]($eps.Render8 -and $eps.Render16 -and $eps.Capture)
        $vbPartial = ($vbAny -and -not $vbHealthy)

        # Skip the download whenever ANY endpoint exists, healthy or not: VB-CABLE
        # setup refuses to install over an existing copy (non-zero exit, see
        # Install-VBCable), so re-running it cannot repair a partial install. The
        # real fix is Start Clean -- remove, reboot, reinstall -- so say that
        # instead of silently proceeding with a broken cable.
        $skipVBCable = $vbAny

        # Whether Voicemeeter is WANTED is entirely the caller's decision: the
        # install path asks about every mixer it found, paid-edition override
        # included, and hands the verdict down in $WantVoicemeeter. Re-deciding any
        # of that here would silently veto a confirmation the user just gave.
        #
        # The only thing this layer adds is "we already have it", and that is gated
        # on the Standard EXE -- NOT on .Present, which is also true for a leftover
        # uninstall registry key with nothing on disk. Skipping on .Present would
        # hand that user a finished install with no mixer in it at all.
        $vmEdition = Test-VoicemeeterEdition
        $skipVoicemeeter = ((-not $WantVoicemeeter) -or $vmEdition.Standard)
    }

    # -- Print skip messages for already-installed components ----------------
    if ($IncludeVirtualAudio) {
        if ($vbHealthy) {
            Write-Host "$($script:BoxMargin)VB-CABLE already installed, skipping download." -ForegroundColor DarkGray
        } elseif ($vbPartial) {
            $missing = @()
            if (-not $eps.Render8)  { $missing += "8ch render (SonicScout2.0)" }
            if (-not $eps.Render16) { $missing += "16ch render (SonicScout2.0 +)" }
            if (-not $eps.Capture)  { $missing += "capture (SonicScout2.0 Unified Output)" }
            Write-Host ""
            Write-Host "$($script:BoxMargin)WARNING: VB-CABLE is installed but incomplete." -ForegroundColor Yellow
            Write-Host "$($script:BoxMargin)Missing: $($missing -join ', ')" -ForegroundColor Yellow
            Write-Host "$($script:BoxMargin)Setup cannot repair this in place -- VB-CABLE refuses to install" -ForegroundColor Yellow
            Write-Host "$($script:BoxMargin)over an existing copy. Use [2] Start Clean to remove it, restart," -ForegroundColor Yellow
            Write-Host "$($script:BoxMargin)then run [1] Install for a complete cable." -ForegroundColor Yellow
            Write-Host "$($script:BoxMargin)Continuing with the endpoints that do exist." -ForegroundColor DarkGray
            Write-Host ""
        }
        # Keyed on the same flags the skip decision uses. The old .Present test
        # announced a skip and then queued the download anyway.
        if ($vmEdition.Standard) {
            Write-Host "$($script:BoxMargin)$($vmEdition.Name) already installed, skipping download." -ForegroundColor DarkGray
        } elseif (-not $WantVoicemeeter) {
            Write-Host "$($script:BoxMargin)Skipping Voicemeeter (not requested)." -ForegroundColor DarkGray
        }
    }
    if ($skipReaPlugs) { Write-Host "$($script:BoxMargin)ReaPlugs already installed, skipping download." -ForegroundColor DarkGray }
    if ($eapoPresent)  { Write-Host "$($script:BoxMargin)Equalizer APO already installed -- reinstalling it to rebind your devices." -ForegroundColor DarkGray }
    if ($skipHeSuVi)   { Write-Host "$($script:BoxMargin)HeSuVi already installed, skipping download." -ForegroundColor DarkGray }
    if ($skipSoundControl) { Write-Host "$($script:BoxMargin)LEQ Control Panel already installed, skipping download." -ForegroundColor DarkGray }

    # -- Build download specs ------------------------------------------------
    $totalComponents = if ($IncludeVirtualAudio) { 6 } else { 4 }
    $specs = @()

    if ($IncludeVirtualAudio) {
        if (-not $skipVBCable) {
            $files.VBCable = Join-Path $script:TempPath "VBCableSetup.zip"
            $specs += @{
                Key           = 'VBCable'
                DisplayName   = 'VB-CABLE'
                OutFile       = $files.VBCable
                Method        = 'IWR'
                Url           = 'https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack45.zip'
                BaseUrl       = $null
                UrlResolver   = $null
                FallbackUrl   = $null
                RequireBinary = $false   # a .zip opens 'PK'; Test-BinaryHeader wants MZ or 7z
                TimeoutSec    = 120
            }
        }

        if (-not $skipVoicemeeter) {
            $files.Voicemeeter = Join-Path $script:TempPath "VoicemeeterSetup.zip"
            $specs += @{
                Key           = 'Voicemeeter'
                DisplayName   = 'Voicemeeter'
                OutFile       = $files.Voicemeeter
                Method        = 'IWR'
                Url           = $null
                BaseUrl       = $null
                UrlResolver   = $script:VoicemeeterUrlResolver
                FallbackUrl   = $null
                RequireBinary = $false   # .zip, as above
                TimeoutSec    = 135
            }
        }
    }

    if (-not $skipReaPlugs) {
        $files.ReaPlugs = Join-Path $script:TempPath "reaplugs_x64.exe"
        $specs += @{
            Key           = 'ReaPlugs'
            DisplayName   = 'ReaPlugs'
            OutFile       = $files.ReaPlugs
            Method        = 'IWR'
            Url           = 'https://www.reaper.fm/reaplugs/reaplugs236_x64-install.exe'
            BaseUrl       = $null
            UrlResolver   = $null
            FallbackUrl   = $null
            RequireBinary = $false   # reaper.fm serves the exe directly, no interstitial
            TimeoutSec    = 120
        }
    }

    # Unconditional -- see the $eapoPresent note above for why there is no skip.
    #
    # CDN primary, SourceForge fallback. Both are GPL projects we are entitled to
    # rehost, and the mirror measured 20x faster to first byte (0.25s vs 5.5s) --
    # SourceForge costs a BITS service cold start plus a redirect-to-mirror handoff,
    # and every failed mirror got a fresh 120s budget before the CDN was even tried.
    #
    # PINNED, deliberately. This used to resolve the newest release from the
    # SourceForge RSS feed; it now takes the same 1.4.2 that SonicScout2.0's installer
    # bundles as a component, so every user gets the build the library configs were
    # validated against. A new E-APO release needs a manual CDN re-upload -- see
    # $script:EapoUrlResolver for how to hand version selection back to SourceForge.
    $files.EAPO = Join-Path $script:TempPath "EqualizerAPO64.exe"
    $localEapo = Join-Path $PSScriptRoot "..\tools\SonicScoutCSharp\installers\EqualizerAPO_Setup.exe"
    if ($PSScriptRoot -and (Test-Path -LiteralPath $localEapo)) {
        Copy-Item -LiteralPath $localEapo -Destination $files.EAPO -Force
        Write-Host "$($script:BoxMargin)Using the Equalizer APO installer already downloaded." -ForegroundColor DarkGray
    } else {
        $specs += @{
            Key           = 'EAPO'
            DisplayName   = 'Equalizer APO'
            OutFile       = $files.EAPO
            Method        = 'IWR'
            Url           = 'https://sourceforge.net/projects/equalizerapo/files/1.4.2/EqualizerAPO-x64-1.4.2.exe/download'
            BaseUrl       = $null
            UrlResolver   = $null
            FallbackUrl   = 'https://sourceforge.net/projects/equalizerapo/files/1.4/EqualizerAPO64-1.4.exe/download'
            RequireBinary = $true
            TimeoutSec    = 120
        }
    }

    if (-not $skipHeSuVi) {
        # CDN primary, SourceForge fallback. The CDN copy is byte-identical: 27,270,486
        # bytes, the same length SourceForge reports for HeSuVi_2.0.0.1.exe.
        $files.HeSuVi = Join-Path $script:TempPath "HeSuVi.exe"
        $localHeSuVi = Join-Path $PSScriptRoot "..\tools\SonicScoutCSharp\installers\HeSuVi.exe"
        if ($PSScriptRoot -and (Test-Path -LiteralPath $localHeSuVi)) {
            Copy-Item -LiteralPath $localHeSuVi -Destination $files.HeSuVi -Force
            Write-Host "$($script:BoxMargin)Using the HeSuVi installer already downloaded." -ForegroundColor DarkGray
        } else {
        $specs += @{
            Key           = 'HeSuVi'
            DisplayName   = 'HeSuVi'
            OutFile       = $files.HeSuVi
            Method        = 'IWR'
            Url           = 'https://sourceforge.net/projects/hesuvi/files/HeSuVi_2.0.0.1.exe/download'
            BaseUrl       = $null
            UrlResolver   = $null
            FallbackUrl   = 'https://sourceforge.net/projects/hesuvi/files/HeSuVi_2.0.0.1.exe/download'
            RequireBinary = $true
            TimeoutSec    = 120
        }
        }
    }

    # LEQ Control Panel. Vendored source (tools/LEQControlPanel) is authoritative:
    # it carries the SonicScout device-name fixes the old releases predate, so a
    # local build wins over the download whenever the source and .NET SDK exist.
    if ($skipSoundControl) {
        $files.SoundControlPresent = $true
    } else {
        $localLeq = Build-LocalLeqControlPanel
        if ($localLeq) {
            $files.SoundControl = $localLeq
        } else {
            $files.SoundControl = Join-Path $script:TempPath "LEQControlPanel.exe"
            $specs += @{
                Key           = 'SoundControl'
                DisplayName   = 'LEQ Control Panel'
                OutFile       = $files.SoundControl
                Method        = 'IWR'
                Url           = $null
                BaseUrl       = $null
                UrlResolver   = $script:LeqUrlResolver
                FallbackUrl   = 'https://github.com/sensoredrooster/LEQControlPanel/releases/latest/download/LEQControlPanel.exe'
                RequireBinary = $false   # GitHub asset then CDN; neither serves an interstitial
                TimeoutSec    = 600
            }
        }
    }

    # -- Ensure BITS is available, but ONLY if something actually uses it -----
    # Gated on the built spec list rather than on which components were requested, so
    # the service is never started for a run that will not touch it. No spec ships with
    # Method = 'BITS' today; the transport and its SourceForge mirror rotation are kept
    # for any future source that needs them, and this gate turns itself back on.
    if (@($specs | Where-Object { $_.Method -eq 'BITS' }).Count -gt 0) {
        try {
            Ensure-BitsRunning
        } catch {
            throw "BITS service could not be started. If this is a managed PC, ask your IT admin to enable BITS."
        }
    }

    # -- Download everything in parallel -------------------------------------
    try {
        if ($specs.Count -gt 0) {
            $dlResults = Start-ParallelDownloads -Specs $specs -TotalCount $totalComponents -NonFatalKeys @('SoundControl')
        }

        # Clear SoundControl path if its download failed (non-fatal)
        if ($script:DownloadWarnings -and $script:DownloadWarnings.ContainsKey('SoundControl')) {
            $files.SoundControl = $null
        }

        return $files
    } finally {
        Restore-BitsState
    }
}

function Get-UrlToFile {
    <#
    .SYNOPSIS
        Downloads a single file with a live byte counter and a hard timeout.
        Returns $true on success, $false on any failure (never throws).
    .DESCRIPTION
        Same Start-Job + Write-Wait shape as Get-HrirFile: the transfer runs in a job so
        this thread stays free to animate, and the partial file's length is the progress
        readout. For one-off fetches that do not warrant the parallel downloader.
    #>
    param(
        [string]$Url,
        [string]$OutFile,
        [string]$Label,
        [int]$TimeoutSeconds = 300
    )

    Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
    $job = Start-Job -ScriptBlock {
        param($u, $o)
        $ErrorActionPreference = 'Stop'
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $u -OutFile $o -UseBasicParsing -ErrorAction Stop
    } -ArgumentList $Url, $OutFile

    $outRef = $OutFile
    $finished = Write-Wait -Message $Label -Until { $job.State -ne 'Running' } -TimeoutSeconds $TimeoutSeconds -Progress {
        $pf = Get-Item $outRef -ErrorAction SilentlyContinue
        if ($pf) { Format-ByteSize -Bytes $pf.Length -Bracket }
    }

    $failed = ($job.State -eq 'Failed')
    $err = ''
    if ($failed) {
        # The terminating exception, not Receive-Job: -ErrorAction SilentlyContinue drops
        # the error records before 2>&1 can capture them, which leaves the message blank.
        try {
            $reason = $job.ChildJobs[0].JobStateInfo.Reason
            if ($reason) { $err = $reason.Message }
        } catch { }
        if (-not $err) { try { $err = "$(Receive-Job $job 2>&1 | Select-Object -First 1)" } catch { $err = "$_" } }
    }
    if (-not $finished) { try { Stop-Job $job -ErrorAction SilentlyContinue } catch { } }
    Remove-Job $job -Force -ErrorAction SilentlyContinue

    $done = Get-Item $OutFile -ErrorAction SilentlyContinue
    if (-not $finished -or $failed -or -not $done -or $done.Length -le 0) {
        # Never leave a truncated file behind: the next attempt writes to the same path
        # and a half-downloaded zip that survives is worse than no zip at all.
        Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
        if (-not $finished) {
            Write-Host "$($script:BoxMargin)Download timed out ($($TimeoutSeconds)s)." -ForegroundColor Yellow
        } elseif ($failed) {
            Write-Host "$($script:BoxMargin)Download failed: $err" -ForegroundColor Yellow
        } else {
            Write-Host "$($script:BoxMargin)Download produced no data." -ForegroundColor Yellow
        }
        return $false
    }
    return $true
}

# ============================================================================
# SECTION 4: Uninstall Functions
# ============================================================================


function Get-SonicScout20BackupRoot {
    <#
    .SYNOPSIS
        Resolves a "SonicScout2.0 Backups" root that is PROVEN writable, or $null.
    .DESCRIPTION
        Every candidate is proven rather than assumed, because the checks that look
        sufficient are not. Measured on PS 5.1:

          New-Item -ItemType Directory -Force  reports success, returns zero objects,
          throws nothing even under $ErrorActionPreference = 'Stop', and creates
          NOTHING when the path runs through a dangling reparse point.

        That single behaviour is why a backup could fail with "Could not find a part
        of the path '...\SonicScout2.0 Backups\library-<stamp>'" on a machine whose
        Documents folder was a stale OneDrive Known Folder Move junction.

        The chain deliberately ends at LOCALAPPDATA. $script:SonicScout20Root is NOT a
        candidate: this helper is shared with Uninstall-ExistingEAPO, and uninstall
        removes the SonicScout2.0 tree -- a backup written there would be destroyed
        along with the thing it was backing up.
    .PARAMETER Force
        Re-probe and ignore the cache. Passed by the retry affordances so a folder the
        user has just fixed is re-detected instead of a stale failure being reused.
    .OUTPUTS
        Backup root path, or $null when no candidate survived.
    #>
    param([switch]$Force)

    if (-not $Force -and $script:BackupRoot) { return $script:BackupRoot }

    # Candidate 1 is GetFolderPath. SpecialFolderOption.None VERIFIES and returns
    # String.Empty for a missing folder -- it is NOT DoNotVerify. Measured on
    # PS 5.1.26100.8875 / CLR 4.0.30319. An empty return therefore means Documents is
    # gone, and the candidate is skipped rather than joined onto: joining it
    # unconditionally, outside any try, turns it into an uncaught terminating error
    # under StrictMode that kills the installer instead of degrading.
    $candidates = @(
        [Environment]::GetFolderPath('MyDocuments')
        $(if ($env:OneDrive)    { Join-Path $env:OneDrive 'Documents'    } else { '' })
        $(if ($env:USERPROFILE) { Join-Path $env:USERPROFILE 'Documents' } else { '' })
        $env:USERPROFILE
        $env:LOCALAPPDATA
    )

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }

        $root       = Join-Path $candidate 'SonicScout2.0 Backups'
        $preExisted = Test-Path -LiteralPath $root
        $accepted   = $false

        try {
            New-Item -Path $root -ItemType Directory -Force | Out-Null

            # Do not trust the line above. Zero objects returned is a signal, not
            # noise: through a dangling reparse point New-Item reports success and
            # creates nothing. This assert is the only thing that catches that, and
            # it also rejects a plain FILE sitting at this name (Directory::Exists is
            # false for a file).
            if ([IO.Directory]::Exists($root)) {

                # Probe write. THIS IS THE LOAD-BEARING GUARD. It is the only check
                # that catches every failing state, and the sole detector for a
                # dangling junction sitting at 'SonicScout2.0 Backups' ITSELF, where
                # [IO.Directory]::Exists returns True and every cheaper check passes.
                # It also catches Controlled Folder Access, which fails on write
                # rather than on create. Do not optimize it out.
                $probeFile = Join-Path $root '.sonicscout-write-probe'
                try {
                    Set-Content -LiteralPath $probeFile -Value 'probe' -Encoding Ascii -ErrorAction Stop
                    Remove-Item -LiteralPath $probeFile -Force -ErrorAction Stop
                    $accepted = $true
                }
                catch {
                    Write-Verbose "Backup root '$root': probe write failed ($($_.Exception.GetType().Name))."
                    # Only ever remove what THIS run created. A pre-existing folder is
                    # the user's, whatever state it turned out to be in.
                    if (-not $preExisted) {
                        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }
            }
            else {
                Write-Verbose "Backup root '$root': New-Item reported success but created nothing."
            }
        }
        catch {
            Write-Verbose "Backup root '$root': $($_.Exception.GetType().Name)."
        }

        if ($accepted) {
            $script:BackupRoot            = $root
            $script:BackupRootCreatedByUs = (-not $preExisted)
            return $root
        }
    }

    return $null
}

function Remove-UnusedBackupRoot {
    <#
    .SYNOPSIS
        Removes the backup root when THIS run created it and nothing was written in.
    .DESCRIPTION
        Resolving a backup root is not a read-only act: Get-SonicScout20BackupRoot creates
        the folder and writes a probe file to prove it is usable. So an uninstall that
        resolves a root and is then cancelled would leave a directory behind, and the
        cancel message ("nothing was changed") would be false.

        Two things this deliberately will NOT do:
          - touch a root that already existed. That folder is the user's, holding
            previous backups, whatever this run decided about it.
          - delete a NON-EMPTY root. A partial copy is still the user's data; it is
            reported instead, so they can find it.
    #>
    if (-not $script:BackupRootCreatedByUs) { return }
    if (-not $script:BackupRoot) { return }
    if (-not (Test-Path -LiteralPath $script:BackupRoot)) {
        # Already gone -- something else removed it. The cache still names it, and a
        # cached path to a directory that no longer exists is the same defect class as
        # caching a $null: a later caller would trust a hit that cannot be written to.
        $script:BackupRoot            = $null
        $script:BackupRootCreatedByUs = $false
        return
    }

    $contents = @(Get-ChildItem -LiteralPath $script:BackupRoot -Force -ErrorAction SilentlyContinue)
    if ($contents.Count -gt 0) {
        Write-Host "$($script:BoxMargin)A partial backup was left at: $($script:BackupRoot)" -ForegroundColor DarkGray
        return
    }

    Remove-Item -LiteralPath $script:BackupRoot -Recurse -Force -ErrorAction SilentlyContinue
    # Clear the cache too: the proven-writable path no longer exists, and a later
    # caller must re-resolve rather than trust a stale hit.
    $script:BackupRoot            = $null
    $script:BackupRootCreatedByUs = $false
}

function Backup-SonicScout20Library {
    <#
    .SYNOPSIS
        Backs up the SonicScout2.0 library folder before destructive operations.
    .OUTPUTS
        Backup folder path if successful, $null when there is nothing to back up,
        $false when a backup was attempted and failed.
    .PARAMETER Rolling
        Use a single fixed backup dest (library-previous), overwriting any prior
        backup, instead of a timestamped folder. Used by the library updater.
    .PARAMETER RefreshBackupRoot
        Forwarded to Get-SonicScout20BackupRoot as -Force. Passed by the retry affordance
        so a folder the user has just fixed is re-detected rather than a cached
        result being reused.
    #>
    param([switch]$Rolling, [switch]$RefreshBackupRoot)

    # Via $script:SonicScout20Root, not a second Join-Path off $env:ProgramFiles.
    # Identical in production, but this function decides whether the library may be
    # destroyed, so it must read the SAME root the lay-down and the state check use --
    # one definition, no chance of the two drifting apart.
    $libraryPath = Join-Path $script:SonicScout20Root "library"

    if (-not (Test-Path $libraryPath)) { return $null }

    $childItems = @(Get-ChildItem -Path $libraryPath -Recurse -File -ErrorAction SilentlyContinue)
    if ($childItems.Count -eq 0) { return $null }

    # Proven writable, not assumed. Get-SonicScout20BackupRoot also guarantees the root
    # exists, which is why there is no New-Item on it below: the New-Item that used to
    # live here is exactly the call whose reported success could not be trusted.
    $backupRoot = Get-SonicScout20BackupRoot -Force:$RefreshBackupRoot
    if (-not $backupRoot) {
        Write-Host ""
        Write-Host "$($script:BoxMargin)Warning: no writable backup location could be found." -ForegroundColor Yellow
        return $false
    }

    Write-Host ""
    Write-Host "$($script:BoxMargin)Backing up SonicScout2.0 library ($($childItems.Count) files)..." -ForegroundColor Cyan

    try {
        # Inside the try on purpose. Join-Path resolves the PSDrive and throws
        # "Cannot find drive" if it is gone -- and the root was proven writable a
        # moment ago, not now. A removable drive pulled, or the folder deleted,
        # between resolve and use would otherwise crash the installer uncaught,
        # which is the same shape as the bug this whole change exists to fix.
        if ($Rolling) {
            # Single rolling dest -- overwrite any prior backup (no timestamped pile).
            $backupDest = Join-Path $backupRoot "library-previous"
        } else {
            $timestamp  = Get-Date -Format "yyyy-MM-dd_HHmmss"
            $backupDest = Join-Path $backupRoot "library-$timestamp"
        }

        if ($Rolling -and (Test-Path $backupDest)) {
            Remove-Item $backupDest -Recurse -Force -ErrorAction SilentlyContinue
        }
        Copy-Item -Path $libraryPath -Destination $backupDest -Recurse -Force

        # Verify HERE, inside this function and before the return, never in a caller.
        # Callers render a destructive-confirm prompt on the strength of the value
        # returned below, so it has to be final by the time they see it.
        #
        # The baseline is re-enumerated WITHOUT -ErrorAction SilentlyContinue: the
        # count taken at the top of this function suppresses errors, so an unreadable
        # source file silently drops out of it and a short copy would compare equal.
        # Unsuppressed, any such error throws into the catch and is reported as the
        # failure it is. Bytes as well as count, because a copy that stalls mid-file
        # yields the right file count and the wrong size.
        # -lt, not -ne. The check exists to catch an INCOMPLETE copy, and the
        # destination legitimately ends up with MORE than the source: Get-ChildItem
        # -Recurse does not descend a junction inside library\, while Copy-Item
        # -Recurse copies straight through it (measured: 1 file enumerated, 4 copied).
        # Treating that as failure would send a user whose backup actually succeeded
        # to a menu whose option destroys the library.
        $srcFiles  = @(Get-ChildItem -LiteralPath $libraryPath -Recurse -File)
        $destFiles = @(Get-ChildItem -LiteralPath $backupDest  -Recurse -File)
        $srcBytes  = ($srcFiles  | Measure-Object -Property Length -Sum).Sum
        $destBytes = ($destFiles | Measure-Object -Property Length -Sum).Sum
        if ($destFiles.Count -lt $srcFiles.Count -or $destBytes -lt $srcBytes) {
            Write-Host "$($script:BoxMargin)Warning: backup verify failed -- copied $($destFiles.Count) of $($srcFiles.Count) files, $destBytes of $srcBytes bytes." -ForegroundColor Yellow
            Write-Host "$($script:BoxMargin)Incomplete backup left at: $backupDest" -ForegroundColor DarkGray
            return $false
        }

        Write-Host "$($script:BoxMargin)Library backed up to:" -ForegroundColor Green
        Write-Host "$($script:BoxMargin)$backupDest" -ForegroundColor DarkGray
        return $backupDest
    }
    catch {
        # Exception TYPE as well as message: the three filesystem states that produce
        # this are indistinguishable from the message alone, and support cannot tell
        # them apart without it.
        Write-Host "$($script:BoxMargin)Warning: Library backup failed: $($_.Exception.GetType().Name): $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "$($script:BoxMargin)Backup location was: $backupRoot" -ForegroundColor DarkGray
        # $false, not $null: callers must be able to tell a FAILED backup from the two
        # "nothing to back up" cases above, which legitimately return $null.
        # No caller-specific follow-up line here -- this function is shared by the
        # install and uninstall paths, and each prints its own.
        return $false
    }
}

function Backup-EAPOConfigFile {
    <#
    .SYNOPSIS
        Backs up config.txt alone, immediately before Write-InitialConfig overwrites it.
    .DESCRIPTION
        Write-InitialConfig always rewrites config.txt (Device: lines scope the
        includes that follow, so the order must be exact). That is fine as long as
        the previous file is never lost -- including for a non-SonicScout2.0 E-APO user
        whose own chain lives there.

        Only config.txt is copied, NOT the whole config folder: that folder holds
        the entire SonicScout2.0 library and HeSuVi, and re-running Install is normal.

        Our own config self-identifies by its first line, so a re-run cannot bury
        the user's original under copies of our template:
          foreign config -> timestamped, kept permanently
          our config     -> single rolling copy, overwritten freely

        ONE foreign backup per run. Install-Eapo calls this before E-APO's setup runs,
        because a reinstall over an existing copy can replace config.txt; the later
        call from Write-InitialConfig would then timestamp whatever the installer left
        behind and present that to the user as "your existing config".
    .OUTPUTS
        Backup file path if one was taken, $null otherwise.
    #>
    $configFile = Join-Path $env:ProgramFiles "EqualizerAPO\config\config.txt"
    if (-not (Test-Path -LiteralPath $configFile)) { return $null }

    $isOurs = $false
    try {
        $firstLine = Get-Content -LiteralPath $configFile -TotalCount 1 -ErrorAction Stop
        $isOurs = ("$firstLine".Trim() -eq '# SonicScout2.0 config.txt')
    } catch { } # Unreadable -- treat as foreign and keep it

    # Gated on foreign only. Our own config is a single rolling copy that costs nothing
    # to refresh, and refreshing it is correct: the second call runs immediately before
    # the overwrite, so it captures the newest version of our file.
    if (-not $isOurs -and $script:ForeignConfigBackup) { return $script:ForeignConfigBackup }

    $backupRoot = Join-Path ([Environment]::GetFolderPath('MyDocuments')) "SonicScout2.0 Backups"
    if ($isOurs) {
        $backupDest = Join-Path $backupRoot "config-previous.txt"
    } else {
        $timestamp  = Get-Date -Format "yyyy-MM-dd_HHmmss"
        $backupDest = Join-Path $backupRoot "config-yours-$timestamp.txt"
    }

    try {
        if (-not (Test-Path $backupRoot)) {
            New-Item -Path $backupRoot -ItemType Directory -Force | Out-Null
        }
        Copy-Item -LiteralPath $configFile -Destination $backupDest -Force

        if ($isOurs) {
            Write-Host "$($script:BoxMargin)Previous config.txt backed up." -ForegroundColor DarkGray
        } else {
            $script:ForeignConfigBackup = $backupDest
            Write-Host ""
            Write-Host "$($script:BoxMargin)Your existing E-APO config.txt was saved to:" -ForegroundColor Cyan
            Write-Host "$($script:BoxMargin)$backupDest" -ForegroundColor Cyan
            Write-Host "$($script:BoxMargin)SonicScout2.0 replaces config.txt with its own; yours is recoverable above." -ForegroundColor DarkGray
        }
        return $backupDest
    }
    catch {
        Write-Host "$($script:BoxMargin)Warning: config.txt backup failed: $_" -ForegroundColor Yellow
        return $null
    }
}

function Backup-EAPOConfig {
    <#
    .SYNOPSIS
        Backs up the entire E-APO config folder before destructive operations.
        Called from Uninstall-ExistingEAPO, where the whole tree is about to go.
        For the non-destructive config.txt rewrite, use Backup-EAPOConfigFile.
    .OUTPUTS
        Backup folder path if successful, $null otherwise.
    #>
    $configPath = Join-Path $env:ProgramFiles "EqualizerAPO\config"

    if (-not (Test-Path $configPath)) { return $null }

    $childItems = @(Get-ChildItem -Path $configPath -Recurse -File -ErrorAction SilentlyContinue)
    if ($childItems.Count -eq 0) { return $null }

    $docsFolder = [Environment]::GetFolderPath('MyDocuments')
    $timestamp  = Get-Date -Format "yyyy-MM-dd_HHmmss"
    $backupRoot = Join-Path $docsFolder "SonicScout2.0 Backups"
    $backupDest = Join-Path $backupRoot "eapo-config-$timestamp"

    Write-Host ""
    Write-Host "$($script:BoxMargin)Backing up E-APO config ($($childItems.Count) files)..." -ForegroundColor Cyan

    try {
        if (-not (Test-Path $backupRoot)) {
            New-Item -Path $backupRoot -ItemType Directory -Force | Out-Null
        }
        Copy-Item -Path $configPath -Destination $backupDest -Recurse -Force
        Write-Host "$($script:BoxMargin)Config backed up to:" -ForegroundColor Green
        Write-Host "$($script:BoxMargin)$backupDest" -ForegroundColor DarkGray
        return $backupDest
    }
    catch {
        Write-Host "$($script:BoxMargin)Warning: Config backup failed: $_" -ForegroundColor Yellow
        Write-Host "$($script:BoxMargin)Continuing with uninstall..." -ForegroundColor Yellow
        return $null
    }
}

function Test-SonicScout20Installed {
    <#
    .SYNOPSIS
        Returns $true if the SonicScout2.0 app is installed on this PC.
    .DESCRIPTION
        SonicScout2.0 deploys the SAME versioned DLL and JSFX filenames to the SAME
        two folders this installer writes (VSTPlugins\SonicScout2.0 and
        ReaPlugs\JS\Effects\SonicScout2.0), and neither product stamps provenance.
        So the plugins cannot be told apart file by file, and the only safe
        question is whether the app is here at all.

        The cost of the two errors is not symmetric. Saying "installed" when it
        is not just leaves our own plugins behind -- the state this uninstall had
        before. Saying "not installed" when it is deletes a working app's plugins
        out from under it. Every signal is therefore OR'd and any single hit wins.

        Four independent signals, in this order:
          1. Add/Remove Programs key -- authoritative, survives the app closed
          2. ProgramData library root -- survives the app closed
          3. Default install exe      -- survives the app closed
          4. Running process          -- proves presence, cannot prove absence

        Signal 1 is SonicScout2.0's own AppId (installer\SonicScout2.0.iss), the key its
        installer keys its own fresh-install detection on. All three hives are
        probed because PrivilegesRequiredOverridesAllowed lets it install per-user.
        Signal 3 only covers the default directory: the Inno directory page is not
        disabled, so a relocated install is invisible to it -- the same defect
        Test-VoicemeeterEdition avoids by keying presence on the registry.

        No try/catch anywhere: every probe below is already exception-safe via
        -ErrorAction SilentlyContinue, and empty catch blocks are a counted
        analyzer finding in this file.
    .OUTPUTS
        [bool]
    #>
    # 1. Add/Remove Programs. Inno Setup AppId, suffixed _is1 by Inno.
    $sonicScoutArpKey = '{2A2388E9-E5F3-46A3-AFB3-B26F33707564}_is1'
    foreach ($hive in @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    )) {
        if (Test-Path -LiteralPath (Join-Path $hive $sonicScoutArpKey) -ErrorAction SilentlyContinue) {
            return $true
        }
    }

    # 2. Shared library root. Can outlive an uninstall, which errs toward
    # "installed" -- the safe direction here.
    if ($env:ProgramData) {
        if (Test-Path -LiteralPath (Join-Path $env:ProgramData "SonicScout2.0") -ErrorAction SilentlyContinue) {
            return $true
        }
    }

    # 3. Default install directory, keyed on the exe rather than the folder so an
    # emptied leftover directory does not read as an install.
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $root) { continue }
        if (Test-Path -LiteralPath (Join-Path $root "SonicScout2.0\SonicScout2.0.exe") -ErrorAction SilentlyContinue) {
            return $true
        }
    }

    # 4. Running process. Last because it is the only signal that goes away when
    # the user simply closes the app; it can confirm presence, never absence.
    if (@(Get-Process -Name 'SonicScout2.0' -ErrorAction SilentlyContinue).Count -gt 0) {
        return $true
    }

    return $false
}

function Uninstall-ExistingEAPO {
    <#
    .SYNOPSIS
        Removes an existing Equalizer APO installation with backup.
    .OUTPUTS
        'Removed' | 'NotFound' | 'Failed'
    #>
    $eapoPath = Join-Path $env:ProgramFiles "EqualizerAPO"
    $eapoUninstall = Join-Path $eapoPath "Uninstall.exe"

    if (-not (Test-Path $eapoPath)) {
        Write-Host "$($script:BoxMargin)No existing E-APO detected, proceeding." -ForegroundColor DarkGray
        return 'NotFound'
    }

    Write-Host "$($script:BoxMargin)Uninstalling E-APO..." -ForegroundColor Red

    # Detection only, and deliberately hoisted above every mutation below so GATE 1
    # can run before the machine has been touched at all.
    $libraryPath = Join-Path $eapoPath "config\SonicScout2.0\library"
    $libraryFiles = @(Get-ChildItem -Path $libraryPath -Recurse -File -ErrorAction SilentlyContinue)

    # -- GATE 1: no backup location at all ----------------------------------
    # Placed HERE, above the process kills, and that placement is load-bearing.
    # Everything from the top of this function to this line is detection: path
    # joins, a Test-Path, a Get-ChildItem. Nothing has been killed, stopped,
    # deleted or written, so declining below leaves the machine exactly as found.
    #
    # One line further down is irreversible. The Stop-Process pair closes the
    # user's audio tools, and the E-APO uninstaller further still deletes
    # config\SonicScout2.0\library outright -- it is the FIRST thing that destroys
    # the library, not the Remove-Item near the end of this function.
    #
    # Every failure state measured for the backup bug fails at root resolution, so
    # this gate catches all of them before any cost is paid.
    $acceptedNoBackup = $false
    if ($libraryFiles.Count -gt 0 -and -not (Get-SonicScout20BackupRoot)) {
        Write-Host ""
        Write-Host "$($script:BoxMargin)No writable backup location could be found." -ForegroundColor Red
        Write-Host "$($script:BoxMargin)Your SonicScout2.0 library ($($libraryFiles.Count) files), including any squig.link" -ForegroundColor Yellow
        Write-Host "$($script:BoxMargin)EQs you added, would be deleted with NO backup and no way to recover it." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "$($script:BoxMargin)Type 'yes' to uninstall anyway, or anything else to cancel: " -ForegroundColor Yellow -NoNewline
        $proceedNoBackup = Read-Host
        if ($proceedNoBackup -ne 'yes') {
            Remove-UnusedBackupRoot
            Write-Host ""
            Write-Host "$($script:BoxMargin)Uninstall cancelled. Nothing on this PC was changed -- no files were" -ForegroundColor Green
            Write-Host "$($script:BoxMargin)removed, no programs were closed, and no settings were altered." -ForegroundColor Green
            return 'Skipped'
        }
        # Consent recorded so GATE 2 does not ask the same question twice. With no
        # root resolvable the backup below is certain to fail, and re-prompting on
        # that failure reads as the script not having heard the answer just given.
        $acceptedNoBackup = $true
    }

    # Kill LEQ Control Panel before device removal -- its COM audio callbacks
    # can crash if a third-party driver (e.g. Elgato) corrupts shared state
    # during audio subsystem destabilization (AccessViolationException).
    Stop-Process -Name "LEQControlPanel" -Force -ErrorAction SilentlyContinue
    Stop-EAPOEcosystemProcesses

    # Back up user data before destroying E-APO folder: the SonicScout2.0 library
    # (dated, so squig.link EQs stay recoverable) AND the full E-APO config.
    # $libraryPath / $libraryFiles came from the detection block above.
    $libraryBackupFailed = $false
    if ($libraryFiles.Count -gt 0) {
        $libraryBackup = Backup-SonicScout20Library
        # -is [bool] rather than -eq $false: a returned path string compared against
        # $false would coerce and could never match, so the guard has to test the
        # type. $null (nothing to back up) is not a failure.
        if ($libraryBackup -is [bool] -and -not $libraryBackup) { $libraryBackupFailed = $true }
    }
    $null = Backup-EAPOConfig

    # -- GATE 2: the backup ran and failed ----------------------------------
    # Reached only when resolution succeeded but the copy itself did not, so gate 1
    # could not have caught it. Still above the Stop-Service pair and well above the
    # E-APO uninstaller, so declining stops the library from being destroyed.
    #
    # This abort is BOUNDED, NOT CLEAN, and the message must not pretend otherwise:
    # the Stop-Process calls above have already closed the user's audio tools and
    # nothing here undoes them. That is why the follow-up names them.
    #
    # Backup-SonicScout20Library verifies its own copy before returning, so the value
    # tested here is already final -- there is no in-flight work behind this prompt.
    if ($libraryBackupFailed -and -not $acceptedNoBackup) {
        Write-Host ""
        Write-Host "$($script:BoxMargin)The library backup FAILED, so there is nothing to restore from." -ForegroundColor Red
        Write-Host "$($script:BoxMargin)Continuing deletes your SonicScout2.0 library ($($libraryFiles.Count) files) and any" -ForegroundColor Yellow
        Write-Host "$($script:BoxMargin)squig.link EQs in it, permanently." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "$($script:BoxMargin)Type 'yes' to uninstall anyway, or anything else to cancel: " -ForegroundColor Yellow -NoNewline
        $proceedFailedBackup = Read-Host
        if ($proceedFailedBackup -ne 'yes') {
            Remove-UnusedBackupRoot
            Write-Host ""
            Write-Host "$($script:BoxMargin)Uninstall cancelled. Your library was NOT deleted." -ForegroundColor Green
            Write-Host "$($script:BoxMargin)Note: LEQ Control Panel, Peace, HeSuVi and the E-APO editor were closed" -ForegroundColor DarkGray
            Write-Host "$($script:BoxMargin)before the backup ran. Nothing else changed -- reopen them as normal." -ForegroundColor DarkGray
            return 'Skipped'
        }
    }

    # Stop audio services first (E-APO hooks into them)
    Stop-Service -Name 'Audiosrv' -Force -ErrorAction SilentlyContinue
    Stop-Service -Name 'AudioEndpointBuilder' -Force -ErrorAction SilentlyContinue

    if (Test-Path $eapoUninstall) {
        try {
            $proc = Start-Process -FilePath $eapoUninstall -ArgumentList '/S', '/NORESTART', "_?=$eapoPath" -PassThru -WindowStyle Hidden
            $null = Write-Wait -Message "Removing E-APO..." -Until { $proc.HasExited } -TimeoutSeconds 30
            if (-not $proc.HasExited) {
                Write-Host "$($script:BoxMargin)Warning: E-APO uninstaller timed out, killing..." -ForegroundColor Yellow
                try { $proc.Kill() } catch { } # Process may have already exited
            }
        } catch {
            Write-Host "$($script:BoxMargin)Warning: E-APO uninstall failed: $_" -ForegroundColor Yellow
        }
        Start-Sleep -Seconds 3
    }

    # Kill stragglers and clean up
    Stop-Process -Name "EqualizerAPO*" -Force -ErrorAction SilentlyContinue
    # Kill audiodg to release file locks on E-APO DLLs -- required for folder deletion
    Stop-Process -Name "audiodg" -Force -ErrorAction SilentlyContinue

    Write-Wait -Message "Cleaning up E-APO files and registry..." -Until {
        Remove-Item $eapoPath -Recurse -Force -ErrorAction SilentlyContinue
        $childApoPath = "HKLM:\SOFTWARE\EqualizerAPO\Child APOs"
        if (Test-Path $childApoPath) {
            Remove-Item $childApoPath -Recurse -Force -ErrorAction SilentlyContinue
        }
        $eapoRegPath = "HKLM:\SOFTWARE\EqualizerAPO"
        if (Test-Path $eapoRegPath) {
            $subkeys = @(Get-ChildItem $eapoRegPath -ErrorAction SilentlyContinue)
            if (-not $subkeys -or $subkeys.Count -eq 0) {
                Remove-Item $eapoRegPath -Force -ErrorAction SilentlyContinue
            }
        }
        $true
    } -TimeoutSeconds 10 | Out-Null

    # Verify folder is actually gone -- uninstaller sometimes leaves remnants
    if (Test-Path $eapoPath) {
        Write-Host "$($script:BoxMargin)E-APO folder survived uninstall, force-removing..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 1
        Remove-Item $eapoPath -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $eapoPath) {
            Write-Host "$($script:BoxMargin)WARNING: Could not fully remove $eapoPath (files may be locked)." -ForegroundColor Yellow
        }
    }

    # -- SonicScout2.0 plugins -------------------------------------------------
    # Deliberately here, and only here. This is inside the window opened by the
    # Stop-Service pair above: Audiosrv and AudioEndpointBuilder are down and
    # audiodg was killed before the E-APO delete, so nothing holds the DLLs.
    # E-APO loads them by absolute path out of a library tune file, never from
    # config.txt, so they outlive the config that referenced them.
    #
    # NOT gated on the E-APO tree delete above succeeding. A locked E-APO folder
    # and a locked plugin folder are separate failures and neither should mask
    # the other. Nothing below can throw or block the Start-Service that follows.
    #
    # ReaPlugs itself is NOT uninstalled -- not here, not anywhere. That is a
    # decision, not an oversight: it is a third-party suite the user may rely on
    # for their own work, and setup only ever adds an SonicScout2.0 subfolder to it.
    # Only that subfolder goes. Same for VSTPlugins, which belongs to the user.
    $pluginDirs = @(
        (Join-Path $env:ProgramFiles "VSTPlugins\SonicScout2.0")
        (Join-Path $env:ProgramFiles "VSTPlugins\ReaPlugs\JS\Effects\SonicScout2.0")
    )
    $presentDirs = @($pluginDirs | Where-Object { Test-Path -LiteralPath $_ })

    if ($presentDirs.Count -gt 0) {
        if (Test-SonicScout20Installed) {
            # DETECT AND SKIP. SonicScout2.0 deploys the same versioned filenames to
            # these same folders, so there is no way to tell whose copy is whose.
            # Deleting here would pull the plugins out from under a working app.
            # Nothing is removed on this branch.
            $script:PluginRemoval.State = 'SkippedSS'
            Write-Host "$($script:BoxMargin)SonicScout2.0 is installed and shares these plugins -- leaving them in place." -ForegroundColor DarkGray
            Write-Host "$($script:BoxMargin)Uninstalling SonicScout2.0 from the app removes them." -ForegroundColor DarkGray
        } else {
            # Same retry idiom as the E-APO tree delete above: the removals run
            # inside the -Until block, so they are retried until the folders are
            # gone or the timeout expires.
            Write-Wait -Message "Removing SonicScout2.0 plugins..." -Until {
                foreach ($pluginDir in $presentDirs) {
                    Remove-Item $pluginDir -Recurse -Force -ErrorAction SilentlyContinue
                }
                @($presentDirs | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0
            } -TimeoutSeconds 10 | Out-Null

            $pluginSurvivors = @($presentDirs | Where-Object { Test-Path -LiteralPath $_ })
            if ($pluginSurvivors.Count -gt 0) {
                $script:PluginRemoval.State       = 'Failed'
                $script:PluginRemoval.FailedPaths = $pluginSurvivors
                Write-Host "$($script:BoxMargin)WARNING: could not remove the SonicScout2.0 plugins:" -ForegroundColor Yellow
                foreach ($pluginDir in $pluginSurvivors) {
                    Write-Host "$($script:BoxMargin)  $pluginDir" -ForegroundColor Yellow
                }
                Write-Host "$($script:BoxMargin)Restart, then re-run setup and choose [4] to finish." -ForegroundColor DarkGray
            } else {
                $script:PluginRemoval.State = 'Removed'
                Write-Host "$($script:BoxMargin)SonicScout2.0 plugins removed." -ForegroundColor Green
            }
        }
    }

    # Restart audio services
    Start-Service -Name 'AudioEndpointBuilder' -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 100
    Start-Service -Name 'Audiosrv' -ErrorAction SilentlyContinue
    $running = Write-Wait -Message "Waiting for Audiosrv" -Until {
        $svc = Get-Service -Name 'Audiosrv' -ErrorAction SilentlyContinue
        $svc -and $svc.Status -eq 'Running'
    } -TimeoutSeconds 15

    if (-not $running) {
        Write-Host "$($script:BoxMargin)Audio services not ready after E-APO uninstall, retrying..." -ForegroundColor Yellow
        Stop-Service -Name 'Audiosrv' -Force -ErrorAction SilentlyContinue
        Stop-Service -Name 'AudioEndpointBuilder' -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Start-Service -Name 'AudioEndpointBuilder' -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
        Start-Service -Name 'Audiosrv' -ErrorAction SilentlyContinue
        $running = Write-Wait -Message "Waiting for Audiosrv (retry)" -Until {
            $svc = Get-Service -Name 'Audiosrv' -ErrorAction SilentlyContinue
            $svc -and $svc.Status -eq 'Running'
        } -TimeoutSeconds 15
    }

    # The retry result used to be discarded, so a permanently dead Audiosrv was
    # reported as a clean uninstall and the only cue was a timeout spinner line
    # already scrolled off screen. The removal DID happen either way, so the
    # return contract is unchanged -- only the message stops claiming a clean
    # finish that did not occur.
    if (-not $running) {
        Write-Host "$($script:BoxMargin)WARNING: Windows Audio did not restart after removing E-APO." -ForegroundColor Yellow
        Write-Host "$($script:BoxMargin)E-APO itself was removed. Restart this PC to get audio back." -ForegroundColor Yellow
    } else {
        Write-Host "$($script:BoxMargin)E-APO uninstalled." -ForegroundColor Green
    }
    return 'Removed'
}

function Get-WaveLinkInfo {
    <#
    .SYNOPSIS
        Detects every installed Elgato Wave Link, across both packaging models.
    .DESCRIPTION
        Wave Link is a mixer this script does not own and cannot install. It is
        NOT a VB-Audio product, so Test-VoicemeeterEdition cannot see it -- yet a
        Wave Link user has the same reason to be spared an unrequested Voicemeeter
        as a Potato user does.

        Elgato CHANGED PACKAGING between major versions, so no single check finds
        both. Wave Link 3 ships as an MSIX/Store app: it is absent from the
        Uninstall registry hive and lives under WindowsApps, not Program Files.
        Wave Link 2 is a classic installer. They coexist happily -- both can be
        installed and running at once.

        Four independent signals, all evaluated (never stop at the first hit):
          1. MSIX/AppX package     -- the ONLY way to see Wave Link 3
          2. Add/Remove Programs   -- Wave Link 2, and carries its version
          3. Install directory     -- WaveLink.exe left by a broken/partial v2 uninstall
          4. Virtual audio devices -- catches an install whose other traces are gone
        Wave Link can be installed WITHOUT its audio driver, so signal 4 must never
        be the only check. Best-effort throughout; fails safe (a miss just means
        Voicemeeter installs as normal, and the user is still asked).
    .OUTPUTS
        Array of pscustomobject @{ Name; Version; Source }
    #>
    # Collect raw (version, source) hits from every signal, then dedupe by the
    # display label at the end. Two signals finding the same major version is
    # normal (v2 has both a registry entry and an install directory).
    $raw = @()

    # 1. MSIX / Store package -- Wave Link 3 exists ONLY here.
    try {
        $pkgs = @(Get-AppxPackage -Name 'Elgato.WaveLink' -ErrorAction SilentlyContinue)
        if ($pkgs.Count -eq 0) {
            $pkgs = @(Get-AppxPackage -ErrorAction SilentlyContinue |
                      Where-Object { Test-OrdinalContains "$($_.Name)" 'WaveLink' })
        }
        foreach ($pkg in $pkgs) {
            $raw += @{ Version = "$($pkg.Version)"; Source = 'MSIX' }
        }
    } catch { } # Appx module unavailable -- other signals still apply

    # 2. Add/Remove Programs -- Wave Link 2 and earlier.
    try {
        foreach ($hive in @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
            "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
        )) {
            foreach ($entry in @(Get-ChildItem -Path $hive -ErrorAction SilentlyContinue |
                                 Where-Object { Test-OrdinalContains "$($_.GetValue('DisplayName'))" 'Wave Link' })) {
                $raw += @{ Version = "$($entry.GetValue('DisplayVersion'))"; Source = 'Registry' }
            }
        }
    } catch { }

    # 3. Install directory -- keyed on WaveLink.exe, NOT on the folder. Elgato's
    # uninstaller leaves the folder tree behind (empty subdirs, Licenses, Firmware),
    # so testing the directory reports a remnant as an install: it made the mixer
    # question appear on a PC with no Wave Link, and it pushed a version-less hit
    # that rendered as a dangling "v". Requiring the exe keeps what this signal is
    # for -- an install whose registry entry is gone but whose files still run --
    # while ignoring leftovers that cannot be launched.
    try {
        foreach ($dir in @(
            (Join-Path $env:ProgramFiles        "Elgato\WaveLink"),
            (Join-Path ${env:ProgramFiles(x86)} "Elgato\WaveLink")
        )) {
            if (-not $dir) { continue }
            $exe = Join-Path $dir "WaveLink.exe"
            if (Test-Path -LiteralPath $exe) {
                $raw += @{ Version = "$((Get-Item $exe).VersionInfo.ProductVersion)"; Source = 'Directory' }
            }
        }
    } catch { }

    # 4. Virtual audio devices -- only present when the driver was installed.
    try {
        $dev = Get-CimInstance Win32_SoundDevice -ErrorAction SilentlyContinue |
            Where-Object {
                (Test-OrdinalContains "$($_.Name)" 'Wave Link') -or
                (Test-OrdinalContains "$($_.Name)" 'Elgato Virtual')
            } |
            Select-Object -First 1
        if ($dev) { $raw += @{ Version = ''; Source = 'AudioDevice' } }
    } catch { }

    # Dedupe by display label (one entry per major version).
    $found = @()
    $seen  = @{}
    foreach ($hit in $raw) {
        $label = "Elgato Wave Link"
        if ($hit.Version -and ($hit.Version -match '^(\d+)')) {
            $label = "Elgato Wave Link $($Matches[1])"
        }
        if ($seen.ContainsKey($label)) { continue }
        $seen[$label] = $true
        $found += [pscustomobject]@{
            Name    = $label
            Version = $hit.Version
            Source  = $hit.Source
        }
    }

    return $found
}

function Get-ExternalAudioPathHints {
    <#
    .SYNOPSIS
        Detects hardware or device names that imply a direct-output / external-DAC path.
    .DESCRIPTION
        Sound Blaster G7 and similar USB DAC devices are a direct-output path and do
        not need the VB-CABLE + Voicemeeter virtual routing chain. When one is found,
        the installer should offer the approved external-device path instead of defaulting
        the user into the virtual-audio route.
    #>
    $hints = @()
    try {
        $devices = @(Get-CimInstance Win32_SoundDevice -ErrorAction SilentlyContinue)
        foreach ($device in $devices) {
            $name = [string]$device.Name
            if (-not $name) { continue }
            $lower = $name.ToLowerInvariant()
            if ($lower -match 'sound blaster' -or
                $lower -match 'creative' -or
                $lower -match 'g7' -or
                $lower -match 'g8' -or
                $lower -match 'g6' -or
                $lower -match 'external dac' -or
                $lower -match 'optical.*dac' -or
                $lower -match 'usb.*dac' -or
                $lower -match 'dac.*optical' -or
                $lower -match 'usb audio' -or
                $lower -match 'dac') {
                $hints += $name
            }
        }
    } catch { }

    return @($hints | Select-Object -Unique)
}

function Get-InstalledMixers {
    <#
    .SYNOPSIS
        Inventory of audio mixers already on this PC that SonicScout2.0 did not install.
    .DESCRIPTION
        Detection decides WHAT TO ASK ABOUT, not whether to skip Voicemeeter. A
        product being installed does not prove the user relies on it -- Wave Link
        in particular is often installed alongside Elgato capture hardware and
        never used as a mixer, sometimes without its audio driver at all.

        Blocking marks a mixer that needs a second, explicit confirmation before
        Voicemeeter Standard is laid on top of it: all Voicemeeter editions share
        one folder, one uninstaller and one audio driver, so installing Standard
        over Banana/Potato can degrade the user's licensed copy. It is a warning
        gate, NOT a refusal -- the user is allowed to overrule it. Wave Link is a
        separate product and never gates.
    .OUTPUTS
        Array of pscustomobject @{ Kind; Name; Blocking }
    #>
    $mixers = @()

    # Only PAID editions gate. Banana/Potato share one folder and one uninstaller
    # with Standard, so laying Standard on top risks the user's licensed copy --
    # worth making them confirm it deliberately, but it is their call. Standard is
    # free and IS the thing we would install, so it never needs the extra warning.
    $vm = Test-VoicemeeterEdition
    if ($vm.Present) {
        $mixers += [pscustomobject]@{
            Kind     = 'Voicemeeter'
            Name     = $vm.Name
            Blocking = $vm.PaidPresent
        }
    }

    # Wave Link versions collapse into ONE question -- the decision is binary, so
    # asking separately about v2 and v3 would be two prompts to settle one thing.
    # Both are named so the user can recognise what was found.
    $wl = @(Get-WaveLinkInfo)
    if ($wl.Count -gt 0) {
        # Only NUMBERED labels become version tokens. Signals 3 and 4 can hit with no
        # readable version, which dedupes to a bare "Elgato Wave Link" -- blindly
        # rewriting that produced the empty token in "v2 and v". Unlabelled hits are
        # dropped from the list rather than printed as a dangling "v".
        $tokens = @($wl | ForEach-Object {
            $ver = Get-OrdinalMatchGroup "$($_.Name)" 'Wave Link\s+(\d+)$'
            if ($ver) { "v$ver" }
        } | Select-Object -Unique)

        if ($tokens.Count -eq 0) {
            $label = "Elgato Wave Link"
        } else {
            if ($tokens.Count -eq 1) {
                $joined = $tokens[0]
            } else {
                $joined = "$(($tokens[0..($tokens.Count - 2)]) -join ', ') and $($tokens[-1])"
            }
            $label = "Elgato Wave Link ($joined installed)"
        }
        $mixers += [pscustomobject]@{
            Kind     = 'WaveLink'
            Name     = $label
            Blocking = $false
        }
    }

    # Plain return, NOT ",$mixers": the comma idiom turns an empty array into a
    # one-element array holding an empty array, so a PC with no mixer would report
    # one and then fault on $mx.Name under StrictMode. Callers wrap in @().
    return $mixers
}

function Get-VoicemeeterFolder {
    <#
    .SYNOPSIS
        Resolves the folder Voicemeeter is actually installed in.
    .DESCRIPTION
        All editions share one folder, but that folder is not guaranteed to be the
        default: the installer honours a custom target and only the uninstall key
        records where it went. Asking the registry first means the exe probes in
        Test-VoicemeeterEdition look at the real install rather than a path we
        assumed, so "the exe is missing" means missing, not merely elsewhere.

        Every registry read is best-effort. InstallLocation and UninstallString are
        both optional values, and under StrictMode reading an absent property
        faults, so each is checked via PSObject.Properties before use.
    .OUTPUTS
        String path. Never null -- falls back to the x86 default.
    #>
    $vmRegKey = "VB:Voicemeeter {17359A74-1236-5467}"
    $regPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$vmRegKey",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$vmRegKey"
    )

    foreach ($rp in $regPaths) {
        $props = Get-ItemProperty -LiteralPath $rp -ErrorAction SilentlyContinue
        if (-not $props) { continue }

        if ($props.PSObject.Properties['InstallLocation']) {
            $loc = "$($props.InstallLocation)".Trim().Trim('"')
            if ($loc -and (Test-Path -LiteralPath $loc -PathType Container)) { return $loc }
        }

        # UninstallString points at the setup exe INSIDE the install folder, so the
        # parent is the answer. Capture up to the first ".exe" to drop both the
        # surrounding quotes and any trailing switches (VB-Audio writes "... -u -h").
        if ($props.PSObject.Properties['UninstallString']) {
            $exe = Get-OrdinalMatchGroup "$($props.UninstallString)" '^\s*"?(.+?\.exe)'
            if ($exe) {
                $parent = Split-Path -Parent $exe
                if ($parent -and (Test-Path -LiteralPath $parent -PathType Container)) { return $parent }
            }
        }
    }

    # No usable registry hint. Prefer whichever default exists -- Invoke-FreshStart
    # treats the same pair as real locations when it cleans up.
    $defaults = @(
        (Join-Path "${env:ProgramFiles(x86)}" "VB\Voicemeeter"),
        (Join-Path "$env:ProgramFiles" "VB\Voicemeeter")
    )
    foreach ($d in $defaults) {
        if (Test-Path -LiteralPath $d -PathType Container) { return $d }
    }
    return $defaults[0]
}

function Test-VoicemeeterEdition {
    <#
    .SYNOPSIS
        Detects which Voicemeeter edition(s) are installed.
    .DESCRIPTION
        All editions share one folder (see Get-VoicemeeterFolder) and are told
        apart by their exe name. This script ONLY ever installs Standard (see
        $script:VoicemeeterUrlResolver), so the edition doubles as provenance:
        Banana or Potato present means the user installed it themselves.

        Two different notions of "installed" come out of this, and callers must
        pick the right one:

          Present    registry OR disk. Use for REMOVAL decisions -- a leftover
                     uninstall key with no exe still needs cleaning up.
          ExePresent disk only. Use for INSTALL decisions -- a leftover key is not
                     a working mixer, and skipping the install because of one
                     leaves the user with nothing.
          Standard   disk only, Standard specifically. The exact gate for "we
                     already have the thing we were about to install".
    .OUTPUTS
        pscustomobject @{ Present; ExePresent; Standard; Banana; Potato;
                          PaidPresent; Name; Folder; StandardExe }
    #>
    $vmFolder = Get-VoicemeeterFolder

    # Edition comes from the exe names (all editions share one folder).
    $standardExe = Join-Path $vmFolder "voicemeeter.exe"
    $standard = Test-Path -LiteralPath $standardExe
    $banana   = Test-Path -LiteralPath (Join-Path $vmFolder "voicemeeterpro.exe")
    $potato   = Test-Path -LiteralPath (Join-Path $vmFolder "voicemeeter8.exe")

    # PRESENCE also accepts the uninstall registry key -- the same signal
    # Uninstall-ExistingVoicemeeter and Add/Remove Programs use. A file-path check
    # alone would miss a non-default install location and wrongly conclude nothing
    # is installed, which is how the original VB-CABLE bug worked.
    $vmRegKey = "VB:Voicemeeter {17359A74-1236-5467}"
    $hasRegEntry = [bool](@(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$vmRegKey",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$vmRegKey"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1)

    # Name the most advanced edition present -- that is the one the user cares
    # about and the one whose uninstaller would run.
    $name = $null
    if ($potato)       { $name = "Voicemeeter Potato" }
    elseif ($banana)   { $name = "Voicemeeter Banana" }
    elseif ($standard) { $name = "Voicemeeter" }
    elseif ($hasRegEntry) { $name = "Voicemeeter" }   # registered, exe elsewhere

    return [pscustomobject]@{
        Present     = ($standard -or $banana -or $potato -or $hasRegEntry)
        ExePresent  = ($standard -or $banana -or $potato)
        Standard    = $standard
        Banana      = $banana
        Potato      = $potato
        PaidPresent = ($banana -or $potato)
        Name        = $name
        Folder      = $vmFolder
        StandardExe = $(if ($standard) { $standardExe } else { $null })
    }
}

function Uninstall-ExistingHiFiCable {
    <#
    .SYNOPSIS
        Removes the Hi-Fi Cable virtual audio driver and registry entries.
    #>
    # Primary detection: check uninstall registry keys (what Add/Remove Programs uses)
    $hifiRegKeys = $script:HiFiCableRegistryKeys
    $hasRegEntry = $hifiRegKeys | Where-Object { Test-Path $_ } | Select-Object -First 1

    # Fallback: check for audio devices
    $hasDevice = Get-CimInstance Win32_SoundDevice -ErrorAction SilentlyContinue |
        Where-Object {
            (Test-OrdinalContains "$($_.Name)" 'Hi-Fi') -or
            (Test-OrdinalContains "$($_.Name)" 'HiFi')
        }

    if (-not $hasRegEntry -and -not $hasDevice) {
        return 'NotFound'
    }

    # Find installer for uninstall (leftover setup EXEs are fine to use)
    $hifiPaths = @(
        "C:\Program Files (x86)\VB\ASIOBridge\HiFiCableAsioBridgeSetup.exe",
        "C:\Program Files\VB\CABLEHiFi\VBCABLE_Setup_x64.exe",
        "C:\Program Files\VB\CABLE\VBHIFI_Setup_x64.exe",
        "C:\Program Files (x86)\VB\CABLE\VBHIFI_Setup.exe"
    )
    $installer = $hifiPaths | Where-Object { Test-Path $_ } | Select-Object -First 1

    Write-Host "$($script:BoxMargin)Uninstalling Hi-Fi Cable..." -ForegroundColor Red

    if ($installer) {
        try {
            $proc = Start-Process -FilePath $installer -ArgumentList "-u -h" -PassThru -WindowStyle Hidden
            $null = Write-Wait -Message "Removing Hi-Fi Cable driver..." -Until { $proc.HasExited } -TimeoutSeconds 30
            if (-not $proc.HasExited) {
                Write-Host "$($script:BoxMargin)Warning: Hi-Fi Cable uninstaller timed out." -ForegroundColor Yellow
                try { $proc.Kill() } catch { } # Process may have already exited
            }
        } catch {
            Write-Host "$($script:BoxMargin)Warning: Hi-Fi Cable uninstall failed: $_" -ForegroundColor Yellow
        }
        Start-Sleep -Seconds 2
    }

    # Clean up files and registry
    Write-Wait -Message "Cleaning up Hi-Fi Cable files and registry..." -Until {
        # Hi-Fi-EXCLUSIVE folders: safe to remove whole.
        $hifiFolders = @(
            "C:\Program Files (x86)\VB\ASIOBridge",
            "C:\Program Files\VB\CABLEHiFi"
        )
        foreach ($folder in $hifiFolders) {
            if (Test-Path $folder) { Remove-Item -Path $folder -Recurse -Force -ErrorAction SilentlyContinue }
        }

        # SHARED with VB-CABLE -- Hi-Fi's setup exe can live here, but so does
        # VB-CABLE's own uninstaller (see Uninstall-ExistingVBCable). Removing the
        # directory would destroy VB-CABLE's only removal path. Delete Hi-Fi's own
        # files here, never the folder.
        $sharedFolders = @(
            "C:\Program Files\VB\CABLE",
            "C:\Program Files (x86)\VB\CABLE"
        )
        foreach ($folder in $sharedFolders) {
            if (-not (Test-Path $folder)) { continue }
            Get-ChildItem -Path $folder -Filter "VBHIFI_Setup*.exe" -ErrorAction SilentlyContinue |
                ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
        }
        $hifiRegKeys = $script:HiFiCableRegistryKeys
        foreach ($regKey in $hifiRegKeys) {
            if (Test-Path $regKey) { Remove-Item -Path $regKey -Force -ErrorAction SilentlyContinue }
        }
        $uninstallHives = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
        )
        foreach ($hive in $uninstallHives) {
            try {
                Get-ChildItem -Path $hive -ErrorAction SilentlyContinue |
                    Where-Object { Test-OrdinalMatch "$($_.Name)" 'VB:HiFi|Hi-Fi Cable|HiFiCable|VB:ASIOBridge|ASIO Bridge' } |
                    ForEach-Object { Remove-Item -Path $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue }
            } catch { } # Registry cleanup is best-effort; leftover keys are harmless
        }
        $true
    } -TimeoutSeconds 10 | Out-Null

    # Clean up empty parent VB directories (only if nothing else remains, e.g. Voicemeeter)
    foreach ($vbParent in @("C:\Program Files\VB", "C:\Program Files (x86)\VB")) {
        if ((Test-Path $vbParent) -and
            @(Get-ChildItem -Path $vbParent -ErrorAction SilentlyContinue).Count -eq 0) {
            Remove-Item -Path $vbParent -Force -ErrorAction SilentlyContinue
        }
    }

    # -- Nuclear cleanup: purge Hi-Fi Cable driver packages from the driver store --
    Write-Wait -Message "Purging Hi-Fi Cable from driver store..." -Until {
        try {
            # ONE predicate, used by both the per-block and the trailing-block path.
            # They were duplicated inline before; keeping two copies of a delete rule in
            # step by hand is exactly how a guard drifts. Culture-invariant throughout:
            # pnputil emits uppercase (OEM12.INF, VB-AUDIO), and under tr-TR raw -match
            # would fail every one of these -- silently no-opping the whole purge.
            #
            # The gate is an AND of two POSITIVE conditions, so a match failure can only
            # ever skip a delete, never widen one.
            $purgeBlock = {
                param($text)
                $oemInf = Get-OrdinalMatchGroup $text '(oem\d+\.inf)'
                if (-not $oemInf) { return }
                if ((Test-OrdinalMatch $text 'VB-Audio') -and
                    (Test-OrdinalMatch $text 'hifi|hi-fi|hfvaio|hfcable')) {
                    & pnputil /delete-driver $oemInf /force 2>&1 | Out-Null
                }
            }

            $pnpRaw = & pnputil /enum-drivers 2>&1
            # Split into per-driver blocks (separated by blank lines).
            # Field names are localized, but oem*.inf and product strings are not.
            $blockText = ""
            foreach ($line in $pnpRaw) {
                $trimmed = "$line".Trim()
                if ($trimmed -eq '' -and $blockText.Length -gt 0) {
                    & $purgeBlock $blockText
                    $blockText = ""
                    continue
                }
                $blockText += " $trimmed"
            }
            # Handle last block (no trailing blank line)
            if ($blockText.Length -gt 0) { & $purgeBlock $blockText }
        } catch { } # Best-effort; pnputil errors are non-fatal
        $true
    } -TimeoutSeconds 15 | Out-Null

    # -- Nuclear cleanup: remove phantom/ghost Hi-Fi Cable devices --
    Write-Wait -Message "Removing phantom Hi-Fi Cable devices..." -Until {
        try {
            $hifiDevices = Get-PnpDevice -ErrorAction SilentlyContinue |
                Where-Object {
                    # The Voicemeeter exclusion is the one NEGATIVE test in the Hi-Fi lane,
                    # so it is the one that fails OPEN when matching breaks. Culture-invariant
                    # here is what keeps it excluding on a tr-TR box.
                    ($_.Status -eq 'Error' -or $_.Status -eq 'Unknown') -and
                    (Test-OrdinalMatch "$($_.FriendlyName)" 'Hi-?Fi|HiFi') -and
                    -not (Test-OrdinalMatch "$($_.FriendlyName)" 'Voicemeeter')
                }
            foreach ($dev in $hifiDevices) {
                & pnputil /remove-device $dev.InstanceId 2>&1 | Out-Null
            }
        } catch { } # Best-effort
        $true
    } -TimeoutSeconds 15 | Out-Null

    # -- Nuclear cleanup: remove residual driver binaries from System32/SysWOW64 --
    # Patterns are HiFi-Cable-specific; Voicemeeter uses vbaudio_vmvaio*/vbvmaux*
    $hifiFilePatterns = @('vbaudio_hfvaio64*', 'vbaudio_hfcable*', 'vbhifi*')
    $systemDirs = @(
        (Join-Path $env:SystemRoot 'System32'),
        (Join-Path $env:SystemRoot 'System32\drivers'),
        (Join-Path $env:SystemRoot 'SysWOW64')
    )
    foreach ($dir in $systemDirs) {
        foreach ($pattern in $hifiFilePatterns) {
            Get-ChildItem -Path $dir -Filter $pattern -ErrorAction SilentlyContinue |
                ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
        }
    }

    # -- Conditional: remove VB-Audio certificate if no other VB-Audio products remain --
    # Must consider ALL Voicemeeter editions, not just Standard: a Potato-only box
    # has no voicemeeter.exe, and stripping the trusted-publisher cert there would
    # be wrong. VB-CABLE counts too -- it is a VB-Audio product using the same cert.
    $vmAny = (Test-VoicemeeterEdition).Present
    $vbCableEps = Get-SonicScout20Endpoints
    $vbCableAny = [bool]($vbCableEps.Render8 -or $vbCableEps.Render16 -or $vbCableEps.Capture)
    if (-not $vmAny -and -not $vbCableAny) {
        try {
            $thumbprint = '00859AAC6A54B8C1B3C139DE67846E64E7B82DB2'
            $store = [System.Security.Cryptography.X509Certificates.X509Store]::new(
                'TrustedPublisher', 'LocalMachine')
            $store.Open('ReadWrite')
            $certs = $store.Certificates.Find(
                [System.Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,
                $thumbprint, $false)
            foreach ($c in $certs) { $store.Remove($c) }
            $store.Close()
        } catch { } # Best-effort
    }

    # Let Windows reconcile the device tree so cleanup is visible immediately
    & pnputil /scan-devices 2>&1 | Out-Null

    # Verify rather than assume. The cleanup above is thorough (registry, files,
    # driver store, phantom devices) but not guaranteed -- reporting success when
    # the device survives is what let earlier removal bugs stay invisible.
    # Culture-invariant deliberately: this is the verification, and it is reached via
    # the literal-path registry detection above, which is culture-proof. A locale that
    # broke this match would report 'Removed' for a driver still installed.
    $stillThere = Get-CimInstance Win32_SoundDevice -ErrorAction SilentlyContinue |
        Where-Object {
            (Test-OrdinalContains "$($_.Name)" 'Hi-Fi') -or
            (Test-OrdinalContains "$($_.Name)" 'HiFi')
        }
    if ($stillThere) {
        Write-Host "$($script:BoxMargin)Hi-Fi Cable is still present after removal." -ForegroundColor Yellow
        Write-Host "$($script:BoxMargin)A restart usually clears it. If it persists, remove" -ForegroundColor Yellow
        Write-Host "$($script:BoxMargin)'VB-Audio Hi-Fi Cable' from Device Manager." -ForegroundColor DarkGray
        return 'Failed'
    }

    Write-Host "$($script:BoxMargin)Hi-Fi Cable uninstalled." -ForegroundColor Green
    return 'Removed'
}

function Uninstall-ExistingVBCable {
    <#
    .SYNOPSIS
        Removes VB-CABLE via its own silent uninstaller (-u -h). Simple pattern:
        official uninstall first, then removes any remaining VB-CABLE PnP devices.
        The latter is required because the official uninstaller can leave a stale
        ROOT\MEDIA device visible in the Sound control panel.
    .OUTPUTS
        'Removed'  - the uninstaller ran
        'NotFound' - VB-CABLE is not present
        'Failed'   - present, but it could not be removed (no uninstaller on disk,
                     or the uninstaller errored). NEVER reported as success: the
                     caller must surface the manual remedy.
    #>
    # Detection: the endpoints resolve (Get-SonicScout20Endpoints is strict about
    # 'VB-Audio Virtual Cable', so the retired Hi-Fi Cable cannot false-positive
    # here), or VB-CABLE's own setup exe is still on disk.
    $eps = Get-SonicScout20Endpoints
    $hasEndpoints = [bool]($eps.Render8 -or $eps.Render16 -or $eps.Capture)

    # Locate the installed VB-CABLE setup exe (fixed install location)
    $vbCablePaths = @(
        "C:\Program Files\VB\CABLE\VBCABLE_Setup_x64.exe",
        "C:\Program Files (x86)\VB\CABLE\VBCABLE_Setup_x64.exe",
        "C:\Program Files\VB\CABLE\VBCABLE_Setup.exe"
    )
    $installer = $vbCablePaths | Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not $hasEndpoints -and -not $installer) {
        return 'NotFound'
    }

    Write-Host "$($script:BoxMargin)Uninstalling VB-CABLE..." -ForegroundColor Red

    $ok = $true
    if ($installer) {
        try {
            $proc = Start-Process -FilePath $installer -ArgumentList "-u -h" -PassThru -WindowStyle Hidden
            $null = Write-Wait -Message "Removing VB-CABLE driver..." -Until { $proc.HasExited } -TimeoutSeconds 30
            if (-not $proc.HasExited) {
                Write-Host "$($script:BoxMargin)Warning: VB-CABLE uninstaller timed out." -ForegroundColor Yellow
                try { $proc.Kill() } catch { } # Process may have already exited
                $ok = $false
            }
        } catch {
            Write-Host "$($script:BoxMargin)Warning: VB-CABLE uninstall failed: $_" -ForegroundColor Yellow
            $ok = $false
        }
    } else {
        Write-Host "$($script:BoxMargin)VB-CABLE setup exe not found; removing its remaining device records." -ForegroundColor Yellow
    }
    Start-Sleep -Seconds 2

    # The VB-Audio uninstaller may remove the package but leave ROOT\MEDIA
    # endpoints registered. Remove those device nodes so they disappear from
    # Playback/Recording instead of remaining as stale disconnected entries.
    $remainingDevices = @(Get-CimInstance Win32_SoundDevice -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'VB-Audio Virtual Cable' })
    foreach ($device in $remainingDevices) {
        if ([string]::IsNullOrWhiteSpace($device.PNPDeviceID)) { $ok = $false; continue }
        try {
            & pnputil.exe /remove-device "$($device.PNPDeviceID)" /subtree | Out-Null
            if ($LASTEXITCODE -ne 0) { $ok = $false }
        } catch { $ok = $false }
    }
    Start-Sleep -Seconds 2
    $stillThere = @(Get-CimInstance Win32_SoundDevice -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'VB-Audio Virtual Cable' })
    if ($stillThere.Count -gt 0) {
        Write-Host "$($script:BoxMargin)VB-CABLE is still present after removal." -ForegroundColor Yellow
        Write-Host "$($script:BoxMargin)Restart, then run [4] Uninstall again if it remains visible." -ForegroundColor DarkGray
        return 'Failed'
    }
    if (-not $ok) { return 'Failed' }

    Write-Host "$($script:BoxMargin)VB-CABLE removal complete." -ForegroundColor Green
    return 'Removed'
}

function Uninstall-ExistingVoicemeeter {
    <#
    .SYNOPSIS
        Removes Voicemeeter, its drivers, auto-start entries, and user data.
    .DESCRIPTION
        REFUSES to run when Banana or Potato is present. All editions share one
        folder and the uninstaller selection below prefers the most advanced one,
        so there is no way to surgically remove only the Standard copy this script
        installs -- the attempt would delete the user's own paid edition instead.
    .OUTPUTS
        'Removed' | 'NotFound' | 'Skipped' | 'Failed'
    #>
    $vmFolder = "${env:ProgramFiles(x86)}\VB\Voicemeeter"

    # Primary detection: check uninstall registry key (what Add/Remove Programs uses)
    $vmRegKey = "VB:Voicemeeter {17359A74-1236-5467}"
    $vmRegPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$vmRegKey",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$vmRegKey"
    )
    $hasRegEntry = $vmRegPaths | Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not $hasRegEntry) {
        return 'NotFound'
    }

    # Paid editions are never ours -- this script only installs Standard.
    $vm = Test-VoicemeeterEdition
    if ($vm.PaidPresent) {
        Write-Host "$($script:BoxMargin)$($vm.Name) detected -- leaving it alone." -ForegroundColor DarkGray
        Write-Host "$($script:BoxMargin)SonicScout2.0 does not install it, and the shared uninstaller would" -ForegroundColor DarkGray
        Write-Host "$($script:BoxMargin)remove your licensed edition. Use Add/Remove Programs if you" -ForegroundColor DarkGray
        Write-Host "$($script:BoxMargin)really want it gone." -ForegroundColor DarkGray
        return 'Skipped'
    }

    Write-Host "$($script:BoxMargin)Uninstalling Voicemeeter..." -ForegroundColor Red

    # Select the uninstaller. Only Standard can reach here (paid editions returned
    # 'Skipped' above), but keep the variant probes so the selection stays correct
    # if that guard is ever relaxed.
    $hasPotato = $vm.Potato
    $hasBanana = $vm.Banana

    $vmSetupPath = $null
    if ($hasPotato) {
        $candidate = Join-Path $vmFolder "Voicemeeter8Setup.exe"
        if (Test-Path $candidate) { $vmSetupPath = $candidate }
    }
    if (-not $vmSetupPath -and $hasBanana) {
        $candidate = Join-Path $vmFolder "VoicemeeterProSetup.exe"
        if (Test-Path $candidate) { $vmSetupPath = $candidate }
    }
    if (-not $vmSetupPath) {
        $candidate = Join-Path $vmFolder "voicemeetersetup.exe"
        if (Test-Path $candidate) { $vmSetupPath = $candidate }
    }

    # Step 1: Kill processes that hold audio handles
    Stop-AudioHoldingProcesses

    # Step 2: Run official uninstaller
    if ($vmSetupPath) {
        try {
            $proc = Start-Process -FilePath $vmSetupPath -ArgumentList "-u -h" -PassThru -WindowStyle Hidden
            $null = Write-Wait -Message "Removing Voicemeeter driver..." -Until { $proc.HasExited } -TimeoutSeconds 30
            if (-not $proc.HasExited) {
                try { $proc.Kill() } catch { } # Process may have already exited
            }
        } catch {
            Write-Host "$($script:BoxMargin)Warning: Voicemeeter uninstall failed: $_" -ForegroundColor Yellow
        }

        # Poll for registry key removal
        Write-Wait -Message "Waiting for Voicemeeter uninstaller to finish..." -Until {
            $regGone = $true
            foreach ($rp in $vmRegPaths) {
                if (Test-Path $rp) { $regGone = $false; break }
            }
            $regGone
        } -TimeoutSeconds 15 | Out-Null
    }

    # Clean up files, registry, and user data
    Write-Wait -Message "Cleaning up Voicemeeter files and registry..." -Until {
        # Force-delete install folders
        @("${env:ProgramFiles(x86)}\VB\Voicemeeter", "${env:ProgramFiles}\VB\Voicemeeter") | ForEach-Object {
            if (Test-Path $_) { Remove-Item $_ -Recurse -Force -ErrorAction SilentlyContinue }
        }

        # Clean auto-start
        $startupFolder = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup"
        @("Voicemeeter.lnk","VoicemeeterPro.lnk","Voicemeeter8.lnk") | ForEach-Object {
            $lnk = Join-Path $startupFolder $_
            if (Test-Path $lnk) { Remove-Item $lnk -Force -ErrorAction SilentlyContinue }
        }
        $runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
        @("VoiceMeeter","VoiceMeeterPro","VoiceMeeter8") | ForEach-Object {
            Remove-ItemProperty -Path $runKey -Name $_ -ErrorAction SilentlyContinue
        }

        # Clean HKCU registry
        @("HKCU:\VB-Audio","HKCU:\Software\VB-Audio") | ForEach-Object {
            if (Test-Path $_) { Remove-Item $_ -Recurse -Force -ErrorAction SilentlyContinue }
        }

        # Clean HKLM uninstall
        foreach ($rp in $vmRegPaths) {
            if (Test-Path $rp) { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
        }
        $uninstallHives = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
        )
        foreach ($hive in $uninstallHives) {
            try {
                Get-ChildItem -Path $hive -ErrorAction SilentlyContinue |
                    Where-Object { Test-OrdinalMatch "$($_.Name)" 'VB:Voicemeeter|Voicemeeter' } |
                    ForEach-Object { Remove-Item -Path $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue }
            } catch { } # Registry cleanup is best-effort; leftover keys are harmless
        }

        # Clean user data
        $vmDocs = Join-Path $env:USERPROFILE "Documents\Voicemeeter"
        if (Test-Path $vmDocs) { Remove-Item $vmDocs -Recurse -Force -ErrorAction SilentlyContinue }
        $vmXml = Join-Path $env:APPDATA "VoiceMeeterDefault.xml"
        if (Test-Path $vmXml) { Remove-Item $vmXml -Force -ErrorAction SilentlyContinue }
        $true
    } -TimeoutSeconds 15 | Out-Null

    Write-Host "$($script:BoxMargin)Voicemeeter uninstalled." -ForegroundColor Green
    return 'Removed'
}

function New-ContinueSetupShortcut {
    <#
    .SYNOPSIS
        Drops a "Continue SonicScout2.0 Setup" shortcut on the desktop before a reboot.
    .DESCRIPTION
        The script is delivered via 'irm ... | iex' and never persists, so after a
        restart the user has nothing to run. This is a bookmark, NOT auto-resume:
        no scheduled task, no state file, no persisted script. It just re-launches
        the same one-liner elevated.
    .OUTPUTS
        Shortcut path, or $null on failure (non-fatal).
    #>
    try {
        $desktop  = [Environment]::GetFolderPath('Desktop')
        $lnkPath  = Join-Path $desktop "Continue SonicScout2.0 Setup.lnk"
        $command  = "irm https://raw.githubusercontent.com/sensoredrooster/SonicScout2.0/main/powershell/Install-SonicScout2.0.ps1 | iex"
        $encoded  = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))

        $shell = New-Object -ComObject WScript.Shell
        $lnk = $shell.CreateShortcut($lnkPath)
        $lnk.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $lnk.Arguments  = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
        $lnk.IconLocation = "$env:SystemRoot\System32\shell32.dll,165"
        $lnk.Description  = "Finish installing the SonicScout2.0 audio stack"
        $lnk.Save()

        # Mark it run-as-administrator (byte 21 of the link flags block).
        $bytes = [System.IO.File]::ReadAllBytes($lnkPath)
        $bytes[21] = $bytes[21] -bor 0x20
        [System.IO.File]::WriteAllBytes($lnkPath, $bytes)

        return $lnkPath
    } catch {
        # Non-fatal: the on-screen command is still shown.
        return $null
    }
}

function Remove-SonicScout20DesktopShortcuts {
    <#
    .SYNOPSIS
        Deletes the desktop icons setup created (uninstall-everything only).
    .DESCRIPTION
        Both icons are SonicScout2.0's own and neither outlives a full uninstall as
        anything but a dead shortcut: SonicScout2.0.lnk targets the E-APO config tree
        the wipe destroys, and "Continue SonicScout2.0 Setup" is a leftover bookmark
        from a [2] Start Clean run that has nothing left to continue.

        The all-users desktop is swept alongside the current one. Setup only ever
        writes to the per-user desktop, but a copy dragged there by hand is still
        an SonicScout2.0 icon the user expects gone.
    .OUTPUTS
        pscustomobject @{ Removed; Failed } -- display names / full paths.
    #>
    $shortcuts = @(
        @{ File = "SonicScout2.0.lnk";              Name = "SonicScout2.0 desktop icon" }
        @{ File = "Continue SonicScout2.0 Setup.lnk"; Name = "Continue SonicScout2.0 Setup icon" }
    )
    $desktops = @(
        [Environment]::GetFolderPath('Desktop')
        [Environment]::GetFolderPath('CommonDesktopDirectory')
    ) | Where-Object { $_ } | Select-Object -Unique

    $removed = @(); $failed = @()
    foreach ($desktop in $desktops) {
        foreach ($sc in $shortcuts) {
            $lnk = Join-Path $desktop $sc.File
            if (-not (Test-Path -LiteralPath $lnk)) { continue }
            # A read-only/hidden .lnk survives a plain Remove-Item, and
            # -ErrorAction SilentlyContinue would report that as a success. Clear
            # the attributes first, then confirm the file is actually gone.
            try {
                (Get-Item -LiteralPath $lnk -Force).Attributes = [System.IO.FileAttributes]::Normal
            } catch { }   # Best effort -- the delete below is the real test
            Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $lnk) { $failed += $lnk } else { $removed += $sc.Name }
        }
    }

    return [pscustomobject]@{
        Removed = @($removed | Select-Object -Unique)
        Failed  = @($failed)
    }
}

function Invoke-FreshStart {
    <#
    .SYNOPSIS
        Uninstalls the SonicScout2.0 audio stack in order.
    .DESCRIPTION
        Voicemeeter is NOT part of the wipe. A clean SonicScout2.0 install has no
        business deleting the user's mixer, and the paid editions are never ours.
        The uninstall-everything flow opts in explicitly via -IncludeVoicemeeter.
    .PARAMETER PromptRestart
        If true, prompts user to restart after uninstalling (default: true).
    .PARAMETER IncludeVoicemeeter
        Also attempt Voicemeeter removal. Paid editions are still refused inside
        Uninstall-ExistingVoicemeeter.
    .OUTPUTS
        pscustomobject @{ Removed; Failed; Skipped } -- arrays of component names.
    #>
    param(
        [bool]$PromptRestart = $true,
        [switch]$IncludeVoicemeeter
    )

    Write-Host ""
    Write-Host "$($script:BoxMargin)Removing the existing audio stack..." -ForegroundColor Red

    # Kill LEQ Control Panel before device removal -- its COM audio callbacks
    # can crash if a third-party driver (e.g. Elgato) corrupts shared state
    # during audio subsystem destabilization (AccessViolationException).
    Stop-Process -Name "LEQControlPanel" -Force -ErrorAction SilentlyContinue
    Stop-EAPOEcosystemProcesses

    # Detect what's installed before doing anything
    $hasEapo = Test-Path (Join-Path $env:ProgramFiles "EqualizerAPO")
    $hasHifi = ($script:HiFiCableRegistryKeys | Where-Object { Test-Path $_ } | Select-Object -First 1) -or
        (Get-CimInstance Win32_SoundDevice -ErrorAction SilentlyContinue |
            Where-Object {
                (Test-OrdinalContains "$($_.Name)" 'Hi-Fi') -or
                (Test-OrdinalContains "$($_.Name)" 'HiFi')
            })
    $hasVm = $false
    if ($IncludeVoicemeeter) {
        $hasVm = (Test-VoicemeeterEdition).Present
    }
    # VB-CABLE: positive endpoint check. A name match on *VB-Audio* would also
    # match the retired Hi-Fi Cable and claim VB-CABLE was present when it is not.
    $vbEps = Get-SonicScout20Endpoints
    $hasVbCable = [bool]($vbEps.Render8 -or $vbEps.Render16 -or $vbEps.Capture)

    if (-not $hasEapo -and -not $hasHifi -and -not $hasVm -and -not $hasVbCable) {
        Write-Host "$($script:BoxMargin)Nothing to remove -- this PC is already clean." -ForegroundColor Green
        Write-Host "$($script:BoxMargin)Choose [1] Install to set up the audio stack." -ForegroundColor DarkGray
        return [pscustomobject]@{ Removed = @(); Failed = @(); Skipped = @() }
    }

    Write-Host ""
    $toRemove = @()
    if ($hasVbCable) { $toRemove += "VB-CABLE" }
    if ($hasHifi)    { $toRemove += "Hi-Fi Cable" }
    if ($hasEapo)    { $toRemove += "E-APO + HeSuVi" }
    if ($hasVm)      { $toRemove += "Voicemeeter" }
    Write-Host "$($script:BoxMargin)This will remove: $($toRemove -join ', ')" -ForegroundColor Yellow
    Write-Host "$($script:BoxMargin)Your E-APO config and SonicScout2.0 library (including any squig.link EQs)" -ForegroundColor Yellow
    Write-Host "$($script:BoxMargin)are backed up first to Documents\SonicScout2.0 Backups\." -ForegroundColor Yellow
    Write-Host "$($script:BoxMargin)A restart afterward finishes clearing the drivers." -ForegroundColor Yellow
    Write-Host ""

    # Order matters: Hi-Fi cleanup used to delete VB-CABLE's directory (and with it
    # VB-CABLE's only uninstaller). That is fixed in Uninstall-ExistingHiFiCable,
    # but removing VB-CABLE first keeps the dependency out of the ordering entirely.
    $removed = @(); $failed = @(); $skipped = @()
    $steps = @(
        @{ Name = "VB-CABLE";       Action = { Uninstall-ExistingVBCable } }
        @{ Name = "Hi-Fi Cable";    Action = { Uninstall-ExistingHiFiCable } }
        @{ Name = "E-APO + HeSuVi"; Action = { Uninstall-ExistingEAPO } }
    )
    if ($IncludeVoicemeeter) {
        $steps += @{ Name = "Voicemeeter"; Action = { Uninstall-ExistingVoicemeeter } }
    }
    foreach ($step in $steps) {
        switch (& $step.Action) {
            'Removed' { $removed += $step.Name }
            'Failed'  { $failed  += $step.Name }
            'Skipped' { $skipped += $step.Name }
            default   { }   # NotFound -- nothing to report
        }
    }

    $endpointCleanup = Clear-SonicScout20EndpointBranding
    if ($endpointCleanup.Changed -gt 0) { $removed += "SonicScout2.0 audio endpoint names" }
    if ($endpointCleanup.Failed -gt 0)  { $failed  += "SonicScout2.0 audio endpoint names" }

    if ($failed.Count -gt 0) {
        Write-Host ""
        Write-Host "$($script:BoxMargin)Could not remove: $($failed -join ', ')" -ForegroundColor Yellow
        Write-Host "$($script:BoxMargin)A restart clears most leftovers. If one persists, remove it from" -ForegroundColor Yellow
        Write-Host "$($script:BoxMargin)Device Manager or Add/Remove Programs before running Install." -ForegroundColor DarkGray
    }

    if ($removed.Count -gt 0) {
        if ($PromptRestart) {
            Write-Host ""
            Write-Host "$($script:BoxMargin)Removed: $($removed -join ', ')" -ForegroundColor Green
            Write-Host ""
            Write-Host "$($script:BoxMargin)Your old config and library were backed up to Documents\SonicScout2.0 Backups\." -ForegroundColor DarkGray
            Write-Host "$($script:BoxMargin)Old squig.link combos are recoverable there via the SonicScout2.0 desktop shortcut." -ForegroundColor DarkGray
            Write-Host ""
            Write-Host "$($script:BoxMargin)A restart is required to finish removing drivers." -ForegroundColor Yellow
            Write-Host "$($script:BoxMargin)After restarting, re-run this script and choose [1] Install:" -ForegroundColor Yellow
            Write-Host "$($script:BoxMargin)  irm https://raw.githubusercontent.com/sensoredrooster/SonicScout2.0/main/powershell/Install-SonicScout2.0.ps1 | iex" -ForegroundColor Cyan
            Write-Host "$($script:BoxMargin)(a 'Continue SonicScout2.0 Setup' shortcut has been placed on your desktop)." -ForegroundColor DarkGray
            $null = New-ContinueSetupShortcut
            Write-Host ""
            Write-Host "$($script:BoxMargin)Restart now? [Y/n]: " -ForegroundColor Yellow -NoNewline
            $restart = Read-Host
            if ($restart -eq 'n' -or $restart -eq 'N') {
                Write-Host ""
                Write-Host "$($script:BoxMargin)OK -- restart manually before re-running this script." -ForegroundColor DarkGray
                Write-Host ""
                exit 0
            }
            Restart-Computer -Force
        }
    }

    return [pscustomobject]@{ Removed = $removed; Failed = $failed; Skipped = $skipped }
}

function Uninstall-SoundControl {
    <#
    .SYNOPSIS
        Removes LEQ Control Panel (PATH C only).
    #>
    $scFolder = Join-Path $env:LOCALAPPDATA "Programs\LEQControlPanel"
    $scLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) "LEQ Control Panel.lnk"

    if (-not (Test-Path $scFolder)) {
        return $false
    }

    Write-Host "$($script:BoxMargin)Uninstalling LEQ Control Panel..." -ForegroundColor Red

    # Kill process
    Stop-Process -Name "LEQControlPanel" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    # Remove Run key
    Remove-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" -Name "LEQControlPanel" -ErrorAction SilentlyContinue

    # Remove desktop shortcut
    if (Test-Path $scLnk) { Remove-Item $scLnk -Force -ErrorAction SilentlyContinue }

    # Delete folder
    Remove-Item $scFolder -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "$($script:BoxMargin)LEQ Control Panel uninstalled." -ForegroundColor Green
    return $true
}

# ============================================================================
# SECTION 5: Install Functions
# ============================================================================

function Install-VBAudioCertificate {
    <#
    .SYNOPSIS
        Pre-trusts the VB-Audio driver signing certificate so Windows
        skips the driver installation confirmation dialog.
    #>

    try {
        $thumbprint = '00859AAC6A54B8C1B3C139DE67846E64E7B82DB2'

        # Check if already trusted
        $store = [System.Security.Cryptography.X509Certificates.X509Store]::new(
            'TrustedPublisher', 'LocalMachine')
        try {
            $store.Open('ReadOnly')
            $existing = $store.Certificates.Find(
                [System.Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,
                $thumbprint, $false)
            if ($existing.Count -gt 0) { return $true }
        }
        finally { $store.Close() }

        # VB-Audio driver signing certificate (CN=Vincent Burel, Digital ID Class 3)
        # Extracted from vbaudio_hfvaio64_win7.sys -- public cert embedded in every
        # copy of the Hi-Fi Cable / Voicemeeter driver package.
        $certBase64 = 'MIIFijCCBHKgAwIBAgIQB6z1xadU2q9M1r0ddHkdWTANBgkqhki' +
            'G9w0BAQUFADCBtDELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDlZlcmlTaWduLC' +
            'BJbmMuMR8wHQYDVQQLExZWZXJpU2lnbiBUcnVzdCBOZXR3b3JrMTswOQYDV' +
            'QQLEzJUZXJtcyBvZiB1c2UgYXQgaHR0cHM6Ly93d3cudmVyaXNpZ24uY29' +
            'tL3JwYSAoYykxMDEuMCwGA1UEAxMlVmVyaVNpZ24gQ2xhc3MgMyBDb2RlI' +
            'FNpZ25pbmcgMjAxMCBDQTAeFw0xMzExMDIwMDAwMDBaFw0xNTAxMDEyMzU5' +
            'NTlaMIHNMQswCQYDVQQGEwJGUjERMA8GA1UECBMIRG9yZG9nbmUxDjAMBgN' +
            'VBAcTBUV5bWV0MSQwIgYDVQQKFBtObyBPcmdhbml6YXRpb24gQWZmaWxpYX' +
            'Rpb24xPjA8BgNVBAsTNURpZ2l0YWwgSUQgQ2xhc3MgMyAtIE1pY3Jvc29md' +
            'CBTb2Z0d2FyZSBWYWxpZGF0aW9uIHYyMR0wGwYDVQQLFBRJbmRpdmlkdWF' +
            'sIERldmVsb3BlcjEWMBQGA1UEAxQNVmluY2VudCBCdXJlbDCCASIwDQYJKo' +
            'ZIhvcNAQEBBQADggEPADCCAQoCggEBAOYiZUittitgZENWdXIYRoqi2HUKqYJ' +
            'b2CA6gRGkJ5VPdv5qMUly6C8tLxlbomX/V3GyWUTN8ZojFU7RWODhVbXkAD' +
            'kwh2eXP6CsmED2SEXFVE5+G5Hf/jFScYYw7wmGkgIQHiYPkWZLEY85Y1Etg' +
            'HEB3rA+sT+cGAPr3X8QJZmdxME6s5SXb2hl9KkiuGpjQR8XEESmHUSft2Ip' +
            'SOz91ocWZIn9k1s9wWph2q5hJjNMtd7IO7m5D7k1MYghzKnZpZGq9rLgDyd' +
            'pnag9LdrR++pYx5WqNkbCqwXeE8PSYW8BvMNne8ZD4oVW4nUC6S6jcPvNe/' +
            'JAUy/rLNmSBn1IQECAwEAAaOCAXswggF3MAkGA1UdEwQCMAAwDgYDVR0PAQH' +
            '/BAQDAgeAMEAGA1UdHwQ5MDcwNaAzoDGGL2h0dHA6Ly9jc2MzLTIwMTAtY3' +
            'JsLnZlcmlzaWduLmNvbS9DU0MzLTIwMTAuY3JsMEQGA1UdIAQ9MDswOQYLY' +
            'IZIAYb4RQEHFwMwKjAoBggrBgEFBQcCARYcaHR0cHM6Ly93d3cudmVyaXNp' +
            'Z24uY29tL3JwYTATBgNVHSUEDDAKBggrBgEFBQcDAzBxBggrBgEFBQcBAQR' +
            'lMGMwJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLnZlcmlzaWduLmNvbTA7Bg' +
            'grBgEFBQcwAoYvaHR0cDovL2NzYzMtMjAxMC1haWEudmVyaXNpZ24uY29tL' +
            '0NTQzMtMjAxMC5jZXIwHwYDVR0jBBgwFoAUz5mp6nsm9EvJjo/X8AUm7+PS' +
            'p50wEQYJYIZIAYb4QgEBBAQDAgQQMBYGCisGAQQBgjcCARsECDAGAQEAAQH' +
            '/MA0GCSqGSIb3DQEBBQUAA4IBAQADlID7V7ye/9ibIHcTo08u9XP/vbrkk7+G' +
            't6k2gZjXLZEs2Q8Bv53sY1xSTmBg8HRZc1CuOR2G2cYSVD8S5NPPYx/6TES' +
            'GuHMTGG2a31G8EHDLUgSRCZmpyfiJAC98iXrIuDWJ1zEXj8f0+cktENiayH2' +
            'hrVgOlxAjvgZ7zpzg+T291f8wwXg2BXVRmXr6SNeLBNX5QsjzK3bsOkjGeE' +
            'fu47CV2CWuAFQW1Yt9HuE64v6h96Z3zipddcg3vHqE81w7JTFrvU7D77iOEz' +
            'ei8RxaUTLhrureghtB7UEymvU5T7PJivdZ51k81+hYBR0Y1JpIsF6YOUcrMe' +
            'BCO5vjYn0Y'

        $certBytes = [Convert]::FromBase64String($certBase64)
        $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($certBytes)

        $store = [System.Security.Cryptography.X509Certificates.X509Store]::new(
            'TrustedPublisher', 'LocalMachine')
        $store.Open('ReadWrite')
        $store.Add($cert)
        $store.Close()

        return $true
    }
    catch {
        return $false
    }
}

function Install-VBCable {
    <#
    .SYNOPSIS
        Extracts and installs the VB-CABLE v45 virtual audio driver from the
        VBCABLE_Driver_Pack45 ZIP. WAITS for the installer's NATURAL exit -- the
        driver finalizes endpoint naming/icons on shutdown, so it is never killed
        early. A non-zero exit means a prior VB-CABLE version is present; the -u -h
        uninstall remedy is surfaced.
    #>
    param([ValidateNotNullOrEmpty()][string]$ZipPath)

    Write-Host "$($script:BoxMargin)Installing VB-CABLE..." -ForegroundColor Cyan

    # Extract ZIP
    $extractPath = Join-Path $script:TempPath "VBCable_Extract"
    if (Test-Path $extractPath) { Remove-Item $extractPath -Recurse -Force }
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $extractPath -Force

    # Find the x64 setup exe
    $setupExe = Get-ChildItem -LiteralPath $extractPath -Filter "VBCABLE_Setup_x64.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $setupExe) {
        $setupExe = Get-ChildItem -LiteralPath $extractPath -Filter "VBCABLE_Setup*.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if (-not $setupExe) {
        Write-Host "$($script:BoxMargin)ERROR: VB-CABLE setup exe not found in archive." -ForegroundColor Red
        return $false
    }

    # Pre-trust VB-Audio driver certificate (suppresses driver confirmation dialog)
    $null = Install-VBAudioCertificate

    # Run silent install (-i install, -h hidden). Wait for NATURAL exit; never kill.
    $proc = Start-Process -FilePath $setupExe.FullName -ArgumentList "-i -h" -PassThru -ErrorAction Stop
    Write-Wait -Message "Installing VB-CABLE driver (waiting for it to finish)..." -Until { $proc.HasExited } -TimeoutSeconds 180 | Out-Null
    # Guarantee full exit before endpoint detection runs -- killing early races the
    # driver's endpoint naming/icon finalization.
    $proc.WaitForExit()
    Start-Sleep -Seconds 2
    $exit = $proc.ExitCode

    # Cleanup extract folder
    Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue

    if ($exit -ne 0) {
        Write-Host "$($script:BoxMargin)VB-CABLE setup returned exit code $exit." -ForegroundColor Yellow
        Write-Host "$($script:BoxMargin)A previous VB-CABLE version may already be present." -ForegroundColor Yellow
        Write-Host "$($script:BoxMargin)To fully reinstall: run the setup with '-u -h' to uninstall, reboot, then re-run:" -ForegroundColor Yellow
        Write-Host "$($script:BoxMargin)  VBCABLE_Setup_x64.exe -u -h" -ForegroundColor DarkGray
        # Non-fatal: endpoints from the existing cable can still be configured, so the
        # run deliberately continues from here. The return reports the failure anyway,
        # so the completion summary does not show a tick for a setup that errored.
        return $false
    }

    Write-Host "$($script:BoxMargin)VB-CABLE installed." -ForegroundColor Green
    return $true
}

function Install-Voicemeeter {
    <#
    .SYNOPSIS
        Extracts and installs Voicemeeter Standard from a ZIP archive.
    #>
    param([ValidateNotNullOrEmpty()][string]$ZipPath)

    Write-Host "$($script:BoxMargin)Installing Voicemeeter..." -ForegroundColor Cyan

    # Resolved rather than hardcoded, so this agrees with the skip decision in
    # Get-Downloads -- both ask Test-VoicemeeterEdition where Voicemeeter lives.
    if ((Test-VoicemeeterEdition).Standard) {
        Write-Host "$($script:BoxMargin)Voicemeeter already installed." -ForegroundColor Green
        return $true
    }

    # Extract ZIP
    $extractPath = Join-Path $script:TempPath "Voicemeeter_Extract"
    if (Test-Path $extractPath) { Remove-Item $extractPath -Recurse -Force }
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $extractPath -Force

    # Find setup exe
    $setupExe = Get-ChildItem -LiteralPath $extractPath -Filter "*Setup*.exe" -Recurse -ErrorAction Stop | Select-Object -First 1
    if (-not $setupExe) {
        Write-Host "$($script:BoxMargin)ERROR: Voicemeeter setup exe not found in archive." -ForegroundColor Red
        return $false
    }

    # Pre-trust VB-Audio driver certificate (suppresses driver confirmation dialog)
    $null = Install-VBAudioCertificate

    # Run silent install
    $proc = Start-Process -FilePath $setupExe.FullName -ArgumentList "-i -h" -PassThru -ErrorAction Stop
    Write-Wait -Message "Installing Voicemeeter driver..." -Until { $proc.HasExited } -TimeoutSeconds 60 | Out-Null
    Start-Sleep -Seconds 2

    # Verify. Re-probe instead of reusing a pre-install path: setup picks its own
    # target folder, and that is exactly what Test-VoicemeeterEdition resolves.
    if (-not (Test-VoicemeeterEdition).Standard) {
        Write-Host "$($script:BoxMargin)WARNING: Voicemeeter verification failed." -ForegroundColor Yellow
        return $false
    }

    # Cleanup extract folder
    Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "$($script:BoxMargin)Voicemeeter installed." -ForegroundColor Green
    return $true
}

function Install-ReaPlugs {
    <#
    .SYNOPSIS
        Installs the ReaPlugs VST plugin suite and brings the NSIS dialog to the foreground.
    #>
    param([ValidateNotNullOrEmpty()][string]$InstallerPath)

    Write-Host "$($script:BoxMargin)Installing ReaPlugs..." -ForegroundColor Cyan

    $verifyDir = "${env:ProgramFiles}\VSTPlugins\ReaPlugs"
    $dlls = @(Get-ChildItem "$verifyDir\*.dll" -ErrorAction SilentlyContinue)
    if ($dlls.Count -ge 5) {
        Write-Host "$($script:BoxMargin)ReaPlugs already installed ($($dlls.Count) DLLs)." -ForegroundColor Green
        return $true
    }

    Unblock-File -LiteralPath $InstallerPath -ErrorAction SilentlyContinue
    $proc = Start-Process -FilePath $InstallerPath -ArgumentList "/S" -PassThru -ErrorAction Stop

    # Poll for the ReaPlugs "installed" dialog and bring it to front
    $focusJob = Start-Job -ScriptBlock {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class WinHelper2 {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
}
'@
        for ($i = 0; $i -lt 60; $i++) {
            $callback = [WinHelper2+EnumWindowsProc]{
                param($hwnd, $lParam)
                $sb = New-Object System.Text.StringBuilder 256
                [WinHelper2]::GetWindowText($hwnd, $sb, 256) | Out-Null
                $t = $sb.ToString()
                if ($t -and ($t -like "*ReaPlug*" -or $t -like "*NSIS*" -or $t -like "*reaplugs*")) {
                    [WinHelper2]::ShowWindow($hwnd, 5) | Out-Null
                    [WinHelper2]::SetForegroundWindow($hwnd) | Out-Null
                    return $false
                }
                return $true
            }
            [WinHelper2]::EnumWindows($callback, [IntPtr]::Zero) | Out-Null
            Start-Sleep -Milliseconds 500
        }
    }

    Write-ActionBox -Lines @(
        "ReaPlugs installer is running.",
        "",
        "  -> Click OK when it says 'installed'",
        "",
        "Press Enter here when done."
    )

    Stop-Job $focusJob -ErrorAction SilentlyContinue
    Remove-Job $focusJob -Force -ErrorAction SilentlyContinue

    # Wait for installer if it hasn't finished
    if (-not $proc.HasExited) {
        Write-Wait -Message "Finishing ReaPlugs installation..." -Until { $proc.HasExited } -TimeoutSeconds 60 | Out-Null
    }

    # Verify
    $dlls = @(Get-ChildItem "$verifyDir\*.dll" -ErrorAction SilentlyContinue)
    if ($dlls.Count -lt 5) {
        Write-Host "$($script:BoxMargin)WARNING: ReaPlugs verification failed (found $($dlls.Count) DLLs, expected 5+)." -ForegroundColor Yellow
        return $false
    }

    Write-Host "$($script:BoxMargin)ReaPlugs installed ($($dlls.Count) DLLs)." -ForegroundColor Green
    return $true
}

function Get-EapoInstallPath {
    <#
    .SYNOPSIS
        The folder Equalizer APO records as its own install location, or $null.
    .DESCRIPTION
        HKLM:\SOFTWARE\EqualizerAPO\InstallPath is written by E-APO's own setup and is
        what that setup reads back when it runs again -- so it, not a Test-Path on the
        default folder, is what decides where a REINSTALL lands. Install-Eapo uses it
        both to spot a non-default install up front and to verify where setup actually
        went, rather than assuming /D= won.

        Returned even when the folder no longer exists: a stale key still steers the
        installer, so callers that care about a live install Test-Path it themselves.

        StrictMode-safe: the key exists on machines where the value does not.
    #>
    foreach ($rp in @('HKLM:\SOFTWARE\EqualizerAPO', 'HKLM:\SOFTWARE\WOW6432Node\EqualizerAPO')) {
        $props = Get-ItemProperty -LiteralPath $rp -ErrorAction SilentlyContinue
        if (-not $props) { continue }
        if (-not $props.PSObject.Properties['InstallPath']) { continue }
        $p = "$($props.InstallPath)".Trim().Trim('"')
        if ($p) { return $p.TrimEnd('\', '/') }
    }
    return $null
}

function Install-Eapo {
    <#
    .SYNOPSIS
        Installs Equalizer APO and creates the SonicScout2.0 folder structure.
    .DESCRIPTION
        ALWAYS runs the installer, including over an existing E-APO. That is the point:
        setup is the only thing that reopens Device Selector, and [1] Install has just
        removed the retired Hi-Fi Cable that an existing E-APO was very likely bound to.
        Everything after the installer -- the SonicScout2.0 folder, its icon, its .url files
        and the desktop shortcut -- used to be unreachable on a machine that already had
        E-APO, because the whole function was skipped.
    #>
    param([ValidateNotNullOrEmpty()][string]$InstallerPath)

    Write-Host "$($script:BoxMargin)Installing Equalizer APO..." -ForegroundColor Cyan

    # Every path downstream -- config.txt, the SonicScout2.0 library root, HeSuVi, the HRIR,
    # the uninstall lane -- is pinned to ProgramFiles\EqualizerAPO, so that is the only
    # location this script can drive. /D= is the lever for it.
    $eapoRoot   = (Join-Path $env:ProgramFiles "EqualizerAPO").TrimEnd('\')
    $eapoConfig = Join-Path $eapoRoot "config"

    # A non-default existing install is the one case /D= may lose: E-APO's setup reads
    # its own recorded path back. Say so before the dialogs appear rather than leaving
    # the user to wonder why the verification below failed.
    $priorRoot = Get-EapoInstallPath
    $priorIsCustom = ($priorRoot -and
        -not [string]::Equals($priorRoot, $eapoRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $priorRoot -PathType Container))
    if ($priorIsCustom) {
        Write-Host ""
        Write-Host "$($script:BoxMargin)Equalizer APO is installed in a non-default folder:" -ForegroundColor Yellow
        Write-Host "$($script:BoxMargin)  $priorRoot" -ForegroundColor Yellow
        Write-Host "$($script:BoxMargin)SonicScout2.0 only drives the default location. Setup will aim for" -ForegroundColor DarkGray
        Write-Host "$($script:BoxMargin)  $eapoRoot" -ForegroundColor DarkGray
        Write-Host "$($script:BoxMargin)and check where it actually landed afterwards." -ForegroundColor DarkGray
        Write-Host ""
    }

    # config.txt is the user's, and a reinstall can replace it -- so the backup happens
    # HERE, before setup runs, not only in Write-InitialConfig. Backup-EAPOConfigFile
    # keeps one foreign copy per run, so its later call cannot bury this one under
    # whatever the installer left behind.
    $null = Backup-EAPOConfigFile

    # Peace / HeSuVi / Editor hold file locks on E-APO's DLLs and would make an
    # install-over fail in place. No-ops on a machine with no E-APO yet.
    Stop-EAPOEcosystemProcesses

    Unblock-File -LiteralPath $InstallerPath -ErrorAction SilentlyContinue
    # /S is semi-silent (the Device Selector dialog still appears). /D sets the install
    # dir (matches SS app: InstallEapoFromFileAsync) and NSIS requires it LAST and
    # UNQUOTED -- everything after /D= is read verbatim to end of line. That is why this
    # stays ONE argument string: an array would quote the path and break it.
    $proc = Start-Process -FilePath $InstallerPath -ArgumentList "/S /D=$eapoRoot" -PassThru -ErrorAction Stop

    # Start a background job to poll for E-APO dialog windows and bring them to front.
    # The installer spawns Device Selector, Upgrades, Testing APO, and Info dialogs --
    # with /S mode the main process has no window, so Set-WindowForeground won't work.
    $focusJob = Start-Job -ScriptBlock {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class WinHelper {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
}
'@
        $titles = @("Device Selector", "Upgrades available", "Testing APO", "Info", "Equalizer APO Setup")
        for ($i = 0; $i -lt 120; $i++) {
            foreach ($title in $titles) {
                $callback = [WinHelper+EnumWindowsProc]{
                    param($hwnd, $lParam)
                    $sb = New-Object System.Text.StringBuilder 256
                    [WinHelper]::GetWindowText($hwnd, $sb, 256) | Out-Null
                    $t = $sb.ToString()
                    if ($t -and $t -like "*$title*") {
                        [WinHelper]::ShowWindow($hwnd, 5) | Out-Null
                        [WinHelper]::SetForegroundWindow($hwnd) | Out-Null
                        return $false
                    }
                    return $true
                }
                [WinHelper]::EnumWindows($callback, [IntPtr]::Zero) | Out-Null
            }
            Start-Sleep -Milliseconds 500
        }
    }

    # Now show guidance while installer is running
    Write-ActionBox -Lines @(
        "E-APO installer is running.",
        "",
        "  -> Device Selector: just CLOSE it (X button)",
        "  -> Upgrades: click Yes",
        "  -> Other dialogs: click OK",
        "",
        "Press Enter here when E-APO is done."
    )

    # Clean up background focus job
    Stop-Job $focusJob -ErrorAction SilentlyContinue
    Remove-Job $focusJob -Force -ErrorAction SilentlyContinue

    # Wait for installer to finish if it hasn't already
    if (-not $proc.HasExited) {
        Write-Wait -Message "Finishing E-APO installation..." -Until { $proc.HasExited } -TimeoutSeconds 60 | Out-Null
    }
    Start-Sleep -Seconds 3

    # Verify. /D= is a REQUEST, not a guarantee -- an existing install's recorded path
    # can win it -- so a missing default config folder is checked against E-APO's own
    # key before it is called a failure. "Installed, but somewhere this script cannot
    # drive" is a different problem with a different fix, and saying so is the whole
    # reason Get-EapoInstallPath exists.
    if (-not (Test-Path $eapoConfig)) {
        Write-Host "$($script:BoxMargin)WARNING: Equalizer APO verification failed." -ForegroundColor Yellow
        $nowRoot = Get-EapoInstallPath
        if ($nowRoot -and -not [string]::Equals($nowRoot, $eapoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Host "$($script:BoxMargin)It installed to $nowRoot, not $eapoRoot." -ForegroundColor Yellow
            Write-Host "$($script:BoxMargin)SonicScout2.0 only drives the default location. Remove Equalizer APO from" -ForegroundColor DarkGray
            Write-Host "$($script:BoxMargin)Add/Remove Programs, then re-run [1] Install." -ForegroundColor DarkGray
        }
        return $false
    }

    Write-Host "$($script:BoxMargin)Equalizer APO installed." -ForegroundColor Green

    # Create desktop shortcuts
    $desktopPath = [Environment]::GetFolderPath('Desktop')

    # SonicScout2.0 folder inside E-APO config
    $sonicScout20Dir = Join-Path $eapoConfig "SonicScout2.0"
    $sonicScout20Library = Join-Path $sonicScout20Dir "library"
    try {
        New-Item -Path $sonicScout20Library -ItemType Directory -Force | Out-Null
        # README.txt is NOT written here. Write-FolderReadme emits it from the [1]
        # Install path instead, which is the only path that also knows whether
        # config.txt ended up with one chain or two ($TwoChains).
        Set-Content -Path (Join-Path $sonicScout20Dir "SonicScout2.0 Home.url") -Value "[InternetShortcut]`r`nURL=https://www.github.com/sensoredrooster"
        Set-Content -Path (Join-Path $sonicScout20Dir "SonicScout2.0.url") -Value "[InternetShortcut]`r`nURL=https://github.com/sensoredrooster/SonicScout2.0"
        # Download SonicScout2.0 icon
        $iconPath = Join-Path $sonicScout20Dir "SonicScout2.0.ico"
        try {
            Invoke-WebRequest -Uri "https://raw.githubusercontent.com/sensoredrooster/SonicScout2.0/main/Assets/SonicScout2.0Logo.ico" -OutFile $iconPath -UseBasicParsing
        } catch {
            $iconPath = $null
            Write-Host "$($script:BoxMargin)Warning: Could not download icon: $_" -ForegroundColor Yellow
        }
        # Set custom folder icon via desktop.ini
        if ($iconPath -and (Test-Path $iconPath)) {
            try {
                $iniPath = Join-Path $sonicScout20Dir "desktop.ini"
                $iniContent = "[.ShellClassInfo]`r`nIconResource=SonicScout2.0.ico,0"
                Set-Content -Path $iniPath -Value $iniContent -Force
                (Get-Item $iniPath).Attributes = 'Hidden,System'
                $dirItem = Get-Item $sonicScout20Dir
                $dirItem.Attributes = $dirItem.Attributes -bor [System.IO.FileAttributes]::System
            } catch {
                Write-Host "$($script:BoxMargin)Warning: Could not set folder icon: $_" -ForegroundColor Yellow
            }
        }
        Write-Host "$($script:BoxMargin)SonicScout2.0 folder created." -ForegroundColor Green
    } catch {
        Write-Host "$($script:BoxMargin)Warning: Could not create SonicScout2.0 folder: $_" -ForegroundColor Yellow
    }

    # SonicScout2.0 desktop shortcut (points to SonicScout2.0 folder)
    try {
        $shortcutPath = Join-Path $desktopPath "SonicScout2.0.lnk"
        $ws = New-Object -ComObject WScript.Shell
        $shortcut = $ws.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $sonicScout20Dir
        $shortcutIcon = Join-Path $sonicScout20Dir "SonicScout2.0.ico"
        if (Test-Path $shortcutIcon) {
            $shortcut.IconLocation = "$shortcutIcon,0"
        } else {
            $shortcut.IconLocation = "shell32.dll,3"
        }
        $shortcut.Description = "SonicScout2.0 folder"
        $shortcut.Save()
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($ws) | Out-Null
        Write-Host "$($script:BoxMargin)Desktop shortcut created: SonicScout2.0" -ForegroundColor Green
    } catch {
        Write-Host "$($script:BoxMargin)Warning: Could not create SonicScout2.0 shortcut: $_" -ForegroundColor Yellow
    }

    # E-APO Configuration Editor shortcut inside SonicScout2.0 folder
    $editorExe = Join-Path $env:ProgramFiles "EqualizerAPO\Editor.exe"
    if (Test-Path $editorExe) {
        try {
            $shortcutPath = Join-Path $sonicScout20Dir "E-APO Configuration Editor.lnk"
            $ws = New-Object -ComObject WScript.Shell
            $shortcut = $ws.CreateShortcut($shortcutPath)
            $shortcut.TargetPath = $editorExe
            $shortcut.WorkingDirectory = Join-Path $env:ProgramFiles "EqualizerAPO"
            $shortcut.Description = "Equalizer APO Configuration Editor"
            $shortcut.Save()
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($ws) | Out-Null
            Write-Host "$($script:BoxMargin)E-APO Configuration Editor shortcut created in SonicScout2.0 folder." -ForegroundColor Green
        } catch {
            Write-Host "$($script:BoxMargin)Warning: Could not create editor shortcut: $_" -ForegroundColor Yellow
        }
    }

    return $true
}

function Install-HeSuVi {
    <#
    .SYNOPSIS
        Installs HeSuVi with retry support for the interactive 7z SFX installer.
    #>
    param([ValidateNotNullOrEmpty()][string]$InstallerPath)

    Write-Host "$($script:BoxMargin)Installing HeSuVi..." -ForegroundColor Cyan

    $hesuviDir = Join-Path $env:ProgramFiles "EqualizerAPO\config\HeSuVi"
    if (Test-Path $hesuviDir) {
        Write-Host "$($script:BoxMargin)HeSuVi already installed." -ForegroundColor Green
        return $true
    }

    # HeSuVi is a 7z SFX -- no silent flag works. Retry loop lets the user
    # re-launch the installer if they accidentally cancel the extraction dialog.
    while ($true) {
        # Clean up any partial directory from a previous cancelled extraction
        Remove-Item $hesuviDir -Recurse -Force -ErrorAction SilentlyContinue

        Unblock-File -LiteralPath $InstallerPath -ErrorAction SilentlyContinue

        $proc = Start-Process -FilePath $InstallerPath -PassThru -ErrorAction Stop
        Set-WindowForeground -Process $proc

        Write-ActionBox -Lines @(
            "HeSuVi needs manual confirmation:",
            "",
            "  -> A dialog will appear -- click Yes / OK",
            "  -> Let it finish extracting",
            "  -> Close HeSuVi and the browser window it opens",
            "",
            "Come back here when it's done."
        )

        if (-not $proc.HasExited) {
            Write-Wait -Message "Finishing HeSuVi extraction..." -Until { $proc.HasExited } -TimeoutSeconds 120 | Out-Null
        }
        Start-Sleep -Seconds 2

        # Check expected path, search alternates if needed
        if (-not (Test-Path $hesuviDir)) {
            $altPaths = @(
                "$env:ProgramFiles\HeSuVi",
                "$env:USERPROFILE\Desktop\HeSuVi",
                "$env:TEMP\HeSuVi"
            )
            $foundPath = $altPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
            if ($foundPath) {
                Write-Host "$($script:BoxMargin)Found HeSuVi at $foundPath, moving to correct location..." -ForegroundColor DarkGray
                New-Item -ItemType Directory -Path $hesuviDir -Force | Out-Null
                Copy-Item -Path "$foundPath\*" -Destination $hesuviDir -Recurse -Force
                Remove-Item $foundPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        # If directory exists now, installation succeeded -- break out of retry loop
        if (Test-Path $hesuviDir) {
            break
        }

        # HeSuVi not found -- offer retry or skip
        Write-Host ""
        Write-Host "$($script:BoxMargin)HeSuVi was not installed." -ForegroundColor Yellow
        Write-Host "$($script:BoxMargin)The installer may have been cancelled." -ForegroundColor Yellow
        Write-Host ""
        $retryMenuItems = @(
            @{ Text = '[r] Retry - run the HeSuVi installer again'; Color = 'White' }
            @{ Text = '[s] Skip  - continue without HeSuVi'; Color = 'DarkGray' }
        )
        $retryMargin = Write-CenteredBlock $retryMenuItems
        Write-Host ""

        while ($true) {
            Write-Host "$retryMargin" -NoNewline
            Write-Host "Choice: " -ForegroundColor Yellow -NoNewline
            $retryChoice = Read-Host
            if ($retryChoice -eq 'r' -or $retryChoice -eq 'R') {
                Write-Host "$($script:BoxMargin)Retrying HeSuVi installation..." -ForegroundColor Cyan
                break
            }
            if ($retryChoice -eq 's' -or $retryChoice -eq 'S') {
                Write-Host "$($script:BoxMargin)Skipping HeSuVi. You can install it manually later." -ForegroundColor Yellow
                return $false
            }
            Write-Host "$($script:BoxMargin)Invalid choice. Enter r to retry or s to skip." -ForegroundColor Red
        }
    }

    # Wipe EQ folder
    $eqPath = Join-Path $hesuviDir "eq"
    if (Test-Path $eqPath) {
        Remove-Item "$eqPath\*" -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Verify
    $hesuviTxt = Join-Path $hesuviDir "hesuvi.txt"
    $convTxt = Join-Path $hesuviDir "conv.txt"
    if ((Test-Path $hesuviTxt) -and (Test-Path $convTxt)) {
        Write-Host "$($script:BoxMargin)HeSuVi installed (hesuvi.txt + conv.txt verified)." -ForegroundColor Green
    } elseif (Test-Path $hesuviDir) {
        Write-Host "$($script:BoxMargin)HeSuVi installed (config files will be generated on first GUI launch)." -ForegroundColor Green
    } else {
        Write-Host "$($script:BoxMargin)WARNING: HeSuVi verification incomplete." -ForegroundColor Yellow
    }
    return $true
}

function Get-HrirFile {
    <#
    .SYNOPSIS
        Downloads a single HRIR WAV file with progress display and validation.
    #>
    param(
        [string]$Url,
        [string]$Label,
        [string]$Destination
    )

    $tempFile = Join-Path $script:TempPath "hrir_$(Split-Path $Destination -Leaf)"

    $job = Start-Job -ScriptBlock {
        param($u, $o)
        $ErrorActionPreference = 'Stop'
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $u -OutFile $o -UseBasicParsing -ErrorAction Stop
    } -ArgumentList $Url, $tempFile

    $outRef = $tempFile
    Write-Wait -Message "Downloading $Label..." -Until { $job.State -ne 'Running' } -TimeoutSeconds 120 -Progress {
        $pf = Get-Item $outRef -ErrorAction SilentlyContinue
        if ($pf) { Format-ByteSize -Bytes $pf.Length -Bracket }
    } | Out-Null

    if ($job.State -eq 'Failed') {
        $err = Receive-Job $job -ErrorAction SilentlyContinue 2>&1
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        Write-Host "$($script:BoxMargin)WARNING: Failed to download ${Label}: $err" -ForegroundColor Yellow
        return $null
    }
    Remove-Job $job -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path $tempFile)) {
        Write-Host "$($script:BoxMargin)WARNING: $Label download completed but file not found." -ForegroundColor Yellow
        return $null
    }
    $fileSize = (Get-Item $tempFile).Length
    if ($fileSize -eq 0) {
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        Write-Host "$($script:BoxMargin)WARNING: $Label download completed but file is empty." -ForegroundColor Yellow
        return $null
    }

    Copy-Item -Path $tempFile -Destination $Destination -Force
    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    return $fileSize
}

function Install-SonicScout20HRIR {
    <#
    .SYNOPSIS
        Downloads the SonicScout2.0 HRIR files (EAC_Default and EAC_Refined, 48 kHz and
        44.1 kHz) into the HeSuVi hrir directory. These are NOT bundled in the
        library release, so they are fetched from the CDN.
    #>

    $hrirDir   = Join-Path $env:ProgramFiles "EqualizerAPO\config\HeSuVi\hrir"
    $hrir44Dir = Join-Path $hrirDir "44"

    $targets = @(
        @{ Name = 'EAC_Default'; Rate = '48 kHz';   Url = 'https://raw.githubusercontent.com/sensoredrooster/SonicScout2.0/main/hrir/EAC_Default.wav';    Dest = (Join-Path $hrirDir   'EAC_Default.wav') }
        @{ Name = 'EAC_Default'; Rate = '44.1 kHz'; Url = 'https://raw.githubusercontent.com/sensoredrooster/SonicScout2.0/main/hrir/44/EAC_Default.wav'; Dest = (Join-Path $hrir44Dir 'EAC_Default.wav') }
    )

    if (-not ($targets | Where-Object { -not (Test-Path $_.Dest) })) {
        Write-Host "$($script:BoxMargin)SonicScout2.0 HRIR already installed." -ForegroundColor Green
        return $true
    }

    Write-Host "$($script:BoxMargin)Installing SonicScout2.0 HRIR..." -ForegroundColor Cyan

    if (-not (Test-Path $hrirDir))   { New-Item -ItemType Directory -Path $hrirDir   -Force | Out-Null }
    if (-not (Test-Path $hrir44Dir)) { New-Item -ItemType Directory -Path $hrir44Dir -Force | Out-Null }

    $ok = $true
    foreach ($t in $targets) {
        if (Test-Path $t.Dest) { continue }
        $relative = if ($t.Rate -eq '44.1 kHz') { 'hrir\44\EAC_Default.wav' } else { 'hrir\EAC_Default.wav' }
        if ($PSScriptRoot) {
            $bundledPaths = @((Join-Path $PSScriptRoot $relative), (Join-Path (Split-Path $PSScriptRoot -Parent) $relative))
            $local = $bundledPaths | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
            if ($local) { Copy-Item -LiteralPath $local -Destination $t.Dest -Force; continue }
        }
        $size = Get-HrirFile -Url $t.Url -Label "$($t.Name) ($($t.Rate))" -Destination $t.Dest
        if (-not $size) { $ok = $false }
    }

    if ($ok) {
        Write-Host "$($script:BoxMargin)SonicScout2.0 HRIR installed (EAC_Default, 48 kHz + 44.1 kHz)." -ForegroundColor Green
    } else {
        Write-Host "$($script:BoxMargin)WARNING: Some SonicScout2.0 HRIR files could not be downloaded." -ForegroundColor Yellow
    }
    return $ok
}

function Resolve-LibraryPayloadRoot {
    <#
    .SYNOPSIS
        Given an extracted release staging dir, returns the folder that DIRECTLY
        holds the flattened library payload (game folders + vst\ / jsfx\), whether
        the zip put them at root, wrapped them in library\, or wrapped everything
        in a single repo-root folder. Prevents a doubled library\library\ layout.
    #>
    param([string]$StagingDir)

    $looksLikeLibrary = {
        param($dir)
        if (-not $dir -or -not (Test-Path $dir)) { return $false }
        if (Test-Path (Join-Path $dir 'vst'))  { return $true }
        if (Test-Path (Join-Path $dir 'jsfx')) { return $true }
        foreach ($g in @('BF6', 'BO6', 'BO7', 'PS5-BO6', 'STD')) {
            if (Test-Path (Join-Path $dir $g)) { return $true }
        }
        return $false
    }

    # 1) payload at the staging root
    if (& $looksLikeLibrary $StagingDir) { return $StagingDir }
    # 2) wrapped in a top-level library\
    $lib = Join-Path $StagingDir 'library'
    if (& $looksLikeLibrary $lib) { return $lib }
    # 3) single wrapper subdir (repo-root style): that dir, or its library\
    $subs = @(Get-ChildItem -Path $StagingDir -Directory -ErrorAction SilentlyContinue)
    if ($subs.Count -eq 1) {
        $w = $subs[0].FullName
        if (& $looksLikeLibrary $w) { return $w }
        $wlib = Join-Path $w 'library'
        if (& $looksLikeLibrary $wlib) { return $wlib }
    }
    # 4) any nested library\ that looks right
    $found = Get-ChildItem -Path $StagingDir -Recurse -Directory -Filter 'library' -ErrorAction SilentlyContinue |
        Where-Object { & $looksLikeLibrary $_.FullName } | Select-Object -First 1
    if ($found) { return $found.FullName }
    return $null
}

function Get-SonicScout20LibraryState {
    <#
    .SYNOPSIS
        Classifies the on-disk SonicScout2.0 library for the Setup decision. Stamp
        presence only -- no version comparison, no manifest.
          'Versioned'      - library\version.txt exists. Keep it; skip install.
          'OldUnversioned' - no version.txt but real library content (.txt config /
                             squig EQ files, e.g. a pre-overhaul S-prefix library).
                             Back up (dated), then fresh-install.
          'None'           - absent, empty, or no real content. Fresh install.
    .OUTPUTS
        pscustomobject @{ State; Version }
    #>
    $libRoot     = Join-Path $script:SonicScout20Root "library"
    $versionFile = Join-Path $libRoot "version.txt"
    if (Test-Path -LiteralPath $versionFile) {
        $ver = ''
        try { $ver = ("$(Get-Content -LiteralPath $versionFile -TotalCount 1 -ErrorAction Stop)").Trim() } catch { $ver = '' }
        return [pscustomobject]@{ State = 'Versioned'; Version = $ver }
    }
    if (Test-Path -LiteralPath $libRoot) {
        $realContent = @(Get-ChildItem -LiteralPath $libRoot -Recurse -File -Filter '*.txt' -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($realContent.Count -gt 0) { return [pscustomobject]@{ State = 'OldUnversioned'; Version = '' } }
    }
    return [pscustomobject]@{ State = 'None'; Version = '' }
}

function Test-LibraryBackupPreflight {
    <#
    .SYNOPSIS
        Fails fast, BEFORE the download, on the backup problems a retry cannot fix.
    .DESCRIPTION
        Every check here catches a failure that would otherwise surface only after a
        1 MB fetch, as a mid-copy error, with the real cause buried.

        MAX_PATH is computed PER FILE as <root>\SonicScout2.0 Backups\library-<stamp>\ plus
        that file's path RELATIVE to the library root, taking the max over the set.
        Longest-source-path plus root length is the wrong maximum: the longest source
        path can have a short relative segment. PS 5.1's FileSystem provider does not
        get long-path support from the LongPathsEnabled policy alone, so 260 is real.

        The enumeration deliberately omits -ErrorAction SilentlyContinue. A source path
        already over the limit is exactly what this check exists to find, and a
        suppressed enumeration would silently skip it.
    .OUTPUTS
        [bool] -- $false when the caller should not proceed to the download.
    #>
    param(
        [Parameter(Mandatory)][string]$LibraryPath,
        [Parameter(Mandatory)][string]$BackupRoot
    )

    try {
        $files = @(Get-ChildItem -LiteralPath $LibraryPath -Recurse -File)
    } catch {
        Write-Host ""
        Write-Host "$($script:BoxMargin)Your existing library cannot be read, so it cannot be backed up." -ForegroundColor Yellow
        Write-Host "$($script:BoxMargin)$($_.Exception.GetType().Name): $($_.Exception.Message)" -ForegroundColor DarkGray
        return $false
    }
    if ($files.Count -eq 0) { return $true }

    # -- free space on the drive that will hold the backup --------------------
    $needed = ($files | Measure-Object -Property Length -Sum).Sum
    try {
        $driveRoot = [IO.Path]::GetPathRoot($BackupRoot)
        $drive     = New-Object IO.DriveInfo($driveRoot)
        # IsReady is checked FIRST and the whole check skipped when false. On a
        # not-ready drive (disconnected network share, empty removable bay) the
        # constructor still succeeds and AvailableFreeSpace yields nothing rather than
        # throwing, so the catch below never fires -- and a null there compares as 0,
        # which would report a perfectly good machine as having a full disk.
        $freeBytes = if ($drive.IsReady) { $drive.AvailableFreeSpace } else { $null }
        if ($null -ne $freeBytes -and $freeBytes -lt $needed) {
            Write-Host ""
            Write-Host "$($script:BoxMargin)Not enough free space to back up your library first." -ForegroundColor Yellow
            Write-Host "$($script:BoxMargin)Needs $([math]::Round($needed / 1MB, 1)) MB on $driveRoot, $([math]::Round($freeBytes / 1MB, 1)) MB is free." -ForegroundColor DarkGray
            return $false
        }
    } catch {
        # Not fatal: an unreadable drive is not a reason to block a backup that may
        # well succeed. Recorded rather than swallowed.
        Write-Verbose "Free-space check skipped: $($_.Exception.GetType().Name)."
    }

    # -- free space for the STAGED copy, on the library's own drive ------------
    # The lay-down stages the new tree as a sibling of library\ before swapping it
    # in, so peak usage on THIS drive is two copies. Different drive from the backup
    # in general, hence a second probe rather than a bigger number above.
    #
    # PROXY, not the real figure: the incoming release has not been downloaded yet,
    # so the existing library's size stands in for it. The authoritative check is in
    # Invoke-AtomicLibraryLayDown, which measures the extracted payload exactly and
    # also covers the fresh-install path that skips this pre-flight entirely.
    try {
        $stageDriveRoot = [IO.Path]::GetPathRoot($LibraryPath)
        $stageDrive     = New-Object IO.DriveInfo($stageDriveRoot)
        # Same IsReady-first shape as above, for the same reason. Do not collapse it.
        $stageFree = if ($stageDrive.IsReady) { $stageDrive.AvailableFreeSpace } else { $null }
        if ($null -ne $stageFree -and $stageFree -lt $needed) {
            Write-Host ""
            Write-Host "$($script:BoxMargin)Not enough free space to install the new library." -ForegroundColor Yellow
            Write-Host "$($script:BoxMargin)Needs about $([math]::Round($needed / 1MB, 1)) MB on $stageDriveRoot, $([math]::Round($stageFree / 1MB, 1)) MB is free." -ForegroundColor DarkGray
            return $false
        }
    } catch {
        Write-Verbose "Staging free-space check skipped: $($_.Exception.GetType().Name)."
    }

    # -- MAX_PATH, per file ---------------------------------------------------
    # "library-yyyy-MM-dd_HHmmss" is 25 characters; +2 for the two separators.
    $prefixLength = $BackupRoot.TrimEnd('\').Length + 2 + 25
    $sourceBase   = $LibraryPath.TrimEnd('\').Length + 1
    $longest      = 0
    $longestName  = ''
    foreach ($file in $files) {
        $projected = $prefixLength + ($file.FullName.Length - $sourceBase)
        if ($projected -gt $longest) { $longest = $projected; $longestName = $file.Name }
    }
    if ($longest -ge 260) {
        Write-Host ""
        Write-Host "$($script:BoxMargin)A backup copy would exceed Windows' 260-character path limit." -ForegroundColor Yellow
        Write-Host "$($script:BoxMargin)Longest would be $longest characters, ending in '$longestName'." -ForegroundColor DarkGray
        Write-Host "$($script:BoxMargin)Shorten that file's name, or move the backup folder nearer the drive root." -ForegroundColor DarkGray
        return $false
    }

    return $true
}

function Get-LibraryLockReport {
    <#
    .SYNOPSIS
        After a refused lay-down, names the files that are open and the E-APO
        ecosystem processes that are running. Diagnostic ONLY -- nothing is gated on
        the answer.
    .DESCRIPTION
        MEASURED (Step 0, PS 5.1.26100.8875 / Win 11 26100, NTFS): a handle on ANY
        file inside a directory blocks [IO.Directory]::Move unconditionally. All six
        share modes failed -- None, Read, ReadWrite, Delete, Read|Delete,
        ReadWrite|Delete.

        MEASURED AND CORRECTED: FILE_SHARE_DELETE was first read as the deciding bit,
        because a handle on the DIRECTORY carrying that bit did not block. The
        isolation test disproved it for child handles -- all three *-del file modes
        still failed. It decides only for a handle on the directory itself. Do not
        reintroduce "share-delete readers are harmless" here; it was measured false.

        A FileShare.None probe therefore detects exactly what blocks the rename: any
        handle at all. It is the same probe the Step 0 harness used to prove its own
        locks were real.

        This runs only AFTER a rename has already been refused, and that is what
        makes the TOCTOU race harmless -- a stale answer costs an imprecise message,
        not a wrong decision. A pre-flight of this same shape was considered for the
        library-destroy path and dropped for exactly the reason that does not apply here.
    .OUTPUTS
        pscustomobject @{ Files; More; Processes }
    #>
    param([Parameter(Mandatory)][string]$Path)

    $locked = @()
    $more   = 0

    foreach ($file in @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        $stream = $null
        try {
            $stream = [IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        }
        catch {
            # Refused open == a handle exists. The exception is the signal itself, so
            # there is nothing to record beyond which file it was.
            # Reported relative to the library folder: the absolute path is ~90
            # characters of Program Files boilerplate that buries the one part the
            # user needs to recognise.
            if ($locked.Count -lt 5) {
                $rel = $file.FullName
                if ($rel.Length -gt $Path.Length) {
                    $rel = Join-Path (Split-Path $Path -Leaf) $rel.Substring($Path.Length).TrimStart('\')
                }
                $locked += $rel
            } else {
                $more++
            }
        }
        finally {
            if ($null -ne $stream) { $stream.Dispose() }
        }
    }

    # Same names Stop-EAPOEcosystemProcesses works from, so the two cannot drift.
    $running = @()
    foreach ($name in @('Peace', 'HeSuVi', 'Configurator', 'DeviceSelector')) {
        if (@(Get-Process -Name $name -ErrorAction SilentlyContinue).Count -gt 0) { $running += $name }
    }
    $eapoPath = Join-Path $env:ProgramFiles "EqualizerAPO"
    $editors = @(Get-Process -Name 'Editor' -ErrorAction SilentlyContinue |
        Where-Object {
            try { $_.Path -and $_.Path.StartsWith($eapoPath, [System.StringComparison]::OrdinalIgnoreCase) }
            catch { $false }
        })
    if ($editors.Count -gt 0) { $running += 'E-APO Editor' }

    return [pscustomobject]@{ Files = $locked; More = $more; Processes = $running }
}

function Restore-InterruptedLibrarySwap {
    <#
    .SYNOPSIS
        Recovers or clears the transient folders an interrupted lay-down leaves
        behind. RESTORES first, deletes second.
    .DESCRIPTION
        The lay-down renames library\ -> library.old-<stamp>\ and then
        library.new-<stamp>\ -> library\. A crash between those two renames leaves the
        real library under library.old-<stamp>\ with no library\ at all. That tree
        holds the user's squig.link EQs and is the only irreplaceable thing in play,
        so it is NEVER deleted while library\ is missing -- it is put back.

        library.new-<stamp>\ is a staged copy that never went live. Always safe to
        delete: it came from the release zip and is re-downloadable.

        Runs at the TOP of Install-SonicScout20Library, before this run stages anything, so
        every folder matching these patterns is by definition from an earlier run.

        Concurrency is NOT handled, and that is stated rather than quietly assumed:
        two installer instances would race here. They already share $script:TempPath
        and kill each other's processes, so single-instance is a pre-existing
        assumption of the whole script. Solving it here alone would be worse than
        naming it.

        A library kept deliberately (the library-destroy path) is named
        library-previous-<stamp>, OUTSIDE both patterns, so a tree the user was told to
        go and collect can never be swept away by this function.
    #>
    param([Parameter(Mandatory)][string]$LibraryRoot)

    $parent = Split-Path $LibraryRoot -Parent
    if (-not (Test-Path -LiteralPath $parent)) { return }

    $all = @(Get-ChildItem -LiteralPath $parent -Directory -Force -ErrorAction SilentlyContinue)
    # Newest stamp first. "yyyy-MM-dd_HHmmss" sorts lexically, so this is chronological.
    $olds = @($all | Where-Object { $_.Name -like 'library.old-*' } | Sort-Object Name -Descending)
    $news = @($all | Where-Object { $_.Name -like 'library.new-*' })
    if ($olds.Count -eq 0 -and $news.Count -eq 0) { return }

    $libExisted = Test-Path -LiteralPath $LibraryRoot

    # -- restore first --------------------------------------------------------
    if (-not $libExisted -and $olds.Count -gt 0) {
        $survivor = $olds[0]
        $restored = $false
        try {
            [IO.Directory]::Move($survivor.FullName, $LibraryRoot)
            $restored = $true
        }
        catch {
            # Called through PowerShell method syntax, the real IOException arrives
            # wrapped in a MethodInvocationException. Unwrap or the type is useless.
            $err = $_.Exception
            if ($err.InnerException) { $err = $err.InnerException }
            Write-Host ""
            Write-Host "$($script:BoxMargin)A previous run was interrupted. Your library is currently at:" -ForegroundColor Red
            Write-Host "$($script:BoxMargin)$($survivor.FullName)" -ForegroundColor White
            Write-Host "$($script:BoxMargin)It could not be moved back automatically ($($err.GetType().Name))." -ForegroundColor DarkGray
            Write-Host "$($script:BoxMargin)Rename that folder to 'library' to restore it, then run this again." -ForegroundColor Yellow
        }
        if (-not $restored) { return }

        Write-Host ""
        Write-Host "$($script:BoxMargin)A previous run was interrupted mid-install. Your library has been put" -ForegroundColor Yellow
        Write-Host "$($script:BoxMargin)back from $($survivor.Name) -- nothing was lost." -ForegroundColor Yellow
        $olds = @($olds | Select-Object -Skip 1)
    }

    # -- then sweep -----------------------------------------------------------
    foreach ($dir in $news) {
        Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($olds.Count -eq 0) { return }
    if ($libExisted) {
        # library\ was already in place, so these are spent copies of a swap that
        # finished. Safe to clear.
        foreach ($dir in $olds) {
            Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    else {
        # We just restored one. Anything still here predates it and may hold an even
        # older library -- reported, never deleted on a guess.
        Write-Host "$($script:BoxMargin)Older leftover folders were kept: $(($olds | ForEach-Object { $_.Name }) -join ', ')" -ForegroundColor DarkGray
    }
}

function Invoke-AtomicLibraryLayDown {
    <#
    .SYNOPSIS
        Stages the new library beside the live one, verifies it, then swaps it in with
        two renames. Never leaves a partial library.
    .DESCRIPTION
        Replaces a nuke-then-copy that left 89 of 92 files and no backup when a source
        file was locked. The sequence:

          S1  ensure the SonicScout2.0 root exists (and PROVE it)
          S2  stage    $SourceRoot\* -> library.new-<stamp>\
          S3  verify   staged tree against $SourceRoot, exactly
          S4  R1       library\           -> library.old-<stamp>\   WINDOW OPENS
          S5  R2       library.new-<stamp>\ -> library\             window closes
          S6  dispose of library.old-<stamp>\

        THE SWAP USES [IO.Directory]::Move ONLY. Move-Item is disqualified and must
        not be substituted for it, however much more PowerShell-ish it looks.
        Measured over 28 cases: [IO.Directory]::Move produced 0 partial results, and
        every failure left the source intact and the destination absent. Move-Item, on
        the same locked-file cases, left 88 FILES IN THE SOURCE AND 4 IN THE
        DESTINATION -- it walks the tree item by item through the FileSystem provider,
        which is the exact disease this function exists to cure.

        This is NOT lock-immune, and is not meant to be. A handle on any file inside
        library\ refuses R1 outright (see Get-LibraryLockReport). Refusal is the
        expected common path: it costs the install, never the library.

        S4 is skipped when library\ does not exist (fresh install), so that path has
        no dangerous window at all.
    .PARAMETER PreserveOld
        Keep the replaced library as library-previous-<stamp> instead of deleting it.
        Used when no successful backup was taken this run, so that path stops being
        a one-way door.
    .OUTPUTS
        pscustomobject @{ Ok; FailedStep; Reason; Lock; PreservedPath; FileCount }
        FailedStep is one of root/space/stage/verify/swap/rollback.
    #>
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$LibraryRoot,
        [switch]$PreserveOld
    )

    # Same stamp format as the backup folders, so the two read alike on disk.
    $stamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
    $root  = Split-Path $LibraryRoot -Parent
    $stage = Join-Path $root "library.new-$stamp"
    $old   = Join-Path $root "library.old-$stamp"

    $result = [pscustomobject]@{
        Ok            = $false
        FailedStep    = ''
        Reason        = ''
        Lock          = $null
        PreservedPath = $null
        FileCount     = 0
    }

    # -- S1: the root must really exist ---------------------------------------
    # New-Item -Force is not trusted here. Through a dangling reparse point it
    # reports success, returns zero objects, throws nothing even under
    # $ErrorActionPreference = 'Stop', and creates NOTHING -- the defect documented at
    # Get-SonicScout20BackupRoot. [IO.Directory]::Exists is the only thing that catches it.
    try {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
    }
    catch {
        $result.FailedStep = 'root'
        $result.Reason     = "$($_.Exception.GetType().Name): $($_.Exception.Message)"
        return $result
    }
    if (-not [IO.Directory]::Exists($root)) {
        $result.FailedStep = 'root'
        $result.Reason     = "The folder could not be created: $root"
        return $result
    }

    # -- source size, and the authoritative free-space check ------------------
    $srcFiles = @(Get-ChildItem -LiteralPath $SourceRoot -Recurse -File -Force -ErrorAction SilentlyContinue)
    $srcBytes = [int64]0
    if ($srcFiles.Count -gt 0) {
        $srcSum = ($srcFiles | Measure-Object -Property Length -Sum).Sum
        if ($null -ne $srcSum) { $srcBytes = [int64]$srcSum }
    }
    try {
        $driveRoot = [IO.Path]::GetPathRoot($root)
        $drive     = New-Object IO.DriveInfo($driveRoot)
        # IsReady first, exactly as Test-LibraryBackupPreflight does it: on a not-ready
        # drive AvailableFreeSpace yields nothing rather than throwing, and a null
        # compared as 0 would report a healthy machine as full.
        $freeBytes = if ($drive.IsReady) { $drive.AvailableFreeSpace } else { $null }
        if ($null -ne $freeBytes -and $freeBytes -lt $srcBytes) {
            $result.FailedStep = 'space'
            $result.Reason     = "Needs $([math]::Round($srcBytes / 1MB, 1)) MB on $driveRoot, $([math]::Round($freeBytes / 1MB, 1)) MB is free."
            return $result
        }
    }
    catch {
        Write-Verbose "Lay-down free-space check skipped: $($_.Exception.GetType().Name)."
    }

    # -- S2: stage ------------------------------------------------------------
    try {
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        Copy-Item -Path (Join-Path $SourceRoot '*') -Destination $stage -Recurse -Force
    }
    catch {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        $result.FailedStep = 'stage'
        $result.Reason     = "$($_.Exception.GetType().Name): $($_.Exception.Message)"
        return $result
    }

    # -- S3: verify -----------------------------------------------------------
    # -ne, NOT the -lt the backup verify uses. That -lt exists because the backup's
    # source is the LIVE library\, where Get-ChildItem -Recurse refuses to descend a
    # user-made junction while Copy-Item -Recurse copies straight through it, so the
    # destination legitimately ends up larger. This source is Expand-Archive output,
    # and zip extraction creates no reparse points -- measured: 0 in the payload. So
    # the counts must match exactly, and exact comparison also catches a surplus that
    # -lt would wave through.
    $stageFiles = @(Get-ChildItem -LiteralPath $stage -Recurse -File -Force -ErrorAction SilentlyContinue)
    $stageBytes = [int64]0
    if ($stageFiles.Count -gt 0) {
        $stageSum = ($stageFiles | Measure-Object -Property Length -Sum).Sum
        if ($null -ne $stageSum) { $stageBytes = [int64]$stageSum }
    }
    if ($stageFiles.Count -ne $srcFiles.Count -or $stageBytes -ne $srcBytes) {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        $result.FailedStep = 'verify'
        $result.Reason     = "staged $($stageFiles.Count) of $($srcFiles.Count) files, $stageBytes of $srcBytes bytes."
        return $result
    }

    # -- S4: R1 ---------------------------------------------------------------
    $hadLibrary = Test-Path -LiteralPath $LibraryRoot
    if ($hadLibrary) {
        try {
            [IO.Directory]::Move($LibraryRoot, $old)
        }
        catch {
            # Nothing has been touched yet. The staged tree goes, library\ stays.
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
            $err = $_.Exception
            if ($err.InnerException) { $err = $err.InnerException }
            $result.FailedStep = 'swap'
            $result.Reason     = "$($err.GetType().Name): $($err.Message)"
            $result.Lock       = Get-LibraryLockReport -Path $LibraryRoot
            return $result
        }
    }

    # -- S5: R2. THE DANGEROUS WINDOW IS OPEN FROM HERE ------------------------
    # Retried because Step 0 found no case where R1 succeeds and R2/rollback fails:
    # the locks that would threaten this window refuse R1 outright, so anything
    # arriving here was acquired INSIDE the window and is transient by nature. Three
    # attempts, then stop -- never spin.
    $moved = $false
    for ($attempt = 1; $attempt -le 3 -and -not $moved; $attempt++) {
        try {
            [IO.Directory]::Move($stage, $LibraryRoot)
            $moved = $true
        }
        catch {
            Write-Verbose "Lay-down R2 attempt $attempt failed: $($_.Exception.GetType().Name)."
            Start-Sleep -Milliseconds 400
        }
    }

    if (-not $moved) {
        $rolled  = $false
        $rollErr = $null
        if ($hadLibrary) {
            for ($attempt = 1; $attempt -le 3 -and -not $rolled; $attempt++) {
                try {
                    [IO.Directory]::Move($old, $LibraryRoot)
                    $rolled = $true
                }
                catch {
                    $rollErr = $_.Exception
                    if ($rollErr.InnerException) { $rollErr = $rollErr.InnerException }
                    Start-Sleep -Milliseconds 400
                }
            }
        }
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue

        if ($rolled -or -not $hadLibrary) {
            # Rolled back, or there was never a library to lose. Nothing lost either way.
            $result.FailedStep = 'swap'
            $result.Reason     = 'The new library could not be moved into place.'
        }
        else {
            # The one genuinely bad state. Never seen in 28 measured cases, but a handle
            # taken inside the window is a real race, so it is handled rather than assumed away.
            $result.FailedStep    = 'rollback'
            $result.PreservedPath = $old
            $result.Reason        = if ($rollErr) { "$($rollErr.GetType().Name): $($rollErr.Message)" } else { 'The library could not be moved back.' }
        }
        return $result
    }

    # -- S6: dispose of the replaced tree -------------------------------------
    if ($hadLibrary) {
        if ($PreserveOld) {
            $preserved = Join-Path $root "library-previous-$stamp"
            try {
                [IO.Directory]::Move($old, $preserved)
                $result.PreservedPath = $preserved
            }
            catch {
                # Could not rename it aside. Name where it actually is instead of
                # deleting what may be the only surviving copy.
                Write-Verbose "Could not rename the replaced library aside: $($_.Exception.GetType().Name)."
                $result.PreservedPath = $old
            }
        }
        else {
            # Non-fatal. A tree left here is picked up by Restore-InterruptedLibrarySwap
            # on the next run, and the swap itself has already succeeded.
            Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $result.Ok        = $true
    $result.FileCount = @(Get-ChildItem -LiteralPath $LibraryRoot -Recurse -File -ErrorAction SilentlyContinue).Count
    return $result
}

function Write-LibraryLayDownFailure {
    <#
    .SYNOPSIS
        Renders a failed lay-down. The refusal case is the COMMON path, not an error,
        and is worded accordingly.
    .DESCRIPTION
        The raw exception is deliberately not echoed as the cause. R1's message is
        "Access to the path '...\library' is denied.", which names the DIRECTORY, reads
        as a permissions problem, and points at a path the user can see is fine. The
        real cause is a handle on a file inside it.
    #>
    param([Parameter(Mandatory)]$Result)

    Write-Host ""
    if ($Result.FailedStep -eq 'rollback') {
        Write-Host "$($script:BoxMargin)The install was interrupted at the worst moment and your library is" -ForegroundColor Red
        Write-Host "$($script:BoxMargin)currently in this folder:" -ForegroundColor Red
        Write-Host "$($script:BoxMargin)$($Result.PreservedPath)" -ForegroundColor White
        Write-Host "$($script:BoxMargin)Nothing was deleted. Rename that folder to 'library' to put it back --" -ForegroundColor Yellow
        Write-Host "$($script:BoxMargin)or just run this installer again and it will do it for you." -ForegroundColor Yellow
        return
    }

    Write-Host "$($script:BoxMargin)Your library was not changed." -ForegroundColor Green
    Write-Host ""

    if ($Result.FailedStep -eq 'swap') {
        Write-Host "$($script:BoxMargin)Something on this PC is still using it, so the new library could not" -ForegroundColor Yellow
        Write-Host "$($script:BoxMargin)be put in place. Nothing was deleted -- your library is exactly as it was." -ForegroundColor DarkGray

        if ($Result.Lock -and $Result.Lock.Files.Count -gt 0) {
            Write-Host ""
            Write-Host "$($script:BoxMargin)  Still in use:" -ForegroundColor Yellow
            foreach ($f in $Result.Lock.Files) {
                Write-Host "$($script:BoxMargin)    $f" -ForegroundColor DarkGray
            }
            if ($Result.Lock.More -gt 0) {
                Write-Host "$($script:BoxMargin)    (and $($Result.Lock.More) more)" -ForegroundColor DarkGray
            }
        }

        # ALWAYS reached, whether or not a file was named. Naming the file without
        # saying what to do about it leaves the user with a path and no next step --
        # and the process list is empty whenever the holder is something we do not
        # recognise, which is exactly when the generic advice matters most.
        Write-Host ""
        if ($Result.Lock -and $Result.Lock.Processes.Count -gt 0) {
            Write-Host "$($script:BoxMargin)  Close these, then choose [r]:" -ForegroundColor Yellow
            foreach ($p in $Result.Lock.Processes) {
                Write-Host "$($script:BoxMargin)    $p" -ForegroundColor White
            }
        } else {
            Write-Host "$($script:BoxMargin)  Close Peace, HeSuVi, the E-APO editor, or any text editor or Explorer" -ForegroundColor Yellow
            Write-Host "$($script:BoxMargin)  window open on the library folder, then choose [r]." -ForegroundColor Yellow
        }
        return
    }

    switch ($Result.FailedStep) {
        'space'  { Write-Host "$($script:BoxMargin)There is not enough free disk space to install it. $($Result.Reason)" -ForegroundColor Yellow }
        'verify' { Write-Host "$($script:BoxMargin)The downloaded library did not copy completely, so it was discarded." -ForegroundColor Yellow
                   Write-Host "$($script:BoxMargin)$($Result.Reason)" -ForegroundColor DarkGray }
        'stage'  { Write-Host "$($script:BoxMargin)The new library could not be written next to your existing one." -ForegroundColor Yellow
                   Write-Host "$($script:BoxMargin)$($Result.Reason)" -ForegroundColor DarkGray }
        default  { Write-Host "$($script:BoxMargin)The install folder could not be prepared." -ForegroundColor Yellow
                   Write-Host "$($script:BoxMargin)$($Result.Reason)" -ForegroundColor DarkGray }
    }
}

function Install-SonicScout20Library {
    <#
    .SYNOPSIS
        Fetches the latest SonicScout2.0 library release (.zip asset) and lays it down in
        the canonical SonicScout2.0 root, automating the old manual "drag the library
        folder into E-APO config" ritual. Any existing library is backed up to a dated
        folder (unless -SkipBackup), then replaced by an atomic stage-verify-swap
        (Invoke-AtomicLibraryLayDown; no state file). The library is load-bearing, so
        hard failures surface with a retry affordance (never silently pass).
    .PARAMETER SkipBackup
        Skip the dated backup of the existing library. Used by the Setup fresh-install
        path when there is no real library worth preserving.
    #>
    param([switch]$SkipBackup)

    $libRoot = Join-Path $script:SonicScout20Root "library"
    # A complete checkout/package is authoritative; no release API is needed offline.
    $bundle = Get-BundledLibraryPath
    if ($bundle -and [IO.Path]::GetFullPath($bundle) -ne [IO.Path]::GetFullPath($libRoot)) {
        $result = Invoke-AtomicLibraryLayDown -SourceRoot $bundle -LibraryRoot $libRoot -PreserveOld
        if ($result.Ok) { Write-Host 'Bundled SonicScout library installed.'; return $true }
        Write-LibraryLayDownFailure -Result $result
        return $false
    }

    # BEFORE anything else, including the pre-flight. An earlier run killed between
    # the two renames leaves the real library under library.old-<stamp>\ with no
    # library\ at all, and every check below would then read a healthy machine as
    # having no library. This restores it. Runs before this run stages anything, so
    # whatever it finds is by definition not ours.
    Restore-InterruptedLibrarySwap -LibraryRoot $libRoot

    # Set by the [r] affordance below so the next backup attempt re-probes the root
    # instead of reusing a cached failure. Declared here because StrictMode faults on
    # reading it before the first assignment.
    $refreshRoot = $false

    # Pre-flight BEFORE the fetch. Neither of these can be fixed by downloading, and
    # discovering them afterwards costs the user a transfer and hides the cause behind
    # a mid-copy error. Skipped when no root resolves at all -- that case is already
    # handled properly by the backup itself and its menu.
    if (-not $SkipBackup -and (Test-Path $libRoot)) {
        $preflightRoot = Get-SonicScout20BackupRoot
        if ($preflightRoot -and -not (Test-LibraryBackupPreflight -LibraryPath $libRoot -BackupRoot $preflightRoot)) {
            Write-Host "$($script:BoxMargin)Nothing was downloaded and your library was not touched." -ForegroundColor Yellow
            return $false
        }
    }

    :libRetry while ($true) {
        Write-Host "$($script:BoxMargin)Fetching SonicScout2.0 library release..." -ForegroundColor Cyan

        # --- Resolve the release .zip asset name ------------------------------
        # Single source of truth: the CDN latest-version.txt (same file the update
        # -check reads). Derive the standard asset name SonicScout2.0-<version>.zip from
        # it; fall back to the hardcoded $script:LibraryReleaseAsset when the CDN
        # version is unreachable/empty (e.g. test mode with no version file on R2).
        $assetName   = $script:LibraryReleaseAsset
        $downloadUrl = $null
        $githubAssetName = $null
        $githubAssetUrl  = $null
        try {
            $verUrl = "$($script:LibraryMirrorBase.TrimEnd('/'))/SonicScout2.0/latest-version.txt"
            $verResp = Invoke-WebRequest -Uri $verUrl -UseBasicParsing -ErrorAction Stop
            $cdnVersion = ((("$($verResp.Content)") -split "`r?`n")[0]).Trim()
            if ($cdnVersion -and $cdnVersion -notmatch '[\\/\s]') {
                $assetName = "SonicScout2.0-$cdnVersion.zip"
                Write-Host "$($script:BoxMargin)Library version (CDN): $cdnVersion" -ForegroundColor DarkGray
            }
        } catch {
            Write-Host "$($script:BoxMargin)CDN version lookup failed; continuing with fallback sources." -ForegroundColor DarkGray
        }

        # Always resolve the latest GitHub zip asset so we can fall back to it if the
        # mirror misses or the pinned/default mirror filename is stale.
        try {
            $headers = @{ 'Accept' = 'application/vnd.github+json'; 'User-Agent' = 'SonicScout2.0-Installer' }
            $release = Invoke-RestMethod $script:LibraryReleaseApi -Headers $headers -ErrorAction Stop
            $zipAssets = @($release.assets | Where-Object { Test-OrdinalContains "$($_.name)" '.zip' })
            $asset = @($zipAssets | Where-Object { $_.name -match '^SonicScout2\.0-.*\.zip$' } | Select-Object -First 1)
            if (-not $asset -or $asset.Count -eq 0) {
                $asset = @($zipAssets | Select-Object -First 1)
            }
            if ($asset -and $asset.Count -gt 0) {
                $githubAssetName = $asset[0].name
                $githubAssetUrl  = $asset[0].browser_download_url
                if ($script:UseGitHubRelease) {
                    $assetName = $githubAssetName
                    $downloadUrl = $githubAssetUrl
                }
            }
        } catch {
            Write-Host "$($script:BoxMargin)GitHub release lookup failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }

        if (-not (Test-Path $script:TempPath)) { New-Item -ItemType Directory -Path $script:TempPath -Force | Out-Null }
        $zipPath = Join-Path $script:TempPath "SonicScout2.0-library.zip"
        $downloaded = $false

        # Try the GitHub asset, then the R2 mirror. Get-UrlToFile shows a live byte
        # counter (this used to be silent for the whole transfer) and enforces a
        # timeout, which neither of these fetches had at all.
        if ($downloadUrl) {
            $downloaded = Get-UrlToFile -Url $downloadUrl -OutFile $zipPath -Label "Downloading library..." -TimeoutSeconds 300
        }
        if (-not $downloaded) {
            $mirrorName = if ($assetName) { $assetName } else { 'SonicScout2.0-library.zip' }
            $mirrorUrl  = "$($script:LibraryMirrorBase.TrimEnd('/'))/SonicScout2.0/$mirrorName"
            Write-Host "$($script:BoxMargin)Trying mirror..." -ForegroundColor DarkGray
            $downloaded = Get-UrlToFile -Url $mirrorUrl -OutFile $zipPath -Label "Downloading library..." -TimeoutSeconds 300
        }
        if (-not $downloaded -and $githubAssetUrl -and ($githubAssetUrl -ne $downloadUrl)) {
            Write-Host "$($script:BoxMargin)Mirror failed; trying GitHub release asset..." -ForegroundColor DarkGray
            $downloaded = Get-UrlToFile -Url $githubAssetUrl -OutFile $zipPath -Label "Downloading library..." -TimeoutSeconds 300
            if ($downloaded -and $githubAssetName) {
                Write-Host "$($script:BoxMargin)Downloaded from GitHub: $githubAssetName" -ForegroundColor DarkGray
            }
        }

        # Final online fallback failed. If setup is running from a local repo checkout,
        # copy the bundled library folder directly so profile setup can still proceed.
        if (-not $downloaded) {
            $localBundle = $null
            if ($PSScriptRoot) {
                # Source checkout: <repo>\powershell\Install-SonicScout2.0.ps1 and
                # <repo>\library. Published app: installer and library are siblings.
                $repoRoot = Split-Path $PSScriptRoot -Parent
                $candidates = @(
                    (Join-Path $PSScriptRoot 'library'),
                    (Join-Path $repoRoot 'library')
                )
                foreach ($candidate in $candidates) {
                    if (-not (Test-Path -LiteralPath $candidate)) { continue }
                    $required = @('BF6', 'BO6', 'BO7', 'version.txt')
                    $ok = $true
                    foreach ($req in $required) {
                        if (-not (Test-Path -LiteralPath (Join-Path $candidate $req))) { $ok = $false; break }
                    }
                    if ($ok) {
                        $localBundle = $candidate
                        break
                    }
                }
            }

            if ($localBundle) {
                Write-Host "$($script:BoxMargin)Remote download failed; using bundled local library." -ForegroundColor Yellow
                $backupDest = $null
                $backupFailed = $false
                if (-not $SkipBackup -and (Test-Path $libRoot)) {
                    $backupDest = Backup-SonicScout20Library -RefreshBackupRoot:$refreshRoot
                    $refreshRoot = $false
                    if ($backupDest -is [bool] -and -not $backupDest) { $backupFailed = $true }
                }

                if (-not $backupFailed) {
                    # Atomic, same as the download path: stage beside library\, verify,
                    # then swap with two renames. The old nuke-then-copy left a partial
                    # library if any source file was locked, with the user's squig.link
                    # EQs already destroyed. PreserveOld covers the case where the
                    # backup failed or was skipped, so this is never a one-way door.
                    $noBackupTaken = (-not $backupDest) -or ($backupDest -is [bool])
                    $layDown = $null
                    try {
                        $layDown = Invoke-AtomicLibraryLayDown -SourceRoot $localBundle -LibraryRoot $libRoot -PreserveOld:$noBackupTaken
                    }
                    catch {
                        Write-Host ""
                        Write-Host "$($script:BoxMargin)Could not install the local library: $($_.Exception.GetType().Name)" -ForegroundColor Red
                        Write-Host "$($script:BoxMargin)$($_.Exception.Message)" -ForegroundColor DarkGray
                        $layDown = $null
                    }

                    if ($layDown -and $layDown.Ok) {
                        if ($backupDest -and -not ($backupDest -is [bool])) {
                            Write-Host "$($script:BoxMargin)Previous library backed up to: $backupDest" -ForegroundColor DarkGray
                        }
                        if ($layDown.PreservedPath) {
                            Write-Host "$($script:BoxMargin)Your previous library was kept here: $($layDown.PreservedPath)" -ForegroundColor Cyan
                        }
                        Write-Host "$($script:BoxMargin)SonicScout2.0 library installed from local bundle ($($layDown.FileCount) files)." -ForegroundColor Green
                        return $true
                    }

                    if ($layDown) {
                        Write-LibraryLayDownFailure -Result $layDown
                    }
                    Write-Host "$($script:BoxMargin)Local bundle install was not applied." -ForegroundColor Yellow
                }
                else {
                    Write-Host "$($script:BoxMargin)Backup failed; local bundle install was not applied." -ForegroundColor Yellow
                }
            }
        }

        if ($downloaded) {
            # --- Extract to staging, then normalize the payload root ---
            $staging = Join-Path $script:TempPath "SonicScout2.0-library-extract"
            if (Test-Path $staging) { Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue }
            New-Item -ItemType Directory -Path $staging -Force | Out-Null
            $srcRoot = $null
            try {
                Expand-Archive -LiteralPath $zipPath -DestinationPath $staging -Force
                $srcRoot = Resolve-LibraryPayloadRoot -StagingDir $staging
            } catch {
                Write-Host "$($script:BoxMargin)Could not extract the library zip: $($_.Exception.Message)" -ForegroundColor Yellow
            }

            if ($srcRoot) {
                # Normalize to the full/long path form so Copy-Item has a valid source.
                $srcRoot = (Get-Item -LiteralPath $srcRoot).FullName

                # --- Back up any existing library (dated), then swap in the new one ---
                # This inner loop is the fix for the reported dead end. The download
                # and extract above have already succeeded, so retrying THEM cannot
                # clear a filesystem problem -- yet re-downloading was the only thing
                # the old menu offered, which made a failed backup an inescapable loop.
                # Everything below retries the BACKUP, and the staging tree is kept so
                # no option here costs another transfer.
                #
                # HOISTED out of the loop on purpose. A refused lay-down leaves library\
                # byte-identical (the swap is atomic), so a backup taken on an earlier
                # pass is still a faithful copy of exactly the same tree. Re-running it
                # per retry would pile up dated duplicates -- and with a lock now the
                # expected reason to retry, that pile would be the common case.
                $backupDest   = $null
                $backupWaived = $false
                :backupRetry while ($true) {

                    $backupFailed = $false
                    $proceed      = $false

                    if ($SkipBackup -or $backupWaived -or -not (Test-Path $libRoot)) {
                        $proceed = $true
                    } elseif ($backupDest -and -not ($backupDest -is [bool]) -and (Test-Path -LiteralPath "$backupDest")) {
                        # Already have one from an earlier pass of this loop, and library\
                        # is provably unchanged since. Reuse it.
                        $proceed = $true
                    } else {
                        # -is [bool] rather than -eq $false: a returned path string
                        # compared against $false would coerce and could never match,
                        # so the guard has to test the type. $null (nothing to back up)
                        # is not a failure.
                        $backupDest  = Backup-SonicScout20Library -RefreshBackupRoot:$refreshRoot
                        $refreshRoot = $false
                        if ($backupDest -is [bool] -and -not $backupDest) { $backupFailed = $true }
                        else { $proceed = $true }
                    }

                    if ($backupFailed) {
                        # The existing library is left exactly as it is: the user's
                        # squig.link EQs live inside the tree the swap would replace, and
                        # there would be nothing to restore them from.
                        $menuOpen = $true
                        while ($menuOpen) {
                            Write-Host ""
                            Write-Host "$($script:BoxMargin)Could not back up your existing library, so it was left untouched." -ForegroundColor Red
                            Write-Host "$($script:BoxMargin)The download already worked -- retrying that cannot fix this." -ForegroundColor DarkGray
                            Write-Host ""
                            $null = Write-CenteredBlock @(
                                @{ Text = '[r] Try the backup again'; Color = 'Yellow' }
                                @{ Text = '[o] Show me the library folder so I can copy it myself'; Color = 'White' }
                                @{ Text = '[b] Install anyway - REPLACES your library'; Color = 'Red' }
                                @{ Text = '[d] Open an issue for help'; Color = 'White' }
                                @{ Text = '[s] Skip - continue without the library'; Color = 'DarkGray' }
                            )
                            Write-Host ""
                            Write-Host "$($script:BoxMargin)" -NoNewline
                            Write-Host "Choice: " -ForegroundColor Yellow -NoNewline
                            $bkChoice = "$(Read-Host)".ToLower()

                            if ($bkChoice -eq 's') {
                                Write-Host "$($script:BoxMargin)Skipping library. Tunes and bundled VST/JSFX will be missing." -ForegroundColor Yellow
                                Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
                                return $false
                            }
                            elseif ($bkChoice -eq 'r') {
                                # Re-probe instead of trusting the cache. The whole
                                # point of this option is that the user has just fixed
                                # the folder, and a cached failure would ignore that.
                                $refreshRoot = $true
                                $menuOpen    = $false
                            }
                            elseif ($bkChoice -eq 'o') {
                                # Path printed as plain text FIRST. Explorer launched
                                # from an elevated process does not reliably surface in
                                # the user's session, and with nothing on screen the
                                # option looks like it did nothing at all.
                                Write-Host ""
                                Write-Host "$($script:BoxMargin)Your library is here:" -ForegroundColor Cyan
                                Write-Host "$($script:BoxMargin)$libRoot" -ForegroundColor White
                                Write-Host "$($script:BoxMargin)Copy it somewhere safe, then choose [b] to install the new one." -ForegroundColor DarkGray
                                Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$libRoot`""
                            }
                            elseif ($bkChoice -eq 'd') {
                                Start-Process 'https://github.com/sensoredrooster/SonicScout2.0/issues'
                                Write-Host "$($script:BoxMargin)Opened in browser." -ForegroundColor Green
                            }
                            elseif ($bkChoice -eq 'b') {
                                Write-Host ""
                                Write-Host "$($script:BoxMargin)This REPLACES your current library. Any squig.link EQs you added" -ForegroundColor Red
                                Write-Host "$($script:BoxMargin)are removed, and the failed backup means they cannot be restored." -ForegroundColor Red
                                Write-Host "$($script:BoxMargin)Type 'yes' to replace it, or anything else to go back: " -ForegroundColor Yellow -NoNewline
                                if ("$(Read-Host)" -eq 'yes') {
                                    $backupDest = $null
                                    # Remembered, so a later lay-down retry does not
                                    # re-ask a question already answered. It also keeps
                                    # $backupDest null, which is what turns PreserveOld
                                    # on and stops [b] being a one-way door.
                                    $backupWaived = $true
                                    $proceed      = $true
                                    $menuOpen     = $false
                                }
                            }
                        }
                    }

                    if (-not $proceed) { continue backupRetry }

                    # Atomic: stage beside library\, verify, then swap in with two
                    # renames. It can REFUSE -- any process holding a file in library\
                    # open blocks the rename -- but it can never half-finish, so the
                    # failure paths below all leave the library exactly as it was.
                    #
                    # PreserveOld keeps the replaced tree as library-previous-<stamp>
                    # whenever no backup was taken this run. That is the [b] path, where
                    # the backup failed and this would otherwise be a one-way door.
                    $noBackupTaken = (-not $backupDest) -or ($backupDest -is [bool])

                    # Still guarded. Not for a half-cleared library -- that state no
                    # longer exists -- but because this function must never let a hard
                    # failure escape silently, and a crash is not "surfacing" it.
                    $layDown = $null
                    try {
                        $layDown = Invoke-AtomicLibraryLayDown -SourceRoot $srcRoot -LibraryRoot $libRoot -PreserveOld:$noBackupTaken
                    }
                    catch {
                        Write-Host ""
                        Write-Host "$($script:BoxMargin)Could not install the new library: $($_.Exception.GetType().Name)" -ForegroundColor Red
                        Write-Host "$($script:BoxMargin)$($_.Exception.Message)" -ForegroundColor DarkGray
                        continue backupRetry
                    }

                    if (-not $layDown.Ok) {
                        Write-LibraryLayDownFailure -Result $layDown

                        # A MENU, not a bare retry. The message above tells the user to
                        # close something and choose [r], and looping straight back would
                        # spin on the same lock forever without ever offering it -- fast,
                        # silent, and impossible to escape. Refusal is now the expected
                        # common path, so this is the path that has to behave.
                        $layMenuOpen = $true
                        while ($layMenuOpen) {
                            Write-Host ""
                            $null = Write-CenteredBlock @(
                                @{ Text = '[r] Try again - I closed what was using it'; Color = 'Yellow' }
                                @{ Text = '[o] Show me the library folder'; Color = 'White' }
                                @{ Text = '[s] Skip - keep my current library as it is'; Color = 'DarkGray' }
                            )
                            Write-Host ""
                            Write-Host "$($script:BoxMargin)" -NoNewline
                            Write-Host "Choice: " -ForegroundColor Yellow -NoNewline
                            $layChoice = "$(Read-Host)".ToLower()

                            if ($layChoice -eq 'r') {
                                $layMenuOpen = $false
                            }
                            elseif ($layChoice -eq 's') {
                                Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
                                Write-Host "$($script:BoxMargin)Skipped. Your library was not changed." -ForegroundColor Yellow
                                return $false
                            }
                            elseif ($layChoice -eq 'o') {
                                # After a failed rollback the library is NOT at $libRoot,
                                # so point at where it actually is.
                                $showPath = if ($layDown.PreservedPath) { $layDown.PreservedPath } else { $libRoot }
                                Write-Host ""
                                Write-Host "$($script:BoxMargin)Your library is here:" -ForegroundColor Cyan
                                Write-Host "$($script:BoxMargin)$showPath" -ForegroundColor White
                                Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$showPath`""
                            }
                        }
                        continue backupRetry
                    }

                    Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
                    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

                    if ($backupDest -and -not ($backupDest -is [bool])) {
                        Write-Host "$($script:BoxMargin)Previous library backed up to: $backupDest" -ForegroundColor DarkGray
                    }
                    if ($layDown.PreservedPath) {
                        Write-Host "$($script:BoxMargin)Your previous library was kept here: $($layDown.PreservedPath)" -ForegroundColor Cyan
                    }
                    Write-Host "$($script:BoxMargin)SonicScout2.0 library installed ($($layDown.FileCount) files)." -ForegroundColor Green
                    return $true
                }
            }
            Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
        }

        # --- Failure: surface clearly and offer retry (library is load-bearing) ---
        Write-Host ""
        Write-Host "$($script:BoxMargin)ERROR: Could not install the SonicScout2.0 library." -ForegroundColor Red
        Write-Host "$($script:BoxMargin)Get it manually from: https://github.com/sensoredrooster/SonicScout2.0/releases" -ForegroundColor Yellow
        Write-Host ""
        $null = Write-CenteredBlock @(
            @{ Text = '[r] Retry library download'; Color = 'Yellow' }
            @{ Text = '[d] Open Discord for help';  Color = 'White' }
            @{ Text = '[s] Skip - continue without the library'; Color = 'DarkGray' }
        )
        Write-Host ""
        Write-Host "$($script:BoxMargin)" -NoNewline
        Write-Host "Choice: " -ForegroundColor Yellow -NoNewline
        $libChoice = Read-Host
        switch ($libChoice.ToLower()) {
            'r' { continue libRetry }
            'd' {
                Start-Process 'https://github.com/sensoredrooster/SonicScout2.0/issues'
                Write-Host "$($script:BoxMargin)Opened in browser. Press [r] then Enter to retry, or [s] to skip." -ForegroundColor Green
                $again = Read-Host
                if ($again.ToLower() -eq 's') { return $false }
                continue libRetry
            }
            's' {
                Write-Host "$($script:BoxMargin)Skipping library. Tunes and bundled VST/JSFX will be missing." -ForegroundColor Yellow
                return $false
            }
            default { continue libRetry }
        }
    }
}

function Get-BundledLibraryPath {
    <#
    .SYNOPSIS
        Resolves the bundled SonicScout2.0 library root shipped with this release.
        Prefers the library next to the installer ($PSScriptRoot\..\library),
        then falls back to the installed SonicScout2.0 library folder.
    #>
    $candidates = @()
    if ($PSScriptRoot) {
        $candidates += (Join-Path $PSScriptRoot "library")
        $candidates += (Join-Path (Split-Path $PSScriptRoot -Parent) "library")
    }
    $candidates += (Join-Path $env:ProgramFiles "EqualizerAPO\config\SonicScout2.0\library")
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    return $null
}

function Install-JsfxPlugins {
    <#
    .SYNOPSIS
        Copies the bundled SonicScout2.0 JSFX plugins into the ReaPlugs JS directory.
        The release is self-contained; no download.
    #>

    $jsfxDir = Join-Path $env:ProgramFiles "VSTPlugins\ReaPlugs\JS\Effects\SonicScout2.0"
    $file1 = Join-Path $jsfxDir "ss_spatial_engine.jsfx"
    $file2 = Join-Path $jsfxDir "ss_stereo_spatial_enhancer.jsfx"

    # Skip if both already installed
    if ((Test-Path $file1) -and (Test-Path $file2)) {
        Write-Host "$($script:BoxMargin)JSFX plugins already installed." -ForegroundColor Green
        return $true
    }

    # Check ReaPlugs is installed
    $reaPlugsDir = Join-Path $env:ProgramFiles "VSTPlugins\ReaPlugs"
    if (-not (Test-Path $reaPlugsDir)) {
        Write-Host "$($script:BoxMargin)WARNING: ReaPlugs not found. Install ReaPlugs first." -ForegroundColor Yellow
        return $false
    }

    # Locate the bundled jsfx\ in the release
    $bundled = Get-BundledLibraryPath
    $srcDir = if ($bundled) { Join-Path $bundled "jsfx" } else { $null }
    if (-not $srcDir -or -not (Test-Path $srcDir)) {
        Write-Host "$($script:BoxMargin)WARNING: bundled jsfx\ not found in the release; skipping JSFX install." -ForegroundColor Yellow
        return $false
    }

    $srcFiles = @(Get-ChildItem -Path $srcDir -Filter '*.jsfx' -File -ErrorAction SilentlyContinue)
    if ($srcFiles.Count -eq 0) {
        Write-Host "$($script:BoxMargin)WARNING: no .jsfx files in the bundle." -ForegroundColor Yellow
        return $false
    }

    Write-Host "$($script:BoxMargin)Installing JSFX plugins..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $jsfxDir -Force | Out-Null

    foreach ($f in $srcFiles) {
        Copy-Item -Path $f.FullName -Destination (Join-Path $jsfxDir $f.Name) -Force
    }

    # Verify the two known plugins landed
    if ((Test-Path $file1) -and (Test-Path $file2)) {
        Write-Host "$($script:BoxMargin)JSFX plugins installed to $jsfxDir" -ForegroundColor Green
        return $true
    }

    Write-Host "$($script:BoxMargin)WARNING: JSFX plugin verification failed." -ForegroundColor Yellow
    return $false
}

function Install-VstPlugins {
    <#
    .SYNOPSIS
        Copies the bundled SonicScout2.0 VST DLL(s) into VSTPlugins\SonicScout2.0
        (the absolute path the native-VST configs reference). No download.
    #>

    $vstDir = Join-Path $env:ProgramFiles "VSTPlugins\SonicScout2.0"

    # Locate the bundled vst\ in the release
    $bundled = Get-BundledLibraryPath
    $srcDir = if ($bundled) { Join-Path $bundled "vst" } else { $null }
    if (-not $srcDir -or -not (Test-Path $srcDir)) {
        Write-Host "$($script:BoxMargin)WARNING: bundled vst\ not found in the release; skipping VST install." -ForegroundColor Yellow
        return $false
    }

    $srcDlls = @(Get-ChildItem -Path $srcDir -Filter '*.dll' -File -ErrorAction SilentlyContinue)
    if ($srcDlls.Count -eq 0) {
        Write-Host "$($script:BoxMargin)WARNING: no VST DLLs in the bundle." -ForegroundColor Yellow
        return $false
    }

    # Skip the copy if every bundled DLL is already present
    $allPresent = $true
    foreach ($dll in $srcDlls) {
        if (-not (Test-Path (Join-Path $vstDir $dll.Name))) { $allPresent = $false; break }
    }

    if (-not $allPresent) {
        Write-Host "$($script:BoxMargin)Installing SonicScout2.0 VST..." -ForegroundColor Cyan
        New-Item -ItemType Directory -Path $vstDir -Force | Out-Null
        foreach ($dll in $srcDlls) {
            Copy-Item -Path $dll.FullName -Destination (Join-Path $vstDir $dll.Name) -Force
        }
    }

    if ($allPresent) {
        Write-Host "$($script:BoxMargin)SonicScout2.0 VST already installed." -ForegroundColor Green
    } else {
        Write-Host "$($script:BoxMargin)SonicScout2.0 VST installed to $vstDir" -ForegroundColor Green
    }
    return $true
}

function Ensure-ManagedActiveConfig {
    <#
    .SYNOPSIS
        Creates the SonicScout-managed active-config directory and placeholder files used by
        the managed E-APO config, while preserving the user-set output boost.
    #>
    param()

    $activeDir = Join-Path $script:SonicScout20Root "active-config"
    $rootBoost = Join-Path $script:SonicScout20Root "boost.txt"
    $activeBoost = Join-Path $activeDir "boost.txt"

    New-Item -ItemType Directory -Path $activeDir -Force | Out-Null

    if (-not (Test-Path -LiteralPath $rootBoost)) {
        $boostLines = @(
            "# SonicScout2.0 Output Boost -- set your dB below and save. 0 dB = off."
            "# config.txt includes this last on every chain; E-APO reloads it live."
            "Preamp: 0 dB"
        )
        Set-Content -Path $rootBoost -Value ($boostLines -join "`r`n") -Force
    }

    if (Test-Path -LiteralPath $rootBoost) {
        Copy-Item -Path $rootBoost -Destination $activeBoost -Force
    } else {
        Set-Content -Path $activeBoost -Value "Preamp: 0 dB" -Force
    }

    $defaultFiles = @{
        'eq.txt' = @(
            '# Managed EQ - no profile active yet.'
            '# Preamp: 0 dB'
        )
        'prehesuvi.txt' = @(
            '# Pre-HeSuVi Processing'
            '# No profile active'
        )
        'posthesuvi.txt' = @(
            '# Post-HeSuVi Processing'
            '# No profile active'
        )
        '16chConfig.txt' = @(
            '# 16-channel tune placeholder'
            '# No 16ch profile active'
        )
    }

    foreach ($entry in $defaultFiles.GetEnumerator()) {
        $target = Join-Path $activeDir $entry.Key
        if (-not (Test-Path -LiteralPath $target)) {
            Set-Content -Path $target -Value ($entry.Value -join "`r`n") -Force
        }
    }
}

function Write-InitialConfig {
    <#
    .SYNOPSIS
        Writes the starter config.txt to the E-APO config folder.
        Always overwrites to ensure correct line order.

        The installer now writes the SonicScout-managed active-config directory and a
        dynamic config.txt that points at those files instead of the static library path.
    .PARAMETER RenderGuid8
        Resolved 8ch "SonicScout2.0" render endpoint GUID. When supplied, an active
        Device: line scopes the 8ch includes to that endpoint.
    .PARAMETER RenderGuid16
        Resolved 16ch "SonicScout2.0 +" render endpoint GUID. When supplied, a commented
        Device: line is emitted for the 16ch profile.
    #>
    param(
        [string]$RenderGuid8,
        [string]$RenderGuid16
    )

    $configFile = Join-Path $env:ProgramFiles "EqualizerAPO\config\config.txt"
    $boostFile  = Join-Path $script:SonicScout20Root "boost.txt"

    # ALWAYS back up before overwriting. Done here rather than at the call site so
    # no future caller can write config.txt without a backup being taken first.
    $null = Backup-EAPOConfigFile

    # Create the managed active-config folder once, and preserve the user-set boost.
    New-Item -ItemType Directory -Path $script:SonicScout20Root -Force | Out-Null
    Ensure-ManagedActiveConfig

    # Normalize a raw endpoint GUID to E-APO's lowercase-braced form.
    $normGuid = {
        param($g)
        if ([string]::IsNullOrWhiteSpace($g)) { return $null }
        $g = $g.Trim().ToLowerInvariant()
        if ($g -notmatch '^\{') { $g = '{' + $g + '}' }
        return $g
    }
    $g8  = & $normGuid $RenderGuid8
    $g16 = & $normGuid $RenderGuid16

    $device8Line  = if ($g8)  { "Device: SonicScout2.0 VB-Audio Virtual Cable $g8" } else { $null }
    $device16Line = if ($g16) { "Device: SonicScout2.0 + VB-Audio Virtual Cable $g16" } else { $null }
    $emit16 = [bool]($device8Line -and $device16Line)

    try {
        $lines = @()
        $lines += "# SonicScout2.0 config.txt"
        $lines += "# >>> Managed by SonicScout2.0 installer <<<"
        $lines += "# Managed files live in EqualizerAPO\config\SonicScout2.0\active-config\"
        $lines += "# Do not edit this section by hand; use the setup flow or profile wizard."
        if ($emit16) {
            $lines += "# Both chains are live and device-scoped."
        }
        $lines += ""

        $lines += "# ---- 8ch profile (SonicScout2.0) ----"
        if ($device8Line) { $lines += $device8Line }
        $lines += "Include: SonicScout2.0\active-config\prehesuvi.txt"
        $lines += "Include: HeSuVi\hesuvi.txt"
        $lines += "Include: SonicScout2.0\active-config\eq.txt"
        $lines += "Include: SonicScout2.0\active-config\posthesuvi.txt"
        $lines += "Include: SonicScout2.0\active-config\boost.txt"

        if ($emit16) {
            $lines += ""
            $lines += "# ---- 16ch profile (SonicScout2.0 +) ----"
            $lines += $device16Line
            $lines += "Include: SonicScout2.0\active-config\16chConfig.txt"
            $lines += "Include: SonicScout2.0\active-config\eq.txt"
            $lines += "Include: SonicScout2.0\active-config\boost.txt"
        }

        Set-Content -Path $configFile -Value ($lines -join "`r`n") -Force

        $script:ConfigIsPlaceholder = $true

        Write-Host ""
        Write-Host "$($script:BoxMargin)Managed config written to EqualizerAPO\config\config.txt" -ForegroundColor Green
        Write-Host "$($script:BoxMargin)Profiles are now built through SonicScout2.0\active-config\ files." -ForegroundColor DarkGray
        Write-Host "$($script:BoxMargin)The installer keeps the output boost file and the profile files separate." -ForegroundColor DarkGray
        Write-Host ""
        return $true
    } catch {
        Write-Host "$($script:BoxMargin)WARNING: Could not write config.txt: $_" -ForegroundColor Yellow
        return $false
    }
}

function Write-FolderReadme {
    <#
    .SYNOPSIS
        Writes the SonicScout2.0 folder's README.txt quick-reference card.
    .DESCRIPTION
        Called from the [1] Install path, NOT from Install-Eapo where this used to live.
        Only the caller knows whether config.txt ended up with one chain or two, and the
        card must never describe a chain the config does not contain -- see $TwoChains.

        Overwritten unconditionally on every run. The file holds no user content, and
        replacing a stale card is the whole point.

        Failure is non-fatal and only warns, matching the behaviour at the old site.
    .PARAMETER TwoChains
        Whether config.txt carries both device-scoped chains. Must be passed the same
        signal Write-InitialConfig uses for $emit16, so the card can never describe a
        chain the config does not actually contain (PATH A resolves no endpoints and
        gets a single unscoped 8ch chain).
    #>
    param([bool]$TwoChains)

    # Literal here-strings: the card interpolates nothing, and $ appears in no line.
    $card = @'
SonicScout2.0
=========

SonicScout2.0 Home.url               - SonicScout2.0 developer page
SonicScout2.0.url                   - SonicScout2.0 project page
E-APO Configuration Editor.lnk  - Equalizer APO Configuration Editor
LEQ Control Panel.lnk           - Loudness EQ control panel
boost.txt                       - Optional output boost (one Preamp line)
active-config\                  - Managed profile files (EQ + tune + boost)
library\                        - Static tune library and target curves

FIRST: finish your profile
  config.txt now points into EqualizerAPO\config\SonicScout2.0\active-config\.
  The installer creates those files and the profile wizard updates them when a
  game or headphone profile is selected. The library stays static and is not the
  live config path.

active-config\ is managed by setup
  Keep your dynamic EQ, tune, and HeSuVi state in active-config\ so the active
  profile can be swapped without editing the whole E-APO config by hand.
  The static library\ folder remains the reference library only.

boost.txt
  Seeded once at "Preamp: 0 dB" and never overwritten, so a value you set survives
  later runs. config.txt includes the managed active-config\boost.txt last on every
  chain, so set your dB there and save. Nothing to uncomment. 0 dB = off.
'@

    if ($TwoChains) {
        $card += @'


Two chains, both live
  config.txt carries both, each scoped to its own output device:
    SonicScout2.0    - 8ch chain, uses HeSuVi
    SonicScout2.0 +  - 16ch chain, no HeSuVi, uses the bundled VST
  Switch by choosing the output device in game, not by editing
  config.txt. Do not comment either one out.
'@
    }

    $readmePath = Join-Path $script:SonicScout20Root "README.txt"
    try {
        Set-Content -Path $readmePath -Value $card -Force
    } catch {
        Write-Host "$($script:BoxMargin)WARNING: Could not write README.txt: $_" -ForegroundColor Yellow
    }
}

function Import-SonicScoutParametricEq {
    <#
    .SYNOPSIS
        Validates and imports SquigLink/Equalizer APO parametric EQ text.
    .DESCRIPTION
        SquigLink exports Equalizer APO-compatible lines. The importer keeps comments,
        Preamp, and supported Filter lines while rejecting empty or unrelated files.
    #>
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        throw "EQ file was not found: $SourcePath"
    }

    $sourceLines = @(Get-Content -LiteralPath $SourcePath -ErrorAction Stop)
    $outputLines = @()
    $filterCount = 0
    foreach ($line in $sourceLines) {
        $trimmed = "$line".Trim()
        if (-not $trimmed) { continue }
        if ($trimmed.StartsWith('#') -or $trimmed -match '^Preamp\s*:') {
            $outputLines += $trimmed
            continue
        }
        if ($trimmed -match '^Filter\s+\d+\s*:\s*ON\s+(PK|LSC|HSC|LP|HP|AP)\s+') {
            $outputLines += $trimmed
            $filterCount++
        }
    }

    if ($filterCount -eq 0) {
        throw "EQ file contains no supported Equalizer APO filter lines: $SourcePath"
    }
    Set-Content -LiteralPath $DestinationPath -Value ($outputLines -join "`r`n") -Force
    return $filterCount
}

function Invoke-SonicScoutProfileWizard {
    <#
    .SYNOPSIS
        Selects real library tune and EQ files for the managed active-config layout.
    #>
    param()

    $libraryRoot = Join-Path $script:SonicScout20Root 'library'
    $activeDir   = Join-Path $script:SonicScout20Root 'active-config'

    if (-not (Test-Path -LiteralPath $libraryRoot)) {
        Write-Host "$($script:BoxMargin)The SonicScout2.0 library is not installed yet. Run [1] Install first." -ForegroundColor Red
        return $false
    }

    New-Item -ItemType Directory -Path $activeDir -Force | Out-Null

    $games = @()
    foreach ($dir in Get-ChildItem -Path $libraryRoot -Directory | Sort-Object Name) {
        $games += $dir.Name
    }

    if ($games.Count -eq 0) {
        Write-Host "$($script:BoxMargin)No library folders were found in $libraryRoot" -ForegroundColor Red
        return $false
    }

    Write-Host ""
    Write-Host "$($script:BoxMargin)SonicScout2.0 Profile Wizard" -ForegroundColor Yellow
    Write-Host "$($script:BoxMargin)Choose a game folder:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $games.Count; $i++) {
        Write-Host "$($script:BoxMargin)[$($i + 1)] $($games[$i])" -ForegroundColor DarkGray
    }
    $gameChoice = Read-Host "Enter the number"
    $gameIndex = 0
    if (-not [int]::TryParse($gameChoice, [ref]$gameIndex) -or $gameIndex -lt 1 -or $gameIndex -gt $games.Count) {
        Write-Host "$($script:BoxMargin)Invalid game selection." -ForegroundColor Red
        return $false
    }
    $selectedGame = $games[$gameIndex - 1]

    $gamePath = Join-Path $libraryRoot $selectedGame
    $versions = @()
    foreach ($dir in Get-ChildItem -Path $gamePath -Directory | Sort-Object Name) {
        $versions += $dir.Name
    }

    if ($versions.Count -eq 0) {
        Write-Host "$($script:BoxMargin)No versions found under $selectedGame" -ForegroundColor Red
        return $false
    }

    Write-Host "$($script:BoxMargin)Choose a version for ${selectedGame}:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $versions.Count; $i++) {
        Write-Host "$($script:BoxMargin)[$($i + 1)] $($versions[$i])" -ForegroundColor DarkGray
    }
    $verChoice = Read-Host "Enter the number"
    $verIndex = 0
    if (-not [int]::TryParse($verChoice, [ref]$verIndex) -or $verIndex -lt 1 -or $verIndex -gt $versions.Count) {
        Write-Host "$($script:BoxMargin)Invalid version selection." -ForegroundColor Red
        return $false
    }
    $selectedVersion = $versions[$verIndex - 1]

    $versionPath = Join-Path $gamePath $selectedVersion
    $tuneFiles = @(Get-ChildItem -LiteralPath $versionPath -File -Filter '*.txt' |
        Where-Object { $_.Name -notmatch '_Target_|^LEQ |^Choose ' } | Sort-Object Name)
    $sixteenTunes = @($tuneFiles | Where-Object { $_.Name -match '_16ch_' })
    $eightPreTunes = @($tuneFiles | Where-Object { $_.Name -match '_pre(?:_|\.)' })
    $eightPost = Get-ChildItem -LiteralPath $versionPath -File -Filter "${selectedGame}_${selectedVersion}_post.txt" -ErrorAction SilentlyContinue
    $isSixteen = ($sixteenTunes.Count -gt 0)

    if ($isSixteen) {
        Write-Host "$($script:BoxMargin)This version uses the 16-channel SonicScout2.0 + route." -ForegroundColor Yellow
        Write-Host "$($script:BoxMargin)Choose a real bundled tune:" -ForegroundColor Yellow
        for ($i = 0; $i -lt $sixteenTunes.Count; $i++) {
            $label = $sixteenTunes[$i].BaseName -replace "^${selectedGame}_${selectedVersion}_16ch_", ''
            Write-Host "$($script:BoxMargin)[$($i + 1)] $label" -ForegroundColor DarkGray
        }
        $tuneChoice = Read-Host "Enter the number"
        $tuneIndex = 0
        if (-not [int]::TryParse($tuneChoice, [ref]$tuneIndex) -or $tuneIndex -lt 1 -or $tuneIndex -gt $sixteenTunes.Count) {
            Write-Host "$($script:BoxMargin)Invalid tune selection." -ForegroundColor Red
            return $false
        }
        $selectedTune = $sixteenTunes[$tuneIndex - 1]
        $tuneVariant = $selectedTune.BaseName -replace "^${selectedGame}_${selectedVersion}_16ch_", ''
        $selectedMode = '16ch'
    } elseif ($eightPreTunes.Count -gt 0 -and $eightPost) {
        Write-Host "$($script:BoxMargin)This version uses the 8-channel SonicScout2.0 route." -ForegroundColor Yellow
        Write-Host "$($script:BoxMargin)Choose a real pre-HeSuVi variation:" -ForegroundColor Yellow
        for ($i = 0; $i -lt $eightPreTunes.Count; $i++) {
            $label = $eightPreTunes[$i].BaseName -replace "^${selectedGame}_${selectedVersion}_pre_?", ''
            if ([string]::IsNullOrWhiteSpace($label)) { $label = 'Competitive (default)' }
            Write-Host "$($script:BoxMargin)[$($i + 1)] $label" -ForegroundColor DarkGray
        }
        $tuneChoice = Read-Host "Enter the number"
        $tuneIndex = 0
        if (-not [int]::TryParse($tuneChoice, [ref]$tuneIndex) -or $tuneIndex -lt 1 -or $tuneIndex -gt $eightPreTunes.Count) {
            Write-Host "$($script:BoxMargin)Invalid tune selection." -ForegroundColor Red
            return $false
        }
        $selectedTune = $eightPreTunes[$tuneIndex - 1]
        $tuneVariant = $selectedTune.BaseName -replace "^${selectedGame}_${selectedVersion}_pre_?", ''
        if ([string]::IsNullOrWhiteSpace($tuneVariant)) { $tuneVariant = 'Competitive' }
        $selectedMode = '8ch'
    } else {
        Write-Host "$($script:BoxMargin)No complete supported tune chain was found in $versionPath" -ForegroundColor Red
        return $false
    }

    $eqDir = Join-Path $versionPath 'eq'
    $eqFiles = @(Get-ChildItem -LiteralPath $eqDir -File -Filter '*.txt' -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($eqFiles.Count -eq 0) {
        Write-Host "$($script:BoxMargin)No EQ files were found in $eqDir" -ForegroundColor Red
        return $false
    }
    Write-Host "$($script:BoxMargin)Choose a bundled EQ file, or enter C for a custom EQ path:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $eqFiles.Count; $i++) {
        Write-Host "$($script:BoxMargin)[$($i + 1)] $($eqFiles[$i].Name)" -ForegroundColor DarkGray
    }
    $eqChoice = Read-Host "Enter the number or C"
    $selectedEqPath = $null
    $selectedEqName = $null
    if ($eqChoice -eq 'c' -or $eqChoice -eq 'C') {
        $selectedEqPath = Read-Host "Full path to a SquigLink/Equalizer APO EQ text file"
        if (-not (Test-Path -LiteralPath $selectedEqPath -PathType Leaf)) {
            Write-Host "$($script:BoxMargin)Custom EQ file was not found." -ForegroundColor Red
            return $false
        }
        $selectedEqName = Split-Path -Path $selectedEqPath -Leaf
    } else {
        $eqIndex = 0
        if (-not [int]::TryParse($eqChoice, [ref]$eqIndex) -or $eqIndex -lt 1 -or $eqIndex -gt $eqFiles.Count) {
            Write-Host "$($script:BoxMargin)Invalid EQ selection." -ForegroundColor Red
            return $false
        }
        $selectedEqPath = $eqFiles[$eqIndex - 1].FullName
        $selectedEqName = $eqFiles[$eqIndex - 1].Name
    }
    $headphone = Read-Host "Headphone or IEM model name (used only for profile notes; leave blank for Custom)"
    if ([string]::IsNullOrWhiteSpace($headphone)) { $headphone = 'Custom' }

    $presetName = 'Not applicable'
    if ($selectedMode -eq '8ch') {
        $presetName = Read-Host "HeSuVi preset name (for example: EAC_Default or EAC_Refined; leave blank for EAC_Default)"
        if ([string]::IsNullOrWhiteSpace($presetName)) { $presetName = 'EAC_Default' }
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $profileLabel = "$headphone - $selectedGame $selectedVersion | $tuneVariant"

    $eqFile = Join-Path $activeDir 'eq.txt'
    $preFile = Join-Path $activeDir 'prehesuvi.txt'
    $postFile = Join-Path $activeDir 'posthesuvi.txt'
    $sixteenFile = Join-Path $activeDir '16chConfig.txt'
    $currentFile = Join-Path $activeDir 'current_profile.txt'
    $profileJson = Join-Path $activeDir 'current_profile.json'

    try {
        $filterCount = Import-SonicScoutParametricEq -SourcePath $selectedEqPath -DestinationPath $eqFile
    } catch {
        Write-Host "$($script:BoxMargin)EQ import failed: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
    if ($selectedMode -eq '8ch') {
        Copy-Item -LiteralPath $selectedTune.FullName -Destination $preFile -Force
        Copy-Item -LiteralPath $eightPost.FullName -Destination $postFile -Force
        Set-Content -Path $sixteenFile -Value "# No 16-channel tune is defined for $selectedGame $selectedVersion`r`n" -Force
    } else {
        Set-Content -Path $preFile -Value "# No pre-HeSuVi stage for this 16-channel profile.`r`n" -Force
        Set-Content -Path $postFile -Value "# No post-HeSuVi stage for this 16-channel profile.`r`n" -Force
        Copy-Item -LiteralPath $selectedTune.FullName -Destination $sixteenFile -Force
    }

    $profile = [ordered]@{
        Schema = 1
        Updated = $timestamp
        Game = $selectedGame
        Version = $selectedVersion
        Mode = $selectedMode
        Headphone = $headphone
        EqFile = $selectedEqName
        EqFilterCount = $filterCount
        TuneFile = $selectedTune.Name
        TuneVariant = $tuneVariant
        HeSuViPreset = $presetName
    }
    $profile | ConvertTo-Json -Depth 3 | Set-Content -Path $profileJson -Force
    Set-Content -Path $currentFile -Value "$profileLabel | $timestamp`r`n" -Force

    Write-Host ""
    Write-Host "$($script:BoxMargin)Profile activated: $profileLabel" -ForegroundColor Green
    Write-Host "$($script:BoxMargin)Managed files written to $activeDir" -ForegroundColor DarkGray
    Write-Host "$($script:BoxMargin)Using real library files: $($selectedTune.Name) + $selectedEqName ($filterCount filters)" -ForegroundColor DarkGray
    Write-Host "$($script:BoxMargin)Profile metadata saved to active-config\current_profile.json" -ForegroundColor DarkGray
    Write-Host ""
    return $true
}

# ============================================================================
# SECTION 6: VB-CABLE Endpoint Configuration (.reg based)
# ============================================================================
# Detect the VB-CABLE render/capture endpoints, then rename + set icons + apply
# the 7.1 speaker configuration via a single .reg import and one Audiosrv
# restart. Plain registry writes only -- no COM, no ACL P/Invoke, no mutex. The
# remaining downstream steps (Device Selector, LEQ, default device) stay in the
# user's guided walkthrough.

# Public Windows registry facts (MMDevices roots + property keys).
$script:MMDEVICES_RENDER  = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render"
$script:MMDEVICES_CAPTURE = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Capture"
$script:PKEY_FRIENDLY   = "{a45c254e-df1c-4efd-8020-67d146a850e0},2"   # PKEY_Device_FriendlyName
$script:PKEY_DESC       = "{b3f8fa53-0004-438e-9003-51a46e139bfc},6"   # DeviceInterface desc
$script:PKEY_FORMFACTOR = "{1da5d803-d492-4edd-8c23-e0c0ffee7f0e},0"   # EndpointFormFactor (1=Speakers, 2=LineLevel)
$script:PKEY_ICON       = "{259abffc-50a7-47ce-af08-68c9a7d73366},12"  # PKEY_DeviceIcon
# Speaker configuration. These two DWORDs are what the Sound "Configure" wizard
# writes when a user picks 7.1 Surround (mask 0x63F = 1599). Written by setup so
# the endpoint ships 7.1 out of the box -- verified empirically from a machine
# where the wizard was run by hand.
$script:PKEY_CHANNELCFG  = "{1da5d803-d492-4edd-8c23-e0c0ffee7f0e},3"
$script:PKEY_CHANNELCFG2 = "{1da5d803-d492-4edd-8c23-e0c0ffee7f0e},6"

function Clear-SonicScout20EndpointBranding {
    <#
    .SYNOPSIS
        Restores stale SonicScout2.0 endpoint names left behind by failed
        or pending driver removal.
    .OUTPUTS
        pscustomobject @{ Changed; Failed }
    #>
    $changed = 0; $failed = 0
    $targets = @(
        @{
            PsRoot = $script:MMDEVICES_RENDER
            RegRoot = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render'
            DefaultName = 'CABLE Input (VB-Audio Virtual Cable)'
        }
        @{
            PsRoot = $script:MMDEVICES_CAPTURE
            RegRoot = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Capture'
            DefaultName = 'CABLE Output (VB-Audio Virtual Cable)'
        }
    )
    $vmDefaults = @{
        'Normal Audio' = 'Voicemeeter Input'
        'Virtual Mix'  = 'Voicemeeter Out B1'
    }
    $brandedNamePattern = '^(Sonic\s*Scout|SonicScout|SonicScout2\.0)'
    $reg = "Windows Registry Editor Version 5.00`r`n"

    foreach ($target in $targets) {
        if (-not (Test-Path $target.PsRoot)) { continue }
        foreach ($key in Get-ChildItem -Path $target.PsRoot -ErrorAction SilentlyContinue) {
            $propsPath = Join-Path $key.PSPath 'Properties'
            if (-not (Test-Path $propsPath)) { continue }
            try {
                $props = Get-ItemProperty -Path $propsPath -ErrorAction SilentlyContinue
                $name = "$($props.$script:PKEY_FRIENDLY)"
                $desc = "$($props.$script:PKEY_DESC)"
                $icon = "$($props.$script:PKEY_ICON)"
                $newName = $null

                if ($desc -eq 'VB-Audio Virtual Cable' -and (Test-OrdinalMatch $name $brandedNamePattern)) {
                    $newName = $target.DefaultName
                } elseif ($vmDefaults.ContainsKey($name)) {
                    $newName = $vmDefaults[$name]
                }

                $removeIcon = Test-OrdinalContains $icon 'SonicScout'
                if (-not $newName -and -not $removeIcon) { continue }

                $reg += "`r`n[$($target.RegRoot)\$($key.PSChildName)\Properties]`r`n"
                if ($newName) { $reg += "`"$script:PKEY_FRIENDLY`"=`"$newName`"`r`n" }
                if ($removeIcon) { $reg += "`"$script:PKEY_ICON`"=-`r`n" }
                $changed++
            } catch {
                $failed++
            }
        }
    }

    if ($changed -gt 0) {
        try {
            if (-not (Test-Path $script:TempPath)) { New-Item -ItemType Directory -Path $script:TempPath -Force | Out-Null }
            $regFile = Join-Path $script:TempPath "sonicscout2.0_clear_endpoints.reg"
            $reg | Out-File -FilePath $regFile -Encoding ASCII -Force
            $proc = Start-Process -FilePath 'regedit.exe' -ArgumentList "/s `"$regFile`"" -Wait -PassThru -WindowStyle Hidden
            if ($proc.ExitCode -ne 0) { throw "regedit returned exit code $($proc.ExitCode)" }
            Remove-Item $regFile -Force -ErrorAction SilentlyContinue
            Write-Host "$($script:BoxMargin)Cleared stale SonicScout2.0 audio endpoint names." -ForegroundColor Green
            Restart-AudioServices
        } catch {
            $failed += $changed
            $changed = 0
            Write-Host "$($script:BoxMargin)WARNING: stale endpoint cleanup failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    return [pscustomobject]@{ Changed = $changed; Failed = $failed }
}

function Restart-AudioServices {
    <#
    .SYNOPSIS
        Restarts Windows audio services using Restart-Service -Force, which handles
        the Audiosrv/AudioEndpointBuilder dependency graph atomically.
    #>
    Write-Host ""
    Write-Host "$($script:BoxMargin)Restarting audio services..." -ForegroundColor Cyan

    try {
        Restart-Service -Name 'Audiosrv' -Force -ErrorAction Stop
    } catch {
        Write-Host "$($script:BoxMargin)Warning: Restart-Service failed ($_), retrying..." -ForegroundColor Yellow
        Start-Sleep -Seconds 2
        Restart-Service -Name 'Audiosrv' -Force -ErrorAction Stop
    }

    $running = Write-Wait -Message "Waiting for Audiosrv" -Until {
        $svc = Get-Service -Name 'Audiosrv' -ErrorAction SilentlyContinue
        $svc -and $svc.Status -eq 'Running'
    } -TimeoutSeconds 15

    if ($running) {
        Write-Host "$($script:BoxMargin)Audio services restarted." -ForegroundColor Green
    } else {
        Write-Host "$($script:BoxMargin)Warning: Audio services may not have restarted properly." -ForegroundColor Yellow
    }
}

function Get-SonicScout20Endpoints {
    <#
    .SYNOPSIS
        Detects the VB-CABLE render/capture endpoints among ACTIVE devices.
    .DESCRIPTION
        Family-matches the device description rather than only a single literal so the
        Hi-Fi / Virtual Cable variants are both recognized. We still guard against
        unrelated local output aliases by checking the device description and the
        friendly name; this keeps a user's own Hi-Fi Cable or other Virtual Cable
        output from being mistaken for SonicScout2.0. Then use EndpointFormFactor to
        split 8ch vs 16ch render endpoints. A clean VB-CABLE v45 install ships all
        three endpoints Active.
    .OUTPUTS
        pscustomobject @{ Render8; Render16; Capture } of GUIDs (any may be $null).
    #>
    $render8 = $null; $render16 = $null; $capture = $null

    $matchesVbCable = {
        param($desc, $friendly)
        if ([string]::IsNullOrWhiteSpace($desc) -and [string]::IsNullOrWhiteSpace($friendly)) { return $false }
        $candidate = (@($desc, $friendly) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
        if ([string]::IsNullOrWhiteSpace($candidate)) { return $false }
        $normalized = $candidate.Trim()
        $matches = @(
            'VB-Audio Virtual Cable',
            'VB-Audio Hi-Fi Cable',
            'VB-Audio HiFi Cable',
            'VB-Audio Hi-Fi',
            'VB-Audio HiFi',
            'SonicScout2.0',
            'SonicScout2.0 +',
            'SonicScout2.0 Unified Output'
        )
        foreach ($name in $matches) {
            if ($normalized -ieq $name) { return $true }
        }
        return $normalized -match '(?i)^VB-Audio\s+(Virtual\s+Cable|Hi[- ]?Fi\s+Cable|Hi[- ]?Fi)$' -or
               $normalized -match '(?i)^SonicScout2\.0(?:\s+\+|\s+Unified\s+Output)?$'
    }

    if (Test-Path $script:MMDEVICES_RENDER) {
        foreach ($key in Get-ChildItem -Path $script:MMDEVICES_RENDER -ErrorAction SilentlyContinue) {
            try {
                $state = (Get-ItemProperty -Path $key.PSPath -Name 'DeviceState' -ErrorAction SilentlyContinue).DeviceState
                if ($state -ne 1) { continue }   # active only
                $propsPath = Join-Path $key.PSPath 'Properties'
                if (-not (Test-Path $propsPath)) { continue }
                $props = Get-ItemProperty -Path $propsPath -ErrorAction SilentlyContinue
                $desc = "$($props.$script:PKEY_DESC)"
                $friendly = "$($props.$script:PKEY_FRIENDLY)"
                if (-not (& $matchesVbCable $desc $friendly)) { continue }
                $ff = [int]($props.$script:PKEY_FORMFACTOR)
                if ($ff -eq 2) {
                    if (-not $render16) { $render16 = $key.PSChildName }
                } else {
                    if (-not $render8) { $render8 = $key.PSChildName }
                }
            } catch { continue }
        }
    }

    if (Test-Path $script:MMDEVICES_CAPTURE) {
        foreach ($key in Get-ChildItem -Path $script:MMDEVICES_CAPTURE -ErrorAction SilentlyContinue) {
            try {
                $state = (Get-ItemProperty -Path $key.PSPath -Name 'DeviceState' -ErrorAction SilentlyContinue).DeviceState
                if ($state -ne 1) { continue }
                $propsPath = Join-Path $key.PSPath 'Properties'
                if (-not (Test-Path $propsPath)) { continue }
                $props = Get-ItemProperty -Path $propsPath -ErrorAction SilentlyContinue
                $desc = "$($props.$script:PKEY_DESC)"
                $friendly = "$($props.$script:PKEY_FRIENDLY)"
                if (-not (& $matchesVbCable $desc $friendly)) { continue }
                if (-not $capture) { $capture = $key.PSChildName }
            } catch { continue }
        }
    }

    return [pscustomobject]@{ Render8 = $render8; Render16 = $render16; Capture = $capture }
}

function Get-VoicemeeterEndpoints {
    <#
    .SYNOPSIS
        Detects the Voicemeeter Standard render/capture endpoints among ACTIVE devices.
    .DESCRIPTION
        Carried over from the v1.1 installer, which renamed Voicemeeter Input to
        "Normal Audio" and Voicemeeter Out B1 to "Virtual Mix" -- the names the
        game settings pages (COD_SETTINGS.md, BF6_SETTINGS.md) tell users to pick.

        Matched by FRIENDLY NAME, not by the interface description the VB-CABLE
        path keys on: the VAIO description string varies across Voicemeeter
        builds, while these endpoint names have been stable. The target names are
        in the match sets too, so a second run resolves the same GUIDs and
        rewrites the same values instead of finding nothing to do.

        Case is not a concern -- string -eq is ordinal (see the culture-invariant
        matching note in SECTION 2), so one entry covers both the 'Voicemeeter'
        and 'VoiceMeeter' spellings VB-Audio has shipped.

        Standard-only is the CALLER's gate (Test-VoicemeeterEdition.Standard).
        The sets here are Standard-shaped regardless: Banana/Potato add Aux
        endpoints on the same driver, and 'Voicemeeter Aux Output' does not
        contain 'Voicemeeter Output', so they cannot be caught by accident.
    .OUTPUTS
        pscustomobject @{ Render; Capture } of GUIDs (either may be $null).
    #>
    $render = $null; $capture = $null

    if (Test-Path $script:MMDEVICES_RENDER) {
        foreach ($key in Get-ChildItem -Path $script:MMDEVICES_RENDER -ErrorAction SilentlyContinue) {
            try {
                $state = (Get-ItemProperty -Path $key.PSPath -Name 'DeviceState' -ErrorAction SilentlyContinue).DeviceState
                if ($state -ne 1) { continue }   # active only
                $propsPath = Join-Path $key.PSPath 'Properties'
                if (-not (Test-Path $propsPath)) { continue }
                $props = Get-ItemProperty -Path $propsPath -ErrorAction SilentlyContinue
                $name = "$($props.$script:PKEY_FRIENDLY)"
                if ($name -eq 'Voicemeeter Input' -or $name -eq 'Normal Audio') {
                    if (-not $render) { $render = $key.PSChildName }
                }
            } catch { continue }
        }
    }

    if (Test-Path $script:MMDEVICES_CAPTURE) {
        foreach ($key in Get-ChildItem -Path $script:MMDEVICES_CAPTURE -ErrorAction SilentlyContinue) {
            try {
                $state = (Get-ItemProperty -Path $key.PSPath -Name 'DeviceState' -ErrorAction SilentlyContinue).DeviceState
                if ($state -ne 1) { continue }
                $propsPath = Join-Path $key.PSPath 'Properties'
                if (-not (Test-Path $propsPath)) { continue }
                $props = Get-ItemProperty -Path $propsPath -ErrorAction SilentlyContinue
                $name = "$($props.$script:PKEY_FRIENDLY)"
                if ($name -eq 'Voicemeeter Out B1' -or $name -eq 'Virtual Mix' -or
                    (Test-OrdinalContains $name 'Voicemeeter Output')) {
                    if (-not $capture) { $capture = $key.PSChildName }
                }
            } catch { continue }
        }
    }

    return [pscustomobject]@{ Render = $render; Capture = $capture }
}

function Set-SonicScout20Endpoints {
    <#
    .SYNOPSIS
        Detect + rename + icon the VB-CABLE render/capture endpoints via a
        single .reg import and one Audiosrv restart (stripped-down OG style).
        Also sets the 8ch endpoint's speaker configuration to 7.1 Surround, the
        same values the Sound "Configure" wizard would write.
    .PARAMETER IncludeVoicemeeter
        Also rename the Voicemeeter Standard endpoints (Normal Audio / Virtual
        Mix), in the SAME .reg and the SAME restart. Caller-gated: pass $true
        only for a Voicemeeter Standard install the user actually asked for.
    .OUTPUTS
        pscustomobject @{ Render8; Render16; Capture } of GUIDs (any may be $null).
    #>
    param([string]$IconBaseUrl, [string]$Margin = '', [bool]$IncludeVoicemeeter = $false)

    Write-Host "$($Margin)Detecting VB-CABLE endpoints..." -ForegroundColor Cyan
    $eps = Get-SonicScout20Endpoints
    $r8 = $eps.Render8; $r16 = $eps.Render16; $cap = $eps.Capture

    if (-not $r8 -and -not $r16 -and -not $cap) {
        Write-Host "$($Margin)No active VB-CABLE endpoints detected; skipping endpoint configuration." -ForegroundColor Yellow
        # Verified = $false: nothing was read back because nothing was found, and a cable
        # that produced no endpoints is the more serious of the two failures this reports.
        return [pscustomobject]@{ Render8 = $null; Render16 = $null; Capture = $null; Verified = $false }
    }
    if ($r8)  { Write-Host "$($Margin)  Render 8ch  : $r8"  -ForegroundColor Cyan }
    if ($r16) { Write-Host "$($Margin)  Render 16ch : $r16" -ForegroundColor Cyan }
    if ($cap) { Write-Host "$($Margin)  Capture     : $cap" -ForegroundColor Cyan }
    if (-not ($r8 -and $r16 -and $cap)) {
        Write-Host "$($Margin)  WARNING: expected three active endpoints (8ch + 16ch render + capture); some were not found." -ForegroundColor Yellow
    }
    # 16ch guard: a missing SonicScout2.0 + endpoint is an explained 8ch-only fallback,
    # not a silent result. The r16 blocks below are already null-gated (no null-ref).
    if ($r8 -and -not $r16) {
        Write-Host "$($Margin)  WARNING: the 16ch endpoint (SonicScout2.0 +) was not found." -ForegroundColor Yellow
        Write-Host "$($Margin)  Only the 8ch endpoint (SonicScout2.0) will be configured." -ForegroundColor Yellow
        Write-Host "$($Margin)  Likely cause: VB-CABLE is not exposing a 16ch render endpoint on this machine." -ForegroundColor Yellow
    }

    # --- Voicemeeter Standard endpoints (old-guide names) ---
    # Resolved AFTER the VB-CABLE early return above, deliberately: with no cable
    # endpoints the stack is broken and the user re-runs anyway, so a names-only
    # pass is not worth a second regedit import and a second Audiosrv restart.
    # Found endpoints ride along in the one .reg and the one restart below.
    $vmRender = $null; $vmCapture = $null
    if ($IncludeVoicemeeter) {
        Write-Host "$($Margin)Detecting Voicemeeter Standard endpoints..." -ForegroundColor Cyan
        $vmEps = Get-VoicemeeterEndpoints
        $vmRender = $vmEps.Render; $vmCapture = $vmEps.Capture
        if ($vmRender)  { Write-Host "$($Margin)  VM render   : $vmRender"  -ForegroundColor Cyan }
        if ($vmCapture) { Write-Host "$($Margin)  VM capture  : $vmCapture" -ForegroundColor Cyan }
        if (-not $vmRender -and -not $vmCapture) {
            # Not a failure: Voicemeeter can be installed with its driver not yet
            # enumerated (pending reboot). Nothing to rename, nothing to verify.
            Write-Host "$($Margin)  No active Voicemeeter endpoints found; leaving Voicemeeter names alone." -ForegroundColor DarkGray
        }
    }

    # --- Download the three endpoint icons (non-fatal) ---
    $iconDir = 'C:\ProgramData\SonicScout2.0\icons'
    try {
        if (-not (Test-Path -LiteralPath $iconDir)) { New-Item -ItemType Directory -Path $iconDir -Force | Out-Null }
    } catch {
        Write-Host "$($Margin)  Could not create icon directory (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
    }
    $iconBase = if ($IconBaseUrl) { $IconBaseUrl.TrimEnd('/') } else { '' }
    $getIcon = {
        param($SourceFileName, $DestinationFileName = $SourceFileName)
        if ([string]::IsNullOrWhiteSpace($iconBase)) { return $null }
        $dest = Join-Path $iconDir $DestinationFileName
        try {
            Invoke-WebRequest -Uri "$iconBase/$SourceFileName" -OutFile $dest -UseBasicParsing -ErrorAction Stop
            if (Test-Path -LiteralPath $dest) { return $dest }
        } catch {
            Write-Host "$($Margin)  Icon download failed for $DestinationFileName (non-fatal)." -ForegroundColor Yellow
        }
        return $null
    }
    $r8Icon  = if ($r8)  { & $getIcon 'SonicScout2.0Cable.ico' 'SonicScout2.0Cable.ico' }                 else { $null }
    $r16Icon = if ($r16) { & $getIcon 'SonicScout2.0PlusCable.ico' 'SonicScout2.0PlusCable.ico' }         else { $null }
    $capIcon = if ($cap) { & $getIcon 'SonicScout2.0UnifiedOutput.ico' 'SonicScout2.0UnifiedOutput.ico' } else { $null }

    # Icon PKEY value = "<abs path>,0" with backslashes doubled for REG_SZ.
    $r8IconReg  = if ($r8Icon)  { ($r8Icon  + ',0') -replace '\\', '\\' } else { $null }
    $r16IconReg = if ($r16Icon) { ($r16Icon + ',0') -replace '\\', '\\' } else { $null }
    $capIconReg = if ($capIcon) { ($capIcon + ',0') -replace '\\', '\\' } else { $null }

    # --- Build ONE .reg: names + icons ---
    $renderKey  = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render'
    $captureKey = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Capture'
    $reg = "Windows Registry Editor Version 5.00`r`n"

    if ($r8) {
        $reg += "`r`n[$renderKey\$r8\Properties]`r`n"
        $reg += "`"$script:PKEY_FRIENDLY`"=`"SonicScout2.0`"`r`n"
        if ($r8IconReg) { $reg += "`"$script:PKEY_ICON`"=`"$r8IconReg`"`r`n" }
        # 7.1 Surround speaker config (0x63F), same DWORDs the Sound "Configure"
        # wizard writes. The 16ch endpoint is deliberately untouched: writing a
        # 7.1 mask there would cap it at 8 channels.
        $reg += "`"$script:PKEY_CHANNELCFG`"=dword:0000063f`r`n"
        $reg += "`"$script:PKEY_CHANNELCFG2`"=dword:0000063f`r`n"
    }
    if ($r16) {
        $reg += "`r`n[$renderKey\$r16\Properties]`r`n"
        $reg += "`"$script:PKEY_FRIENDLY`"=`"SonicScout2.0 +`"`r`n"
        if ($r16IconReg) { $reg += "`"$script:PKEY_ICON`"=`"$r16IconReg`"`r`n" }
    }
    if ($cap) {
        $reg += "`r`n[$captureKey\$cap\Properties]`r`n"
        $reg += "`"$script:PKEY_FRIENDLY`"=`"SonicScout2.0 Unified Output`"`r`n"
        if ($capIconReg) { $reg += "`"$script:PKEY_ICON`"=`"$capIconReg`"`r`n" }
    }
    # Names only for Voicemeeter: v1.1 shipped no icons for these, and there are
    # no .ico assets for them to fetch.
    if ($vmRender) {
        $reg += "`r`n[$renderKey\$vmRender\Properties]`r`n"
        $reg += "`"$script:PKEY_FRIENDLY`"=`"Normal Audio`"`r`n"
    }
    if ($vmCapture) {
        $reg += "`r`n[$captureKey\$vmCapture\Properties]`r`n"
        $reg += "`"$script:PKEY_FRIENDLY`"=`"Virtual Mix`"`r`n"
    }

    Write-Host "$($Margin)Applying endpoint names and icons..." -ForegroundColor Cyan
    if (-not (Test-Path $script:TempPath)) { New-Item -ItemType Directory -Path $script:TempPath -Force | Out-Null }
    $regFile = Join-Path $script:TempPath "sonicscout2.0_endpoints.reg"
    $reg | Out-File -FilePath $regFile -Encoding ASCII -Force

    try {
        $proc = Start-Process -FilePath 'regedit.exe' -ArgumentList "/s `"$regFile`"" -Wait -PassThru -WindowStyle Hidden
        if ($proc.ExitCode -ne 0) {
            Write-Host "$($Margin)  WARNING: registry import returned exit code $($proc.ExitCode) (non-fatal)." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "$($Margin)  WARNING: registry import failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
    }
    Remove-Item $regFile -Force -ErrorAction SilentlyContinue

    # One restart finalizes the renames and icons.
    Restart-AudioServices

    # --- Read-back verify the three names and the icons we actually wrote ---
    # Expected icon value is the SINGLE-backslash form: $r8IconReg and friends are
    # .reg source literals with backslashes doubled for REG_SZ, and regedit stores
    # the unescaped path. Comparing against the doubled literal would never match.
    Start-Sleep -Milliseconds 200
    $expected = @()
    if ($r8)  { $expected += @{ Type = 'Render';  GUID = $r8;  Name = 'SonicScout2.0';                Icon = $(if ($r8Icon)  { "$r8Icon,0" }  else { $null }); Config = 1599 } }
    if ($r16) { $expected += @{ Type = 'Render';  GUID = $r16; Name = 'SonicScout2.0 +';              Icon = $(if ($r16Icon) { "$r16Icon,0" } else { $null }) } }
    if ($cap) { $expected += @{ Type = 'Capture'; GUID = $cap; Name = 'SonicScout2.0 Unified Output'; Icon = $(if ($capIcon) { "$capIcon,0" } else { $null }) } }
    # Icon-completeness is reported against the CABLE endpoints only -- the
    # Voicemeeter entries below carry no icon by design and would otherwise make
    # every run read as "icons where available".
    $cableCount = $expected.Count
    if ($vmRender)  { $expected += @{ Type = 'Render';  GUID = $vmRender;  Name = 'Normal Audio'; Icon = $null } }
    if ($vmCapture) { $expected += @{ Type = 'Capture'; GUID = $vmCapture; Name = 'Virtual Mix';  Icon = $null } }
    $allOk = $true
    $iconsAttempted = 0
    foreach ($e in $expected) {
        $propsPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\$($e.Type)\$($e.GUID)\Properties"
        try {
            $actual = (Get-ItemProperty -LiteralPath $propsPath -Name $script:PKEY_FRIENDLY -ErrorAction Stop).$script:PKEY_FRIENDLY
            if ($actual -ne $e.Name) { $allOk = $false }
        } catch { $allOk = $false }

        # Icons are best effort at DOWNLOAD time: an endpoint whose .ico never
        # arrived has no icon to verify and must not fail the check. One that WAS
        # written and does not read back means the .reg import silently dropped it
        # -- a real failure, treated exactly like a name mismatch.
        # ContainsKey, not a null test: these are hashtables, and under StrictMode
        # reading a MISSING key throws PropertyNotFoundException (the "Config" bug).
        if ($e.ContainsKey('Icon') -and $e.Icon) {
            $iconsAttempted++
            try {
                $actualIcon = (Get-ItemProperty -LiteralPath $propsPath -Name $script:PKEY_ICON -ErrorAction Stop).$script:PKEY_ICON
                if ("$actualIcon" -ne $e.Icon) { $allOk = $false }
            } catch { $allOk = $false }
        }

        # Speaker config is written unconditionally on the 8ch endpoint, so it
        # is verified with the same weight as a name: both wizard DWORDs must
        # read back as the 7.1 mask.
        if ($e.ContainsKey('Config')) {
            try {
                $cfgProps = Get-ItemProperty -LiteralPath $propsPath -ErrorAction Stop
                if ([int]$cfgProps.$script:PKEY_CHANNELCFG -ne $e.Config -or
                    [int]$cfgProps.$script:PKEY_CHANNELCFG2 -ne $e.Config) { $allOk = $false }
            } catch { $allOk = $false }
        }
    }

    if ($allOk) {
        if ($iconsAttempted -eq 0) {
            Write-Host "$($Margin)  Endpoints configured and verified (names + 7.1); no icons applied." -ForegroundColor Green
        } elseif ($iconsAttempted -eq $cableCount) {
            Write-Host "$($Margin)  Endpoints configured and verified (names + icons + 7.1)." -ForegroundColor Green
        } else {
            Write-Host "$($Margin)  Endpoints configured and verified (names + 7.1 + icons where available)." -ForegroundColor Green
        }
    } else {
        Write-Host "$($Margin)  WARNING: endpoint name, icon or 7.1 config verification incomplete (non-fatal)." -ForegroundColor Yellow
    }

    return [pscustomobject]@{ Render8 = $r8; Render16 = $r16; Capture = $cap; Verified = $allOk }
}

# ============================================================================
# SECTION 7: LEQ Control Panel Placement
# ============================================================================

function Install-SoundControl {
    <#
    .SYNOPSIS
        Installs the LEQ Control Panel executable and creates an SonicScout2.0 shortcut.
    #>
    param([ValidateNotNullOrEmpty()][string]$SourcePath)

    Write-Host "$($script:BoxMargin)Installing LEQ Control Panel..." -ForegroundColor Cyan

    $scFolder = Join-Path $env:LOCALAPPDATA "Programs\LEQControlPanel"
    $scExe = Join-Path $scFolder "LEQControlPanel.exe"

    # Stop LEQ Control Panel if it's running (locks the exe)
    $running = Get-Process -Name "LEQControlPanel" -ErrorAction SilentlyContinue
    if ($running) {
        Write-Host "$($script:BoxMargin)Closing running LEQ Control Panel..." -ForegroundColor DarkGray
        Stop-Process -Name "LEQControlPanel" -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
    }

    # Create directory
    if (-not (Test-Path $scFolder)) {
        New-Item -ItemType Directory -Path $scFolder -Force | Out-Null
    }

    # Copy exe
    Copy-Item -LiteralPath $SourcePath -Destination $scExe -Force

    # Create shortcut in SonicScout2.0 root folder
    $sonicScout20Root = Join-Path $env:ProgramFiles "EqualizerAPO\config\SonicScout2.0"
    if (Test-Path $sonicScout20Root) {
        try {
            $lnkPath = Join-Path $sonicScout20Root "LEQ Control Panel.lnk"
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($lnkPath)
            $shortcut.TargetPath = $scExe
            $shortcut.WorkingDirectory = $scFolder
            $shortcut.Description = "LEQ Control Panel"
            $shortcut.Save()
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
        } catch {
            Write-Host "$($script:BoxMargin)Warning: Could not create SonicScout2.0 library shortcut: $_" -ForegroundColor Yellow
        }
    }

    Write-Host "$($script:BoxMargin)LEQ Control Panel installed." -ForegroundColor Green
    return $true
}

# ============================================================================
# SECTION 8: Main Execution Flow
# ============================================================================

# Helper imports must never enter the menu or run installation.
if ($MyInvocation.InvocationName -eq '.') { return }

try {
    if ($DryRun) {
        # DRY RUN: this script is an interactive menu, so a dry run cannot replay it.
        # Instead it walks the install functions that [1] Install would call and
        # prints what each one WOULD do. Nothing is downloaded, installed, deleted,
        # renamed, or rebooted. Exit 0 either way -- the trace is the signal.
        Write-Host ""
        Write-Host "$($script:BoxMargin)DRY RUN -- no changes will be made." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "$($script:BoxMargin)Install-SonicScout2.0.ps1 -DryRun would:" -ForegroundColor Yellow
        Write-Host "$($script:BoxMargin)  1. Verify admin privileges and system compatibility (read-only checks)." -ForegroundColor White
        Write-Host "$($script:BoxMargin)  2. Resolve the E-APO install path from the registry." -ForegroundColor White
        Write-Host "$($script:BoxMargin)  3. Install-VBCable      -- launch the VB-Audio driver pack (interactive consent required)." -ForegroundColor White
        Write-Host "$($script:BoxMargin)  4. Install-Voicemeeter  -- launch the Voicemeeter installer, if chosen." -ForegroundColor White
        Write-Host "$($script:BoxMargin)  5. Install-ReaPlugs     -- launch the ReaPlugs installer, if missing." -ForegroundColor White
        Write-Host "$($script:BoxMargin)  6. Install-Eapo         -- launch Equalizer APO setup, then restart audio services." -ForegroundColor White
        Write-Host "$($script:BoxMargin)  7. Install-HeSuVi       -- launch the HeSuVi installer, if present." -ForegroundColor White
        Write-Host "$($script:BoxMargin)  8. Install-SonicScout20HRIR      -- download and place the HRIR wav." -ForegroundColor White
        Write-Host "$($script:BoxMargin)  9. Install-SonicScout20Library   -- download the release zip and lay it down." -ForegroundColor White
        Write-Host "$($script:BoxMargin) 10. Set-SonicScout20Endpoints     -- detect, rename and icon endpoints." -ForegroundColor White
        Write-Host "$($script:BoxMargin) 11. Write-InitialConfig           -- write device-scoped config.txt." -ForegroundColor White
        Write-Host "$($script:BoxMargin) 12. Install-JsfxPlugins / Install-VstPlugins -- drop the plugin payloads." -ForegroundColor White
        Write-Host "$($script:BoxMargin) 13. Install-SoundControl          -- build the LEQ Control Panel, if a source is available." -ForegroundColor White
        Write-Host ""
        Write-Host "$($script:BoxMargin)Every step above launches a third-party installer or writes files." -ForegroundColor Yellow
        Write-Host "$($script:BoxMargin)Run without -DryRun to actually perform them." -ForegroundColor Yellow
        Write-Host ""
        exit 0
    }

    Write-Banner
    Test-AdminPrivilege
    Test-SystemCompatibility
    Test-PowerShellEdition

    # Audio warning
    $null = Write-CenteredBlock @(@{ Text = "$([char]0x26A0) WARNING"; Color = 'Red' })
    $null = Write-CenteredBlock @(
        @{ Text = 'This installer will temporarily kill audio on this PC.'; Color = 'Red' }
        @{ Text = 'Watch the video guide on your phone or a different device.'; Color = 'Red' }
        @{ Text = 'Close all apps and save your work before continuing.'; Color = 'Red' }
    )

    :mainMenu while ($true) {

    Write-Host ""
    $menuItems = @(
        @{ Text = 'What would you like to do?'; Color = 'Yellow' }
        @{ Text = ''; Color = 'White' }
        @{ Text = '[1] Install - set up the audio stack (start here)'; Color = 'White' }
        @{ Text = '    Keeps Voicemeeter / Wave Link and anything else you already run.'; Color = 'DarkGray' }
        @{ Text = '[2] Start Clean - only if [1] is broken: wipe, restart, then re-run [1]'; Color = 'White' }
        @{ Text = '[3] Redownload Library - refresh the tune library (backs up your current one)'; Color = 'White' }
        @{ Text = '[4] Uninstall everything'; Color = 'White' }
        @{ Text = '[5] Setup Profile - guided game + headphone profile selection'; Color = 'White' }
        @{ Text = '[t] Thank you - Credits & developer links'; Color = 'White' }
        @{ Text = '[b] SonicScout2.0 - automated, auto-updating, no Voicemeeter'; Color = 'DarkGray' }
        @{ Text = '[Q] Quit'; Color = 'DarkGray' }
    )
    $menuMargin = Write-CenteredBlock $menuItems
    Write-Host ""

    while ($true) {
        Write-Host "$menuMargin" -NoNewline
        Write-Host "Choice: " -ForegroundColor Yellow -NoNewline
        $selection = Read-Host
        if ($selection -eq 't' -or $selection -eq 'T') {
            $result = Show-ThankYou
            if ($result -eq 'quit') { break mainMenu }
            continue mainMenu
        }
        if ($selection -eq 'b' -or $selection -eq 'B') {
            Start-Process "https://github.com/sensoredrooster/SonicScout2.0"
            Write-Host "$($script:BoxMargin)Opened in browser." -ForegroundColor Green
            continue mainMenu
        }
        if ($selection -eq 'q' -or $selection -eq 'Q') { break mainMenu }
        $num = 0
        if ([int]::TryParse($selection, [ref]$num) -and $num -ge 1 -and $num -le 5) {
            $menuChoice = $num
            break
        }
        Write-Host "$($script:BoxMargin)Invalid choice. Enter 1, 2, 3, 4, 5, t, b, or q." -ForegroundColor Red
    }

    if ($menuChoice -eq 2) {
        # ===============================================================
        # START CLEAN: back up, remove everything, reboot, re-run Install
        # ===============================================================
        # Invoke-FreshStart reboots (or exits) once anything is removed, so it
        # only returns here when there was nothing to remove -- in which case the
        # PC is already clean and [1] Install is the next step. Voicemeeter is
        # deliberately NOT part of the wipe.
        $null = Invoke-FreshStart
        continue mainMenu

    } elseif ($menuChoice -eq 3) {
        # ===============================================================
        # REDOWNLOAD LIBRARY: back up current library, fresh configs only
        # ===============================================================
        Write-Host ""
        Write-Host "$($script:BoxMargin)This backs up your current SonicScout2.0 library -- including any" -ForegroundColor Yellow
        Write-Host "$($script:BoxMargin)squig.link EQs you added -- to a dated folder, then downloads a" -ForegroundColor Yellow
        Write-Host "$($script:BoxMargin)fresh library. You will need to recopy or remake those EQs." -ForegroundColor Yellow
        Write-Host "$($script:BoxMargin)Backup location: Documents\SonicScout2.0 Backups\library-<date>" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "$($script:BoxMargin)Continue? [Y/n]: " -ForegroundColor Yellow -NoNewline
        $libGo = Read-Host
        if ($libGo -eq 'n' -or $libGo -eq 'N') { continue mainMenu }

        if (-not (Test-Path $script:TempPath)) {
            New-Item -ItemType Directory -Path $script:TempPath -Force | Out-Null
        }
        # Library configs only -- backup + wipe + fresh download happen inside
        # Install-SonicScout20Library. VST / JSFX / HRIR are NOT re-moved here.
        $null = Install-SonicScout20Library
        Remove-Item $script:TempPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host ""
        Write-Host "$($script:BoxMargin)Your previous library is in Documents\SonicScout2.0 Backups\ -- open the" -ForegroundColor DarkGray
        Write-Host "$($script:BoxMargin)SonicScout2.0 desktop shortcut to recover old squig.link combos." -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "$($script:BoxMargin)Done. Press any key to return to the menu." -ForegroundColor Green
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        continue mainMenu

    } elseif ($menuChoice -eq 4) {
        # ===============================================================
        # UNINSTALL EVERYTHING (no forced reboot; no reinstall)
        # ===============================================================
        # Voicemeeter is not removed unless asked. Name the edition so the choice
        # is answerable: only Standard is ever installed by this script, so Banana
        # or Potato means the user installed it themselves (and it is a paid,
        # licensed product) -- default to keeping those.
        $vm = Test-VoicemeeterEdition
        $wantVm = $false
        if ($vm.Present) {
            Write-Host ""
            if ($vm.PaidPresent) {
                # Stated, not asked. Uninstall-ExistingVoicemeeter refuses paid
                # editions outright (it returns 'Skipped'), so a remove prompt here
                # could only ever be a fake choice.
                Write-Host "$($script:BoxMargin)$($vm.Name) detected -- a licensed edition SonicScout2.0 did not" -ForegroundColor Yellow
                Write-Host "$($script:BoxMargin)install. Leaving it untouched." -ForegroundColor Yellow
            } else {
                Write-Host "$($script:BoxMargin)$($vm.Name) detected (installed by SonicScout2.0)." -ForegroundColor Yellow
                Write-Host "$($script:BoxMargin)Remove it? [Y/n]: " -ForegroundColor Yellow -NoNewline
                $ans = Read-Host
                $wantVm = ($ans -ne 'n' -and $ans -ne 'N')
            }
        }

        # Desktop icons go first, before the wipe rather than after it. Every
        # removal below can fail hard on a locked driver or a dead audio service,
        # and the script-level catch would then skip anything that came after --
        # which is exactly how an SonicScout2.0 icon pointing at a deleted folder
        # survived an uninstall. Nothing in the wipe needs these shortcuts.
        $lnkResult = Remove-SonicScout20DesktopShortcuts

        $result = Invoke-FreshStart -PromptRestart $false -IncludeVoicemeeter:$wantVm
        $removed = @($result.Removed)
        $kept    = @($result.Skipped)
        if ($vm.Present -and -not $wantVm) { $kept += $vm.Name }

        # Optional LEQ Control Panel removal
        Write-Host ""
        Write-Host "$($script:BoxMargin)Also remove LEQ Control Panel? [Y/n]: " -ForegroundColor Yellow -NoNewline
        $removeScp = Read-Host
        if ($removeScp -ne 'n' -and $removeScp -ne 'N') {
            if (Uninstall-SoundControl) { $removed += "LEQ Control Panel" }
        }

        Write-UninstallCompletion -RemovedComponents $removed -KeptComponents $kept `
            -RemovedShortcuts $lnkResult.Removed -FailedShortcuts $lnkResult.Failed

        # Prompt restart if drivers were removed
        if ($removed | Where-Object { $_ -ne 'LEQ Control Panel' }) {
            Write-Host ""
            Write-Host "$($script:BoxMargin)A restart is recommended to fully clear removed drivers." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "$($script:BoxMargin)Restart now? [Y/n]: " -ForegroundColor Yellow -NoNewline
            $restart = Read-Host
            if ($restart -ne 'n' -and $restart -ne 'N') {
                Restart-Computer -Force
            }
        }
        continue mainMenu

    } elseif ($menuChoice -eq 5) {
        $null = Invoke-SonicScoutProfileWizard
        continue mainMenu

    } else {
        # ===============================================================
        # INSTALL: set up the stack, keeping what is already present
        # ===============================================================
        # The retired Hi-Fi Cable is removed rather than warned about. It is the
        # OLD SonicScout2.0 cable, so leaving it behind means two similar-looking
        # devices in the sound panel and constant user confusion. This is a
        # cosmetic cleanup, NOT a prerequisite: VB-CABLE and Hi-Fi Cable have
        # distinct interface descriptions and Get-SonicScout20Endpoints ignores Hi-Fi
        # entirely, so nothing here needs a reboot to proceed.
        # ASIO Bridge Hi-Fi Cable is the cable this setup keeps. Do not uninstall it.
        $hifiLeftBehind = $false
        Write-Host "$($script:BoxMargin)Keeping ASIO Bridge Hi-Fi Cable. VB-CABLE is not the route." -ForegroundColor DarkGray

        # Voicemeeter installs by default -- most users need a mixer -- but never
        # on top of one the user actually relies on. Detection alone cannot decide
        # that: Wave Link ships with Elgato capture hardware and is often present
        # but unused (sometimes without its audio driver at all), and a stale
        # Voicemeeter folder proves nothing either. So detection picks WHAT TO ASK
        # ABOUT, and the user confirms per product.
        $mixers = @(Get-InstalledMixers)
        $wantVoicemeeter = $true
        $usesExisting = $false

        $externalPathHints = @(Get-ExternalAudioPathHints)
        if ($externalPathHints.Count -gt 0) {
            Write-Host ""
            Write-Host "$($script:BoxMargin)Detected a direct-output / external DAC path on this PC." -ForegroundColor Yellow
            foreach ($hint in $externalPathHints) {
                Write-Host "$($script:BoxMargin)  - $hint" -ForegroundColor DarkGray
            }
            Write-Host "$($script:BoxMargin)This path is for Sound Blaster / DAC / USB-audio devices and does NOT use" -ForegroundColor DarkGray
            Write-Host "$($script:BoxMargin)VB-CABLE or Voicemeeter. Keep the direct-output route? [Y/n]: " -ForegroundColor Yellow -NoNewline
            $dacAns = Read-Host
            if ($dacAns -eq '' -or $dacAns -ne 'n' -and $dacAns -ne 'N') {
                $usesExisting = $true
                $wantVoicemeeter = $false
                Write-Host "$($script:BoxMargin)Keeping the direct-output path -- Voicemeeter will not be installed." -ForegroundColor DarkGray
            }
        }

        if ($mixers.Count -gt 0 -and -not $usesExisting) {
            Write-Host ""
            Write-Host "$($script:BoxMargin)Found an audio mixer already installed on this PC." -ForegroundColor Yellow
            foreach ($mx in $mixers) {
                Write-Host "$($script:BoxMargin)Do you use $($mx.Name) as your mixer? [Y/n]: " -ForegroundColor Yellow -NoNewline
                $mxAns = Read-Host
                if ($mxAns -ne 'n' -and $mxAns -ne 'N') { $usesExisting = $true }
            }

            if ($usesExisting) {
                $wantVoicemeeter = $false
                Write-Host "$($script:BoxMargin)Keeping your mixer -- Voicemeeter will not be installed." -ForegroundColor DarkGray
            } else {
                # Nothing here is in use, so Voicemeeter Standard goes in as normal
                # -- except on top of a paid edition. All editions share one folder,
                # one uninstall entry and one audio driver, so Standard can strip the
                # extra virtual inputs Potato/Banana paid for and take over their
                # uninstaller. That is still the user's call, but it has to be made
                # deliberately: this prompt defaults to NO, unlike the [Y/n] above.
                $blocker = $mixers | Where-Object { $_.Blocking } | Select-Object -First 1
                if ($blocker) {
                    Write-Host ""
                    Write-Host "$($script:BoxMargin)Heads up: $($blocker.Name) is a paid edition, and every Voicemeeter" -ForegroundColor Yellow
                    Write-Host "$($script:BoxMargin)edition shares one folder, one uninstall entry and one audio driver." -ForegroundColor Yellow
                    Write-Host "$($script:BoxMargin)Installing Voicemeeter Standard over it can remove the extra virtual" -ForegroundColor Yellow
                    Write-Host "$($script:BoxMargin)inputs you paid for and take over its uninstaller." -ForegroundColor Yellow
                    Write-Host "$($script:BoxMargin)Safer: remove it from Add/Remove Programs first, then run this again." -ForegroundColor DarkGray
                    Write-Host ""
                    Write-Host "$($script:BoxMargin)Install Voicemeeter Standard anyway? [y/N]: " -ForegroundColor Yellow -NoNewline
                    $ovrAns = Read-Host
                    if ($ovrAns -eq 'y' -or $ovrAns -eq 'Y') {
                        Write-Host "$($script:BoxMargin)Installing Voicemeeter Standard alongside $($blocker.Name)." -ForegroundColor DarkGray
                    } else {
                        $wantVoicemeeter = $false
                        Write-Host "$($script:BoxMargin)Leaving $($blocker.Name) alone -- Voicemeeter will not be installed." -ForegroundColor DarkGray
                    }
                } else {
                    Write-Host "$($script:BoxMargin)Installing Voicemeeter as part of the stack." -ForegroundColor DarkGray
                }
            }
        }

        Write-Host ""
        :dlRetryB while ($true) {
            try {
                $files = Get-Downloads -IncludeVirtualAudio -WantVoicemeeter $wantVoicemeeter
                break dlRetryB
            } catch {
                Write-Host ""
                Write-Host "$($script:BoxMargin)Download failed: $($_.Exception.Message)" -ForegroundColor Red
                Write-Host ""
                :dlMenuB while ($true) {
                    $null = Write-CenteredBlock @(
                        @{ Text = '[r] Retry downloads'; Color = 'Yellow' }
                        @{ Text = '[d] Open Discord for help'; Color = 'White' }
                        @{ Text = '[m] Back to main menu'; Color = 'DarkGray' }
                    )
                    Write-Host ""
                    Write-Host "$($script:BoxMargin)" -NoNewline
                    Write-Host "Choice: " -ForegroundColor Yellow -NoNewline
                    $dlChoice = Read-Host
                    switch ($dlChoice.ToLower()) {
                        'r' { break dlMenuB }
                        'd' {
                            Start-Process 'https://github.com/sensoredrooster/SonicScout2.0/issues'
                            Write-Host "$($script:BoxMargin)Opened in browser." -ForegroundColor Green
                            Write-Host ""
                        }
                        'm' { continue mainMenu }
                        default { Write-Host "$($script:BoxMargin)Invalid choice." -ForegroundColor Red; Write-Host "" }
                    }
                }
            }
        }

        # Component results for the completion summary. Initialized to $true BEFORE each
        # guard, because a null $files.X means "already installed, nothing to fetch" --
        # a fatal download failure throws inside Get-Downloads and never reaches here, so
        # the skipped case is a genuine success. Only SoundControl can be null because it
        # FAILED, and that one is reported from $files below rather than from a capture.
        $okVBCable  = $true
        $okVoicemeeter = $true
        $okReaPlugs = $true
        $okEapo     = $true
        $okHeSuVi   = $true
        $okJsfx     = $true

        Write-Host ""
        Write-Host "$($script:BoxMargin)Installing [1/9]..." -ForegroundColor Yellow
        # VB-CABLE installs only when its endpoints do not already resolve
        # (Get-Downloads leaves $files.VBCable null in that case).
        if ($files.VBCable) { $okVBCable = Install-VBCable -ZipPath $files.VBCable }
        Write-Host "$($script:BoxMargin)Installing [2/9]..." -ForegroundColor Yellow
        if ($files.Voicemeeter) { $okVoicemeeter = Install-Voicemeeter -ZipPath $files.Voicemeeter }
        Write-Host "$($script:BoxMargin)Installing [3/9]..." -ForegroundColor Yellow
        if ($files.ReaPlugs) { $okReaPlugs = Install-ReaPlugs -InstallerPath $files.ReaPlugs }

        # Configure the VB-CABLE endpoints (detect/rename/format/icons). Ported
        # SonicScout2.0 stack; restarts audio internally where needed. Returns the
        # resolved render/capture GUIDs for the device-scoped config.txt below.
        #
        # The v1.1 Voicemeeter names (Normal Audio / Virtual Mix) ride along, but
        # ONLY for a Voicemeeter Standard install we were asked for. Two gates,
        # both required:
        #   Standard, no paid edition -- Banana/Potato are the user's own install
        #     (Test-VoicemeeterEdition doubles as provenance) and every edition
        #     shares the one VAIO driver, so renaming its endpoints on a paid box
        #     renames devices the user set up themselves. Also covers the
        #     "install Standard anyway" override above, which leaves both present.
        #   $wantVoicemeeter -- false means the user kept Wave Link or a paid
        #     mixer. We do not install their mixer, so we do not rename it either.
        $vmEdition = Test-VoicemeeterEdition
        $renameVoicemeeter = ($wantVoicemeeter -and $vmEdition.Standard -and -not $vmEdition.PaidPresent)
        Write-Host "$($script:BoxMargin)Installing [4/9]..." -ForegroundColor Yellow
        $script:SonicScout20Endpoints = Set-SonicScout20Endpoints -IconBaseUrl $script:AssetBase -Margin $script:BoxMargin -IncludeVoicemeeter $renameVoicemeeter

        Write-Host "$($script:BoxMargin)Installing [5/9]..." -ForegroundColor Yellow
        if ($files.EAPO) { $okEapo = Install-Eapo -InstallerPath $files.EAPO }
        # E-APO's installer re-binds its APO onto the selected devices. Without a
        # fresh audio restart afterwards, some PCs are left with dead audio on
        # EVERY output until a manual reboot.
        if ($files.EAPO) { Restart-AudioServices }
        # Version-aware library decision (stamp presence only; no compare, no manifest).
        $libState = Get-SonicScout20LibraryState
        if ($libState.State -eq 'Versioned') {
            $verLabel = if ($libState.Version) { " $($libState.Version)" } else { "" }
            Write-Host "$($script:BoxMargin)Existing SonicScout2.0 library$verLabel detected - keeping it." -ForegroundColor Green
            Write-Host "$($script:BoxMargin)Use [3] Redownload Library to update (it backs up your custom EQs first)." -ForegroundColor DarkGray
        } elseif ($libState.State -eq 'OldUnversioned') {
            Write-Host "$($script:BoxMargin)An older SonicScout2.0 library (no version stamp) was found." -ForegroundColor Yellow
            Write-Host "$($script:BoxMargin)Backing it up to Documents\SonicScout2.0 Backups\, then installing the new versioned library..." -ForegroundColor Yellow
            $null = Install-SonicScout20Library
            Write-Host "$($script:BoxMargin)Old squig.link EQs are recoverable from that backup via the SonicScout2.0 desktop shortcut." -ForegroundColor DarkGray
        } else {
            $null = Install-SonicScout20Library -SkipBackup
        }
        Write-Host "$($script:BoxMargin)Installing [6/9]..." -ForegroundColor Yellow
        if ($files.HeSuVi) { $okHeSuVi = Install-HeSuVi -InstallerPath $files.HeSuVi }
        Write-Host "$($script:BoxMargin)Installing [7/9]..." -ForegroundColor Yellow
        $null = Install-SonicScout20HRIR
        $null = Write-InitialConfig -RenderGuid8 $script:SonicScout20Endpoints.Render8 -RenderGuid16 $script:SonicScout20Endpoints.Render16
        # After Write-InitialConfig, which is what creates the config.txt and boost.txt
        # the card describes and guarantees the SonicScout2.0 folder exists. Unconditional
        # on this path, so the card is refreshed on every run. The -TwoChains signal is
        # Write-InitialConfig's own $emit16 condition.
        Write-FolderReadme -TwoChains ([bool]($script:SonicScout20Endpoints.Render8 -and $script:SonicScout20Endpoints.Render16))
        Write-Host "$($script:BoxMargin)Installing [8/9]..." -ForegroundColor Yellow
        $okJsfx = Install-JsfxPlugins
        $null = Install-VstPlugins
        Write-Host "$($script:BoxMargin)Installing [9/9]..." -ForegroundColor Yellow
        if ($files.SoundControl) {
            $null = Install-SoundControl -SourcePath $files.SoundControl
        } elseif ($files.SoundControlPresent) {
            Write-Host "$($script:BoxMargin)LEQ Control Panel already installed." -ForegroundColor Green
        } else {
            Write-Host ""
            Write-Host "$($script:BoxMargin)LEQ Control Panel download failed." -ForegroundColor Yellow
            Write-Host "$($script:BoxMargin)Press [d] to open the GitHub releases page, or any other key to continue." -ForegroundColor Yellow
            Write-Host ""
            $dlKey = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown').Character
            if ($dlKey -eq 'd' -or $dlKey -eq 'D') {
                Start-Process 'https://github.com/sensoredrooster/LEQControlPanel/releases'
                Write-Host "$($script:BoxMargin)Opened in browser." -ForegroundColor Green
            }
        }

        # Anonymous setup counter (success path only).
        Send-SetupPing -Mode 'voicemeeter'

        # ExePresent, not Present: a leftover uninstall registry key with nothing on
        # disk is not a mixer, and must not render a green tick. ANDed with the
        # install result so a failed install is never reported as a success.
        $vmFinal = ((Test-VoicemeeterEdition).ExePresent -and $okVoicemeeter)
        $result = Write-Completion `
            -SoundControlInstalled ([bool]($files.SoundControl -or $files.SoundControlPresent)) `
            -VoicemeeterInstalled $vmFinal `
            -VBCableInstalled $okVBCable `
            -ReaPlugsInstalled $okReaPlugs `
            -EapoInstalled $okEapo `
            -HeSuViInstalled $okHeSuVi `
            -JsfxInstalled $okJsfx `
            -EndpointsVerified $script:SonicScout20Endpoints.Verified `
            -ConfigIsPlaceholder $script:ConfigIsPlaceholder

        # Cleanup
        Remove-Item $script:TempPath -Recurse -Force -ErrorAction SilentlyContinue

        if ($result -eq 'mainMenu') { continue mainMenu }
        if ($result -eq 'quit') { break mainMenu }
    }

    # All paths complete -- exit the main menu loop
    break

    } # end :mainMenu

} catch {
    Write-Host ""
    Write-Host "$($script:BoxMargin)FATAL ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "$($script:BoxMargin)Line: $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Red
    Write-Host ""
    Write-Host "$($script:BoxMargin)If this keeps happening, report it at:" -ForegroundColor White
    Write-Host "$($script:BoxMargin)https://github.com/sensoredrooster/SonicScout2.0/issues" -ForegroundColor Cyan
    Write-Host ""
} finally {
    # Runs on the success path, the fatal path, and any future exit from the menu loop.
    # The success-path cleanup above stays: it clears temp per menu iteration, which this
    # alone would not do once the flow hits "continue mainMenu". Both are idempotent.
    Remove-Item $script:TempPath -Recurse -Force -ErrorAction SilentlyContinue
}

