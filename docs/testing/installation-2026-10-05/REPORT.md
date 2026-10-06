# SonicScout first-time installation test

Date: October 5, 2026 (America/Chicago)
Project: C:\Users\brand\OneDrive\Documents\SonicScout2.0\SonicScout-main
Scope: acquiring the app, prerequisites, packaging, starting installation, error handling and installation completion. Profile setup, routing performance and listening tests belong to round two.
Status: Installation review pass completed with blockers. A successful fresh-machine installation was not achieved.

## Findings

A first-time user following the README's recommended instructions cannot complete the first step from this checkout. The application itself publishes successfully, but the documented packaging and installation entry points do not agree. Passing builds and dry runs do not establish that a fresh machine can install it.

Evidence is in the adjacent evidence/ folder. Actual executions, simulated checks and source inspection are distinguished below.

| Priority | Finding | Evidence type |
|---|---|---|
| P1 | Recommended source-folder installer immediately refuses to run | Actual batch execution |
| P1 | Packaging batch uses obsolete paths and cannot publish | Actual batch execution in an isolated copied layout |
| P1 | Published output omits installation entry point and main installer script | Actual direct publish + file inventory |
| P1 | Preflight enters endpoint/configuration-writing code | Real script control flow with fake state and fake mutation functions |
| P1 | Missing APO configuration script still produces final READY and exit 0 | Real script control flow with simulated installed dependencies |
| P1 | Library/latest release and Refined HRIR URLs are unavailable | Actual HTTP requests |
| P2 | Launcher ignores missing-prerequisite exit code | Actual launcher with stubbed preflight and dotnet |
| P2 | Runtime prerequisites and install paths are unclear | Documentation + packaging review |
| P1 | Script elevation helper relaunches with an empty -File path, then exits 0 | Real helper function with mocked process launch |
| P2 | Interactive main installer is dot-sourced inside automation | Source review; needs clean VM confirmation |
| P2 | Wizard offers AUDIO STACK READY / DONE for a BLOCKED check result | Real wizard with injected blocked result; normal-flow reachability not yet established |
| P2 | Missing prerequisites are labeled READY in preflight | Actual clean Windows VM |
| P1 | Bundled VB-Cable installer fails because companion driver files are missing | Actual elevated Windows VM install |

## Reproduction and user impact

### 1. Recommended first step fails (P1)

README says to run tools/SonicScoutCSharp/Install-SonicScout.bat as Administrator. This batch requires SonicScout.exe directly beside it. There is no executable at that path in this checkout. Running it prints:

> SonicScout.exe was not found. Run publish_sonic_scout.bat again and use the published SonicScout folder.

It exits 1. A new user has been told to install, but is now being asked to publish software without explanation. Source users should have a separate SDK-based path; release users should receive one explicit download/extract/run path. Evidence: source-install.txt.

### 2. Suggested packaging recovery fails too (P1)

publish_sonic_scout.bat changes to tools/ and tries CSharp/SonicScout.CSharp.csproj. The actual project is tools/SonicScoutCSharp/SonicScout.CSharp.csproj. Reproduced in a disposable layout with the same relative paths and a disposable USERPROFILE, protecting the real Desktop. Output: MSB1009, project file does not exist; exit 1. The subsequent CSharp/... and profiles/... copies also use obsolete paths.

The script also deletes Desktop/SonicScout before checking whether publishing works. This was not run against the real Desktop; source inspection shows that a failed publish could destroy an existing exported build. Publish to a staging directory, validate it, then replace the destination. Evidence: publish-batch.txt.

### 3. Successful direct publishing does not produce the documented install package (P1)

A direct dotnet publish against the actual csproj succeeds. SonicScout.exe and SonicScout.SonicPass.exe are present. However Install-SonicScout.bat and Install-SonicScout2.0.ps1 are absent. README_CSHARP tells destination-PC users to run the missing batch. setup_audio_stack.ps1 expects the main script beside the app or in a repository-relative powershell directory; an extracted standalone build has neither.

The output includes local Equalizer APO and cable installers, but this checkout lacks bundled ReaPlugs, Voicemeeter and HeSuVi executables. Thus the README's blanket statement that dependencies ship with the app and need no downloads is misleading. Evidence: direct-publish.txt and published-manifest.json.

### 4. Read-only preflight can invoke mutations (P1)

setup_audio_stack.ps1 gates elevation and installer launch by Mode, but its APO Configuration block runs whenever readyForTesting is true. It does not check Mode=Install. Startup invokes this script in Preflight mode.

