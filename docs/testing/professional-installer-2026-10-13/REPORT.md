# Professional installer and end-to-end verification — 2026-10-13

Status: **release qualification failed; development build only.** The VM walkthrough found and repaired several defects, but game-target processing, vendor installation prompts and hardware audio qualification remain blockers. This is not a tester-release approval.

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

## Continued VM walkthrough

The E2E clone had Equalizer APO, VB-Cable and standalone .NET runtime removed, dependencies backed up, and Windows rebooted. The baseline showed only physical endpoints, no APO configuration, no ReaPlugs DLL and no installed .NET runtime. The self-contained EXE installed and launched successfully.

| Scenario | Actual result |
|---|---|
| Decline elevation | Passed: reported blocked administrator access and offered retry |
| Fresh dependency installation | Completed, but VB-Cable, ReaPlugs and HeSuVi vendor prompts remained; not fully automatic |
| APO selector handoff | Original package reproduced unwanted selector. The subsequent managed-child handoff repair passed without selector interaction; see `selector-handoff-test.txt` |
| Reboot recovery | Correctly reported restart required; rebooted and subsequent setup completed READY |
| Round2 replacement | GUI installation and launch passed; final stages no longer showed stale RUNNING rows |
| Default audio route | SonicPass GUI running on normal SonicScout2.0 cable → physical Speakers, 20 ms setting |
| Game selection | Black Ops 7 (V0) selected and target saved; **functional qualification failed: curve is not applied** |
| Headphone correction | AutoEQ 1Custom SA02 downloaded and activated with −6 dB preamp and ten correction filters |
| Live EQ slider | Passed: GUI +7 dB at 60 Hz appended adjustments and retained all imported filters and preamp; slider returned to neutral afterward |
| Diagnostics/local ZIP | Passed: window opened, bundle created and inspected; three setup reports, installation transcripts, error/app logs and routing configuration included. Nothing uploaded |
| Stop/start | STOPPED state displayed; manual start exercised. This alone does not establish audible output |
| Normal shortcut reopen | Launched without elevation. Reproduced duplicate target tile and lost profile metadata; fixed in subsequent source. Setup reappeared because manual verification was incomplete |
| GUI uninstall | Completed; executable, public desktop shortcut and Installed Apps entry removed; active user EQ and shared APO configuration retained. Unrelated-file sentinel creation failed without elevation, so that specific preservation case was not exercised |
| Latest EXE reinstall | GUI reinstall completed and launched; legacy profiles migrated to LocalAppData and paired target sidecar no longer created a second tile |
| Automatic profile activation | Latest EXE: downloaded 1Custom SA03 activated immediately; correct name/category metadata saved in user data |
| Profile persistence | Latest EXE normal desktop-shortcut launch restored 1Custom SA03 as active with its correct name/category after closing the incomplete manual verification wizard; no activation click needed. `final-normal-persistence-pass.png`, local routing JSON and committed `profile-metadata.json` provide evidence |
| Actual physical-output signal | Quiet 1,234 Hz test tone sent to the 8-channel cable. SonicPass stopped: physical loopback silent; running: 838,376 float samples, RMS 0.00469994, peak 0.03362576. This verifies signal reaches the VM's physical endpoint, not sound quality, fidelity, latency or game behavior; see `route-probe-*.txt` |

Further fixes: wait only for the VB installer process rather than its thank-you browser; reconcile final progress; concurrently drain preflight output; include installation reports in diagnostics; prefer 8-channel initial routing. Profiles now live in per-user LocalAppData, legacy originals remain intact during migration, target sidecars are excluded from profile tiles, downloaded profiles activate immediately, and metadata/active selection persist.

The game-target defect is **not fixed** by saving metadata: the label now explicitly says the target is saved, not applied. Correct target processing requires implementation and audio verification.

Evidence in the local QA folder: `continued-profile-added.png`, `continued-diagnostics.png`, `continued-bundle.png`, `continued-stop-slider.png`, `continued-normal-reopen.png`, `continued-uninstall-complete.png`; `evidence-fresh/active-profile-after-gui-slider.txt`, `support-continued-43492b72c0df.zip`, `uninstall-continued-result.json`.

An unexpected guest reboot happened before audio setup executed; no evidence attributes it to the app. Guest scheduling also stalled commands. The attempted live snapshot of the older GUI VM was cancelled and is not a recovery checkpoint.

## Remaining release blockers

1. Game-target curves are saved but not applied. Arbitrarily stacking filters would not establish the intended target calculation.
2. Fresh setup still requires vendor prompts and opens browsers. Silent dependency installation/extraction needs a clean-machine retest.
3. Manual verification asks for running SonicPass while the modal setup window prevents starting it. The user must leave the dialog first; this needs a coherent verification flow.
4. Initial spectrum input may be the physical microphone, independent of game routing. CONNECTED/SIGNAL labels do not prove audible content.
5. Voicemeeter fallback, Wave Link, GC7, real game output, sound quality, latency and underruns have not passed this round.
6. APO changes have backups but no automatic transactional rollback. Shared components remain after uninstall and should be explained by its UI.

VirtualBox scheduling stalls prevent a credible assessment of real gaming latency, sound quality or underruns. A running engine and APO gain response do not establish these results. No real game has been installed in the VM.

The latest source removes the extra profile activation click. Catalog-only entries without downloadable filters remain. Installer branding is standard NSIS and the EXE is unsigned, so it remains a development artifact.

## Evidence and build locations

Local full logs, screenshots, backups and build artifacts: `C:\Users\brand\Documents\SonicScout-GUI-QA-2026-10-13`. Disposable VM accounts and credentials are excluded from the repository.

VMs: `SonicScout-GUI-QA-20261013` for upgrade/automatic-APO verification; `SonicScout-E2E-QA-20261013` for fresh dependency testing. Both are isolated from host audio configuration. The second VM is a linked clone of the original verified installation snapshot; dependencies were removed and the baseline rechecked before the fresh-component run.

Latest unsigned development installer: `C:\Users\brand\Documents\SonicScout-GUI-QA-2026-10-13\final-installer\SonicScout-Setup.exe`, 127,149,559 bytes, SHA256 `2E391630F6C6DB9D4C5550AF0B17CD6D4100E2D328F1F1CEAA346797C3838E19`. Includes the continued-walkthrough fixes above. Earlier Round2 and other installer folders are superseded; no release was published.

Developer build command (NSIS compiler downloaded separately):

```powershell
./tools/packaging/build_installer.ps1 -CompilerPath 'C:\BuildTools\nsis-3.11\makensis.exe' -OutputDirectory 'C:\BuildOutput'
```

The script publishes the app and companion when a payload directory is omitted. It includes the root licence and generates uninstall commands only for packaged files. No compiler, installer binaries or VM credentials are committed.
