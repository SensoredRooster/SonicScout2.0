# Installation fixes and verification

Updated October 6, 2026 (America/Chicago). Scope: installation only. The original [installation report](../installation-2026-10-05/REPORT.md) remains historical evidence.

Status: installation round one completed for the standard Windows x64 package route. Recovery installation and a repeat with audio dependencies and system .NET runtimes absent both passed. After a fresh boot, Install-SonicScout.bat returned 0 and launched the app. Live unprivileged preflight returned 0 without changing installed files or logs. Setup, profiles, routing and listening tests have not been run.

## Changes against the original findings

| Original finding | Fix | Verification |
|---|---|---|
| Source installer requires a missing executable | Source entry point publishes first, then installs the complete exported package | Actual batch with a stub publisher; actual canonical publishing |
| Publisher has obsolete paths and deletes existing output | Correct project paths; publish to staging, validate, preserve prior output | Actual publish; injected failed publish preserves existing files |
| Published output misses installer and assets | Copy installation scripts, library, plugins, HRIR and README; self-contained app and SonicPass; canonical publisher builds LEQ companion | Published file inventory and build |
| Preflight writes configuration | Configuration imports and writes restricted to installation; no preflight history writes | Real control flow with simulated state and file hashes |
| Missing configuration still returns success | Configuration failures, missing files and unattached APO block completion | Regression checks; live retry reports |
| Release/HRIR/LEQ endpoints unavailable | Bundled library, Default HRIR and locally built LEQ remove these dependencies from the complete-package route | Offline asset installation in VM; source bundle checks |
| Launcher ignores prerequisite exit code | Delayed expansion handles current preflight and installation exit codes | Actual launcher with harmless native stubs |
| Runtime and installation instructions unclear | Distinguish SDK for source builds from self-contained releases; explain elevation, vendor prompts and reboot/retry | README review; app starts in VM with system .NET runtimes absent |
| Elevation loses path/options and returns early | Preserve absolute path, consent and choices; wait and propagate child exit | Mocked helper; real VM elevation and cancellation |
| Importing main installer executes menu | Dot-source helper imports return before main execution; isolate helper globals in a module | Regression import; actual VM asset configuration |
| BLOCKED wizard result says READY/DONE | Count BLOCKED as a problem; offer review/retry; stop downstream work when installation fails | Real wizard with injected blocked result, five assertions; live declined-permission and retry screenshots |
| Missing prerequisites say READY | Preflight reports incomplete requirements and returns nonzero | Controlled regressions; live VM checks |
| VB-Cable installer separated from driver files | Extract complete archive, require adjacent INF/SYS and run x64 setup in its own folder | Actual vendor success dialog; endpoints detected after reboot |

## Additional problems found while retesting

