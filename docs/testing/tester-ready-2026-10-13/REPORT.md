# Tester qualification — 2026-10-13

Status: IN PROGRESS. No installer in this directory is approved for tester distribution yet.

Testing takes place in the disposable Windows x64 VirtualBox VM `SonicScout-E2E-QA-20261013`. Host audio has not been changed. Earlier reference and QA VMs are saved, preserving their data. Full screenshots, installer artifacts and logs are retained locally in `C:\Users\brand\Documents\SonicScout-Tester-Ready-2026-10-13`.

## Verified this round

- Clean baseline: application, Equalizer APO configuration and ReaPlugs absent; physical Windows audio endpoints present. Prior installation data was moved into the VM's QA archive before resetting.
- EXE installation and launching the graphical setup passed.
- VB cable installation and Equalizer APO installer handoff ran automatically.
- ReaPlugs extraction succeeded, but Windows PowerShell 5.1 originally reported a missing process exit code as a failure. Waiting with `Start-Process -Wait -PassThru` fixes this; the VM retry reports FIXED.
- HeSuVi's original archive does not contain its generated `conv.txt`. Setup now runs its command-line initializer, creates SonicScout's private configuration and binds it to the owned cable endpoints. The VM retry reports FIXED without vendor configuration dialogs.
- Automatic LFX/GFX registration, installed assets and final installation verification report READY after the corrected scripts were deployed into the test installation.
- Setup starts SonicPass before opening verification; the running route and physical output volume are checked automatically.
- A quiet 1,234 Hz test tone routed through the virtual cable reaches the physical output: 996,072 captured samples, RMS 0.0090779195, peak 0.0551932417. This confirms audio delivery, not subjective sound quality or hardware latency.
- The GUI generated and activated `1Custom SA03 · Black Ops 7 (V0)` using AutoEq's measured-headphone solver and the bundled custom game target.
- Application build: zero warnings/errors. Installation regressions pass, including read-only preflight, both cable APO bindings, reboot tracking, failure handling and invalid-download preservation.

## Corrections awaiting final package verification

Device list refresh must not change a running route's status to READY. User changes to route, gain and buffer now restart the running engine so they take effect. Exit notifications from a replaced process are ignored. Playback format initialization is recorded as informational diagnostics instead of an error.

The final EXE must still be installed and checked without test-script patches. Remaining qualification includes reopen/persistence, live control changes, local diagnostics, rollback, uninstall and a final clean installation. Real-hardware latency and subjective game sound quality are reserved for the owner, as requested. Third-party mixer compatibility has not been qualified by this direct-route test.

No `ready for testers` claim is supported until those remaining checks complete.