In an isolated copy, replaced device discovery with a simulated healthy installed stack, replaced setup-history writing with a print statement, and supplied a fake main installer whose functions only print. Running -Mode Preflight invoked both Set-SonicScout20Endpoints and Write-InitialConfig, plus setup-history saving. No actual registry, services or audio configuration were changed by this reproduction.

On real devices the supplied functions perform endpoint changes and overwrite config. With the actual main script, dot-sourcing may first enter the interactive menu (finding 10). Gate all mutation and history-writing operations explicitly by install mode. Evidence: preflight-side-effects.txt, preflight-stubbed.ps1, fake-main-installer.ps1.

### 5. Failed configuration still reports installation success (P1)

Same isolated real-control-flow test, with the main script absent: APO Configuration reports UPDATE / main installer not found, then Final verification reports READY and exits 0. Required ReaPlugs missing in Preflight is also labeled READY because that installer stage is not marked Required.

The readyForTesting predicate checks APO plus a route and the audio service; it does not incorporate all stage failures, library/plugins, successful configuration, or a pending restart. The C# bridge treats exit 0 as successful script completion. Completion must reflect required stage results. Evidence: preflight-missing-main.txt. This is a simulated installed-state test, not a completed live installation.

### 6. Required hosted resources return 404 (P1)

Actual HTTP checks on October 5 returned:

- Main installer raw GitHub script: 200.
- SonicScout2.0 releases/latest API: 404.
- hrir/EAC_Refined.wav: 404.
- hrir/44/EAC_Refined.wav: 404.
- LEQControlPanel releases/latest API: 404.

These URLs are used by the local installer. The library is load-bearing for tunes/plugins; the API failure is an installation blocker unless another working source supplies it. The source installer has a bundled-library fallback when run from a checkout. The online irm/iex path has no adjacent checkout library, and the standalone published package currently lacks it. Both the hardcoded library ZIP fallback and LEQ executable fallback also return 404 (fallback-url-checks.txt). The complete installer recovery behavior remains to be exercised in the VM. Validate all published asset URLs during release and supply a tested library fallback. Evidence: network-checks.json.

### 7. Launcher skips its missing-prerequisite prompt (P2)

run_sonic_scout_csharp.bat sets PRECHECK inside a parenthesized IF block and reads %PRECHECK% within that same block, with delayed expansion disabled. cmd expands the value before the preflight command runs. A copied launcher, fake preflight returning 2, and harmless dotnet shim proceeded directly to dotnet without the advertised missing-dependency prompt. Similar early expansion affects SETUP_RESULT/RESULT reads in other nested blocks.

The application's own startup gate may still catch missing setup, so this is a launcher failure rather than proof the app bypasses all checks. Fix batch control flow or expansion. Evidence: launcher-preflight-exit2.txt.

### 8. First-time instructions leave avoidable uncertainty (P2)

- The source README recommends an installer that expects a release layout.
- .NET 8 SDK/runtime prerequisites appear in a secondary README, not the primary Requirements section. Framework-dependent publishing requires a desktop runtime on a clean PC; no runtime bootstrap is in the recommended installer batch.
- The local PowerShell command names only Install-SonicScout2.0.ps1 although the script is inside powershell/. It fails if copied from the repository root.
- The app launcher builds from source, while the installer expects a prebuilt executable. Users are not told clearly which artifact they downloaded.
- Documentation says the wizard has one authorization checkbox, but recovery hints still say “all 3 consent boxes.”
- “Default Audio Output,” “routing ownership” and “Compatibility Route” ask for technical decisions before explaining what changes will be made. Prefer “Headphones or speakers you listen through,” a recommended default, and a brief concrete description of installed components.
- Fixed 720x700, nonresizable setup window may be difficult on small screens/high DPI. Needs visual VM verification.

### 9. Elevation helper loses the script path and reports success (P1, isolated function reproduction)

run_audio_stack_setup.bat uses Start-Process -Verb RunAs -Wait but does not propagate the child process ExitCode via -PassThru. setup_audio_stack.ps1's own elevation helper starts an elevated child and exits 0 without waiting; its MyInvocation.MyCommand.Path is resolved inside a function, and relaunch does not preserve all install options. An isolated execution of the exact Request-ElevationIfNeeded function with Test-Administrator returning false and a harmless mocked Start-Process produced: powershell.exe -NoProfile -ExecutionPolicy Bypass -File "" -Mode Install. The helper exited 0. No UAC prompt or real child process was launched in this reproduction. Preserve the script-level path and arguments, wait, and propagate the real exit code. Confirm UAC cancel and child failure in the clean VM. Evidence: elevation-function-test.txt and elevation-function-test.ps1.

### 10. Automation imports a script with a live menu (P2, inspection only)