- SourceForge may return HTML instead of the installer. The downloader follows the official file link once, verifies its host/path, validates executable/package magic and preserves an existing installer when a response is invalid.
- HeSuVi's `/S` does not remove its confirmation dialog. Installation now gives explicit confirmation/extraction instructions.
- ReaPlugs can show an installation-complete dialog even with `/S`; guidance tells the user to acknowledge it.
- Equalizer APO files alone do not prove endpoint installation. Verification inspects the virtual playback endpoint's registered APO DLL. Installation opens current `DeviceSelector.exe` or legacy `Configurator.exe` when registration is missing. This follows the endpoint-registration model in [Equalizer APO's developer documentation](https://sourceforge.net/p/equalizerapo/wiki/Developer%20documentation/).
- Restart requirements persist until Windows boot time changes; read-only preflight does not remove the marker.
- A pre-existing HeSuVi directory can contain only HRIR files. The legacy helper now checks its actual configuration files and preserves existing assets on retry.
- Installation writes transcripts and stage reports; dependency download output and failures are retained separately.
- Equalizer APO 1.4.2's Device Selector failed with a Qt platform-plugin error when launched from the application folder. Launching it from Equalizer APO's own folder resolved the error; its own checks then passed on both SonicScout playback endpoints.
- HeSuVi's installer launches its GUI after extraction. Installation now waits for extraction itself and verifies its files rather than waiting for all GUI/browser descendants to close.
- GUI installation no longer has an eight-minute automatic timeout that could interrupt a driver installer or expire while a first-time user reads vendor dialogs.
- A cancelled installation still appended green post-install instructions and said "Setup finished." The wizard now keeps its failure summary, hides those instructions, disables post-install verification, preserves choices, and offers retry.
- Status text was clipped horizontally. Checklist items now stretch within the available width and wrap their text.
- The elevation helper waited for vendor GUI descendants even after the worker completed. It now waits for the worker itself and propagates its exit code. A live guest fixture returned 23 while its Notepad child remained open.
- Generic exit codes hid the next action. The wizard now displays the current installation report's incomplete/error/blocked items, including declined administrator permission and required restart.

## Evidence

`regressions.txt`: isolated Windows PowerShell 5.1 checks for read-only preflight, unbound APO failure, reboot gating, configuration failure, safe helper imports, elevation options/exit and invalid-download preservation.

`publish.txt`, `publish-failure.txt`, `source-entrypoint.txt`, `launcher.txt`: actual packaging and batch executions, with injected failures explicitly labeled.

`download-reaplugs.txt`, `download-hesuvi.txt`, `download-equalizer.txt`: actual vendor downloads into an isolated QA folder; these files were not run on the host.

`wizard/blocked-result.txt`, `wizard/blocked-install.png`: focused wizard test with an injected blocked result. `vbcable-success.png`: actual guest vendor success dialog.

Persistent QA data: `C:\Users\brand\Documents\SonicScout-QA-2026-10-05`. VM: `SonicScout-Install-QA-20261005`. Its `Before-installation-fixes` snapshot preserves the original partial installation. Disposable credentials are excluded from report artifacts.

## Final live verification

The repeat used the existing disposable Windows x64 VM after uninstalling Equalizer APO, VB-Cable and the desktop runtime, and preserving old library/plugins/user data in a dated guest folder. The baseline contained only the active physical Speakers endpoint; Equalizer APO, ReaPlugs, SonicScout VSTs, LEQ companion and both system .NET runtime folders were absent. This is a clean dependency baseline on an existing Windows installation, not a second brand-new OS installation.

| Check | Actual result | Evidence |
|---|---|---|
| Clean baseline | Required dependencies absent; preflight exit 2 | `clean-baseline.txt`, `clean-baseline-preflight-exit.txt`, `dependency-reset-complete.txt` |
| Self-contained application | Starts while system .NET Core and Windows Desktop runtimes are absent | `clean-app-after-install.png`, `clean-install-success.txt` |
| Declined Windows permission | BLOCKED administrator-access row; no READY/DONE or post-install steps; verification disabled; choices retained for retry | `wizard-cancel-final.png`, guest reports |
| VB-Cable installation | Vendor reported successful installation; both playback endpoints present | Guest installation report |
| Equalizer APO attachment | Both cable playback endpoints passed vendor pre-mix and post-mix checks | `clean-selector-verified.png` |
| ReaPlugs and HeSuVi | Real downloads, confirmations, extraction and installed-file verification passed | Guest report/transcripts and download logs |
| Bundled assets | Library, JSFX, VST, HRIR, LEQ companion and managed config verified | Guest report/transcripts |
| Restart required | Install exit 2; wizard displays explicit restart/retry instructions and keeps verification disabled | `wizard-restart-final.png` |
| Elevation wait fix | Real helper returned worker exit 23 while its GUI descendant stayed open | `elevation-live-result.txt`; guest-only fixture scripts |
| Post-boot completion | Install-SonicScout.bat exit 0; restart marker removed; app loaded its private runtime | `clean-install-success.txt` |
| SonicPass binary startup | `--help` exit 0 with system runtime absent; no audio stream started | `sonicpass-help.txt`, `sonicpass-help-exit.txt` |
| Read-only preflight | Exit 0; config/library/VST/HRIR hashes and timestamps plus log inventory unchanged | `preflight-clean-readonly-result.txt` |
| Build and regression checks | Build: 0 warnings/0 errors; 8 script regressions; 5 wizard assertions; final package publish succeeds | `build-final.txt`, `regressions-final.txt`, `wizard-retry-test.txt`, `publish-final.txt` |

The full dependency installation exposed the elevation descendant-wait bug; the worker completed correctly but its parent waited for HeSuVi to close. After fixing it, the actual helper was tested with a deliberately open child window, and the revised real installer was exercised through pending-restart retry and post-boot completion. Earlier failed/partial screenshots and reports are retained as historical evidence.

The cold snapshot `Installation-verified-round1-20261006` (UUID `a0c6bcb1-4ac2-4b0a-ab7e-fb1502908230`) preserves the verified installation before round two. `Recovery-install-verified-20261006` also remains available.

Final tested package: `C:\Users\brand\Documents\SonicScout-QA-2026-10-05\clean-published`. Guest copy: `C:\QA\clean-published`. Full before/after guest logs are preserved in the corresponding ZIP archives and extracted evidence directories. Disposable credentials are excluded.

## Scope and next round

No installation blocker remains in the tested standard Windows x64 package route. This does not establish that every supported hardware/mixer combination works. Optional Hi-Fi Cable, Wave Link, Voicemeeter, Sound Blaster, ARM64/non-Windows paths and the complete interactive legacy-menu path were not fully exercised. The original findings were checked using actual package/VM runs where possible and controlled failures where appropriate, as identified above.

Round two should test profile onboarding, routing selection, SonicPass streaming, actual audible APO effects, Windows LEQ, restart persistence of user settings and fallback behavior. The empty profile list and disconnected tuning indicator at application launch are not functional-test passes. No profile, game routing or listening test has been performed in this round.

On October 6, VirtualBox became unresponsive after a long idle period. Its live snapshot failed with `VERR_VM_UNEXPECTED_UNSTABLE_STATE`; power-off also failed because the internal snapshot state was inconsistent. The identified QA VM process was stopped and restarted using its existing disk. Diagnostic logs were preserved. This is a test-environment interruption, not evidence of a SonicScout installation failure.
