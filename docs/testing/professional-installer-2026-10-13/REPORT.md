# Professional installer and end-to-end verification — 2026-10-13

Status: development build; end-to-end testing is in progress. This is not a tester-release approval.

## Implemented changes

- Added a self-contained Windows x64 EXE installer using NSIS 3.11, with installation wizard, shortcuts, Installed Apps entry and a file-manifest-based uninstaller. Users open the app instead of batch files.
- Added automatic cable-only Equalizer APO LFX/GFX registration. Setup backs up endpoint settings, registers APO, installs the existing LEQ chain on the 8-channel cable, then finalizes APO and restarts Windows audio between phases. The 16-channel cable has no LEQ child processors.
- Requires both LFX and GFX slots to resolve to installed Equalizer APO classes. Competing cable effects must be removed before success is reported. Hardware effect slots are not targeted.
- Kept headphone EQ inside the managed cable-scoped include, and repaired normal-user file access. The root configuration ends with `Device: all`.
- Added live wizard progress. A Windows PowerShell 5.1 error in the first progress implementation was reproduced and fixed: `File.Replace` now uses an explicit backup filename. A progress-file failure cannot stop installation.
- Collapses installation choices while setup runs. Removed batch-file and manual APO selector instructions from the app's installation/restart flow.
- Removed a false claim that saving routing metadata enables a proprietary tuning algorithm.
- Found and fixed an EQ editor bug: moving a slider previously replaced the imported headphone filters and removed their preamp. Adjustments now have a separate marked block, retaining the imported correction and includes.

## Executed checks

| Check | Result and limits |
|---|---|
| Self-contained app and companion publish | Passed; no build warnings or errors |
| NSIS installer compilation | Passed with no compiler warnings; unsigned development EXE |
| Windows installer GUI | Welcome, licence, destination, install progress, Finish and app launch exercised in Windows 11 x64 VM |
| In-app installation on existing dependencies | Passed after fixing the progress writer; automatic registration completed without opening APO Device Selector or a terminal |
| APO repeat/repair | Passed after enabling forced LEQ repair; physical-output effect values unchanged; see `automatic-apo-regression.txt` |
| Live APO processing | Passed on 16-channel render → processed stereo capture: requested −12 dB, measured −12.076 dB; see `apo-runtime-result.txt` |
| SonicPass start | Started automatically after setup; GUI reported running processed stereo route to the physical output |
| Headphone profile | AutoEQ 1Custom SA02 downloaded, added, activated; active file contained its preamp and ten filters, linked from managed EQ |
| EQ preservation regression | Passed for imported preamp, correction filters, includes and repeated slider edits; `EqRegression.csproj` |
| Installation regressions | Passed using Windows PowerShell 5.1: read-only preflight, optional mixer, APO binding, reboot marker, failed configuration, import safety, elevation arguments and download validation |
| SonicPass regressions | Passed: stereo isolation/unity gain, silent additional output channels, endpoint identity pairing, input rejection and 20 ms default |

The first live audio probe was invalidated while setup was restarting Windows audio. Repeating after setup settled passed. It temporarily changed the managed EQ to measure gain and restored the original file in `finally`.

## End-to-end test still underway

Fresh dependency installation and reboot/recovery, final package retest with EQ fix, normal-user reopening, live slider editing, diagnostics export, game-target selection, stop/start routing, upgrade and uninstall require further VM walkthrough results. Windows driver/vendor dialogs are still part of some fresh-install paths. Voicemeeter fallback and GC7 hardware behavior have not passed this round.

VirtualBox scheduling stalls prevent a credible assessment of real gaming latency, sound quality or underruns. A running engine and APO gain response do not establish these results. No real game has been installed in the VM.

Known usability findings: `Use profile` currently adds a tile requiring another activation click; the profile picker lists some catalog-only entries without downloadable filters; the Windows verification dialog requires leaving it to start SonicPass; the GUI's connected/signal labels do not prove that a game is sending audible content. Shared drivers and APO configuration remain after application uninstall.

## Evidence and build locations

Local full logs, screenshots, backups and build artifacts: `C:\Users\brand\Documents\SonicScout-GUI-QA-2026-10-13`. Disposable VM accounts and credentials are excluded from the repository.

VMs: `SonicScout-GUI-QA-20261013` for upgrade/automatic-APO verification; `SonicScout-E2E-QA-20261013` for fresh dependency testing. Both are isolated from host audio configuration. The second VM is a linked clone of the original verified installation snapshot and must have dependencies removed before it qualifies as a fresh-install test.

Developer build command (NSIS compiler downloaded separately):

```powershell
./tools/packaging/build_installer.ps1 -CompilerPath 'C:\BuildTools\nsis-3.11\makensis.exe' -OutputDirectory 'C:\BuildOutput'
```

The script publishes the app and companion when a payload directory is omitted. It includes the root licence and generates uninstall commands only for packaged files. No compiler, installer binaries or VM credentials are committed.
