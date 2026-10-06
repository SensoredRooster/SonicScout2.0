# Installation fixes and verification

Updated October 6, 2026 (America/Chicago). Scope: installation only. The original [installation report](../installation-2026-10-05/REPORT.md) remains historical evidence.

Status: recovery installation verified in the VM, including post-reboot batch exit 0 and application startup. Live read-only preflight passed. A complete repeat from a baseline with dependencies absent is in progress.

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
| Runtime and installation instructions unclear | Distinguish SDK for source builds from self-contained releases; explain elevation, vendor prompts and reboot/retry | README review; runtime launch verification pending |
| Elevation loses path/options and returns early | Preserve absolute path, consent and choices; wait and propagate child exit | Mocked helper; real VM elevation and cancellation |
| Importing main installer executes menu | Dot-source helper imports return before main execution; isolate helper globals in a module | Regression import; actual VM asset configuration |
| BLOCKED wizard result says READY/DONE | Count BLOCKED as a problem; offer review/retry; stop downstream work when installation fails | Real wizard with injected blocked result, two assertions and screenshot |
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

## Evidence

`regressions.txt`: isolated Windows PowerShell 5.1 checks for read-only preflight, unbound APO failure, reboot gating, configuration failure, safe helper imports, elevation options/exit and invalid-download preservation.

`publish.txt`, `publish-failure.txt`, `source-entrypoint.txt`, `launcher.txt`: actual packaging and batch executions, with injected failures explicitly labeled.

`download-reaplugs.txt`, `download-hesuvi.txt`, `download-equalizer.txt`: actual vendor downloads into an isolated QA folder; these files were not run on the host.

`wizard/blocked-result.txt`, `wizard/blocked-install.png`: focused wizard test with an injected blocked result. `vbcable-success.png`: actual guest vendor success dialog.

Persistent QA data: `C:\Users\brand\Documents\SonicScout-QA-2026-10-05`. VM: `SonicScout-Install-QA-20261005`. Its `Before-installation-fixes` snapshot preserves the original partial installation. Disposable credentials are excluded from report artifacts.

## Remaining verification

Repeat installation from a baseline with the tested dependencies and system .NET runtime absent, verify the live wizard's failure/retry flow, and confirm SonicPass startup. Recovery installation and its post-reboot retry already passed. The application loaded `hostfxr.dll` and `coreclr.dll` from `C:\QA\fixed-published`, and live unprivileged preflight preserved installed file hashes/timestamps and logs. Profile setup, routing performance and listening tests remain round two.

On October 6, VirtualBox became unresponsive after a long idle period. Its live snapshot failed with `VERR_VM_UNEXPECTED_UNSTABLE_STATE`; power-off also failed because the internal snapshot state was inconsistent. The identified QA VM process was stopped and restarted using its existing disk. Diagnostic logs were preserved. This is a test-environment interruption, not evidence of a SonicScout installation failure.