setup_audio_stack.ps1 dot-sources the entire powershell/Install-SonicScout2.0.ps1 to obtain helper functions. That script contains top-level main execution and Read-Host menu prompts, with no dot-source guard. The bridge launches setup noninteractively with redirected streams. This can block or fail during supposed automated configuration. Extract a module or guard the entry point; confirm behavior live in the VM before labeling the exact symptom.


### 11. Wizard labels a blocked check result as ready (P2, rendered contract test)

A focused harness links the real SetupWindow.xaml and code-behind. Its injected installer callback emits and returns one BLOCKED required-installer result. The wizard displays “STEP 3 OF 4 | AUDIO STACK READY” and DONE despite the blocked row. Two expectations fail: blocked setup must not claim ready, and must not offer DONE. This is a simulated installer outcome, not a real driver failure; the rendering and wizard control flow are real. A normal production path producing this exact result has not yet been established, so treat this as a robustness and UX defect rather than a confirmed live-install blocker.

BeginSetupButton_Click counts only UPDATE and ERROR as problems, omitting BLOCKED. Include blocked states in the completion gate, and consistently preserve failed/blocked status in the header, next-action hints and buttons. Evidence: wizard-blocked/blocked-install.png, blocked-result.txt and wizard-blocked-test.txt. The harness source/project are preserved beside the screenshot.

First-time impression from the rendered window: most of the window remains occupied by the output selection/authorization form after installation, leaving only a small scrollable area for actual installation results and recovery steps. Collapse completed inputs and give results/recovery more space. Label the action “Retry installation” after a failure rather than keeping “RUN INSTALL SETUP.”

## Checks that passed

- Actual direct Release win-x64 framework-dependent publish succeeds.
- SonicPass executable and supporting files appear beside the published app.
- Installer dry run emits planned operations without installing drivers.
- Raw GitHub installer entry point is reachable.
- Source checkout remained unchanged apart from new testing evidence/report files.

## VM and preservation

Original SonicScout-Test was powered off initially, had no snapshots, and its disk is effectively empty. Saved Before-SonicScout-install-test-2026-10-05 snapshot before starting it. Boot failed with no bootable medium; screenshot preserved. Powered it off afterwards.

User authorized downloading compatible Windows and a disposable account. A second official Windows 11 Enterprise LTSC x64 evaluation ISO was also downloaded and hashed as a fallback; it is not the currently installed guest. Downloaded Microsoft's Windows 11 Enterprise x64 evaluation ISO (8,225,329,152 bytes; build 10.0.26300.9457) from its [official Evaluation Center](https://www.microsoft.com/en-us/evalcenter/download-windows-11-enterprise). SHA-256 is preserved in evidence/windows-iso-sha256.json. Created a separate SonicScout-Install-QA-20261005 VM. EFI with two CPUs stalled in VirtualBox firmware; one CPU booted but Windows rejected the core count. The working installation rig uses 4 GB RAM, 2 CPUs, a separate 64 GB dynamic QA-BIOS.vdi disk, legacy BIOS, TPM 2.0 and virtual HD audio. Added explicit NTFS formatting and an active partition to the VirtualBox unattended template. The supplied VirtualBox template includes Windows hardware-check bypasses; this is an installation test environment, not a claim that this VM meets all supported Windows 11 hardware requirements. The original failed QA.vdi remains intact. The host's existing audio drivers/configuration are untouched.

## Follow-up coverage after installation blockers are fixed

1. Repeat clean Windows tests with the corrected release package. Clean Windows and missing/runtime-installed launch behavior were covered in this pass.
2. Complete source and release installation successfully. This pass reproduced entry-point failures and exercised the directly published app.
3. UAC cancellation and a true standard-user account. This pass covered a medium-integrity administrator account, UAC acceptance, and an explicitly elevated installer run.
4. Successful driver installation, reboot and resume. This pass covered missing driver files, Equalizer APO device-selection dismissal, and Hi-Fi Cable cancellation.
5. Disconnected-network recovery. Missing installers and unavailable release URLs were exercised; offline behavior was not.
6. Successful final status and reboot guidance. Incomplete-state UI, real installation reports, runtime files and Equalizer APO installed files were captured.
7. Repeat installation after partial failure.
8. High-DPI readability. Live screenshots covered default DPI at 1024×768 and 1920×1080; high DPI was not tested.

The original TEST-REPORT.md describes build/dry-run/stubbed-window tests; it explicitly did not perform live driver installation. This report does not treat those earlier passes as fresh-PC installation success.

## Live VM continuation

Windows reached its desktop with an evaluation license valid for 90 days. VirtualBox Guest Additions 7.2.20 is installed. Guest execution initially reported that its service was not ready, so the disposable guest was restarted; guest processes can now start. The shared-folder connection did not work in the guest, so files were transferred using guestcontrol copyto. Fresh-machine transcripts, runtime install logs and actual SonicScout install reports were then collected. These VM integration problems are environment observations, not SonicScout defects.


### 12. Fresh-machine preflight marks absent requirements READY (P2, live Windows VM)

On Windows 11 Enterprise Evaluation x64 10.0.26300 with no SonicScout audio dependencies installed, Preflight labels VB-Cable Base, Equalizer APO and ReaPlugs READY. Their explanations say they are required rather than reporting whether they are installed. A later Equalizer APO verification row and the final row return UPDATE, and the process exits 2. The final exit code is correct, but the earlier green READY labels contradict it. Use MISSING or NOT INSTALLED for missing prerequisites and reserve READY for verified success. Evidence: fresh-machine-live.txt.

### Fresh-machine results

The real guest is build 10.0.26300 (the desktop watermark shows an older base-build string). The disposable administrator account runs these probes with a medium-integrity, unelevated token. The recommended source installer exits 1 because SonicScout.exe is absent. The source launcher skips the prerequisite prompt despite Preflight exit 2, then fails to build because the SDK is absent, returning 1 and telling the user to install .NET 8 SDK. The directly published executable also fails without .NET: hostfxr.dll is absent, exit -2147450749 (0x80008083). The runtime probe disables the GUI error dialog to capture diagnostic text; it is not a screenshot of the normal launch experience. Evidence: fresh-machine-live.txt and runtime-missing.txt. These are real guest executions, separate from the earlier mocks.


### 13. Bundled VB-Cable cannot install because driver files are separated (P1, live VM)

Ran the actual published setup_audio_stack.ps1 as administrator in the disposable Windows guest, with ownership accepted. It selects installers/VBCABLE_Setup_x64.exe. The vendor executable immediately shows “Missing 'inf' file or Driver package corrupted” and says to extract all files into a folder and run setup there. After dismissing the error, SonicScout reports VB-Cable installer exit -1 and proceeds to Equalizer APO. The selected root executable has no adjacent INF/SYS files; the driver files live in the nested VBCABLE folder, which lacks the x64 setup executable. Preserve each vendor package together, select the setup executable in that complete directory, and validate required companion files before starting. Evidence: vbcable-live-missing-inf.png and vbcable-selected-package.json.

The installation console claims VB-Cable is “the only manual click in the whole install.” Equalizer APO 1.4.2 nevertheless opens a Device Selector and follow-up dialogs even with the chosen silent flags. No SonicScout-specific explanation tells a novice what to choose in that selector. In this cancellation probe, no devices were selected and Escape dismissed the selector; a device-test result and informational dialog still followed. Document the real third-party prompts and provide instructions at the point they occur. Screenshot: equalizer-apo-device-selector.png.

The unelevated real wizard finishes with REVIEW ITEMS NEEDING ATTENTION / CLOSE AND REVIEW, and a permissions message asking for an administrator restart. This is correct incomplete-state handling for this actual run; it does not reproduce the injected BLOCKED header defect in finding 11. The real window confirms the constrained scrolling result area. Screenshot: wizard-live-incomplete.png. Installing Microsoft's Windows Desktop Runtime 8.0.31 x64 in the guest succeeds with exit 0, and the published app then opens.

## End-of-pass result and recommended order

Fix the documented source/publish paths and release packaging first, including a complete VB-Cable x64 package and a clear .NET bootstrap. Next make preflight genuinely read-only, propagate installation/elevation failures, and remove false READY labels. Finally simplify the wizard's results/recovery area and explain each real vendor prompt. These changes remove the earliest first-time-user blockers before further routing or listening tests.

In the elevated cancellation run, Equalizer APO files were installed successfully, VB-Cable failed with exit -1, Hi-Fi Cable was closed without installing, and ReaPlugs remained missing. The ReaPlugs downloader said it had downloaded the file, then also downloaded HeSuVi; the stage nevertheless asked the user to supply the ReaPlugs installer. The exact downloader failure needs a focused follow-up; do not infer a successful ReaPlugs installation from its download message. The final saved installation report correctly says the route is incomplete. See guest-live/sonicscout-logs/logs/audio-setup-report-20261005-221741.json and audio-setup-history.log.

No product code was changed. Only testing artifacts were added to the repository. All audio/runtime changes occurred in the separate disposable VM. Profile setup, routing quality and listening tests remain outside this pass. The VM and both official x64 evaluation ISOs are retained, and the persistent QA directory holds source/build inputs and guest evidence. The disposable credential is kept outside the repository and evidence archive.

