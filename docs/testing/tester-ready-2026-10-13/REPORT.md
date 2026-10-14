# Tester qualification — completed 2026-10-14

Status: **READY FOR TESTERS — Windows x64 direct route.** Clean EXE installation, automatic component/APO setup, restart recovery, profile activation, saved controls and audio delivery passed. Real-hardware latency and subjective listening quality remain the owner's test, as explicitly agreed. This is an unsigned tester build, not a production certification or a qualification of every mixer/hardware combination.

Qualified EXE: `tester-installer\SonicScout-Setup.exe`, retained in the local QA directory below. Size: **128,049,132 bytes**. SHA256: **C489DF9A346C66B65FD7A354B962F262BEA975839E679B7F9254D6CCC4362B61**. Application source: commit `77baf2e`. Final installed DLL matches the published payload: **9AF462DED90D20A3A9DB6E62576F1AC792ECB5D70C97BE6B895DB49037FA5620**.

Testers should follow [TESTER-GUIDE.md](TESTER-GUIDE.md) and use the supplied EXE. No terminal, Git, SDK or separate .NET runtime is needed.

Testing takes place in the disposable Windows x64 VirtualBox VM `SonicScout-E2E-QA-20261013`. Host audio has not been changed. Earlier reference and QA VMs are saved, preserving their data. Full screenshots, installer artifacts and logs are retained locally in `C:\Users\brand\Documents\SonicScout-Tester-Ready-2026-10-13`.

## Findings and fixes verified during development

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

## Routing and control fixes

Device list refresh must not change a running route's status to READY. User changes to route, gain and buffer now restart the running engine so they take effect. Exit notifications from a replaced process are ignored. Playback format initialization is recorded as informational diagnostics instead of an error.

These fixes are included in the qualified EXE and were checked during the packaged and clean-install tests below. Third-party mixer compatibility has not been qualified by this direct-route test.

## Packaged application follow-up

The rebuilt EXE (SHA256 `67734E80EBE77EFFB097B1F3287EB65A7193C42DC0CB2DE0EB82DDF8C9F42B31`) installed successfully. Its installed application DLL hash matched the published payload. The active measured game-target profile survived upgrade and normal reopening, and SonicPass started automatically without the setup wizard. Selecting 50 ms in the GUI restarted the engine; its logs confirm buffer=50ms and running playback. Format initialization now has INFO severity.

Diagnostics opened and created a local support ZIP containing installation reports and routing configuration. Nothing was sent. An injected failure immediately after cable APO mutation exercised automatic rollback: all captured render registry values (including physical endpoints) and the root configuration were unchanged afterward, and Windows Audio was running. GUI uninstall removed the executable, shortcut and Installed Apps entry while preserving the profile and shared APO configuration. See `rollback-result.json` and `qualified-uninstall-result.json`.

Reopening revealed that boost/buffer choices were not persisted. Those controls now save and restore valid dropdown values. The qualified EXE includes that fix.

## Final EXE end-to-end result

The application, APO configuration, ReaPlugs and routing preferences were absent before this run; see `final-clean-baseline.json`. Previous files and logs were archived, not discarded. The final EXE was installed directly and no application or setup files were patched inside the guest.

| Check | Result | Evidence |
| --- | --- | --- |
| EXE welcome, notices, destination, installation and launch | PASS | Local `final-clean-*.png`; installed DLL hash above |
| VB-Cable, Equalizer APO, ReaPlugs and HeSuVi | PASS; all installed automatically without vendor choices or configuration dialogs | `final-fresh-before-reboot.json` |
| Cable LFX/GFX registration, private HeSuVi/device whitelist, managed assets and loudness chain | PASS; virtual cables are device scoped, physical output remains unchanged | Installation reports; local root config and spatial screenshots |
| Driver restart and setup completion through the app | PASS; pending restart is reported, post-reboot final verification is READY | `final-after-reboot-ready.json`; `final-after-reboot-result.png` |
| Running engine and volume verification | PASS; automatic checks; Spatial Sound confirmed Off in Windows properties for both devices | `final-verify-settings.png`, `final-physical-spatial-off.png`, `final-cable-spatial-off.png` |
| Live buffer/input/output controls | PASS; process arguments use 50 ms, -3 dB input and -6 dB output | `final-live-controls.json` |
| Reopen with saved controls | PASS; selections restored and automatic routing starts without the setup wizard | `final-reopened-controls.json`; `final-control-persistence.png` |
| Measured game-target profile | PASS; GUI generated and activated 1Custom SA03 / Black Ops 7 V3, with a real GraphicEQ correction in the active file | `final-active-profile.txt`; `final-v3-profile.png` |
| Offline reopening and profile persistence | PASS with the VM network disconnected; profile hash unchanged and route running. Network restored afterward | `final-offline-route.json`; `final-offline-reopen.png` |
| Physical-output audio delivery | PASS; 857,164 samples, RMS 0.0035871188, peak 0.0194933228 | `route-probe-final-running.txt` |
| Stop/start | PASS; stopped route has zero physical samples/RMS; restarted route delivers 934,332 samples, RMS 0.0041004334 | `route-probe-final-stopped.txt`, `route-probe-final-restarted.txt` |
| Diagnostics without administrator privileges | PASS in the final build; local support ZIP includes setup reports and routing state; nothing sent | `final-diagnostics-window.png`; local `final-support.zip` |
| Injected-failure recovery and uninstall | PASS in the preceding packaged build; these paths were unchanged in the final build | `rollback-result.json`, `qualified-uninstall-result.json` |

Full screenshot and raw-log evidence stays in the local QA directory. Selected compact evidence is committed beside this report. Disposable credentials and the full support ZIP are excluded from the repository.

The reference, earlier QA and final test VMs are saved with their files and logs preserved. The final VM retains the working V3 profile and the control selections exercised by the persistence test. The distributed installer starts new users with 0 dB boosts and a 20 ms buffer; it does not include VM user settings.

## Scope and remaining user actions

The tested VM reports Windows x64 build 26300, Windows PowerShell 5.1, VirtualBox 7.2.20 and physical HD Audio output at 44.1 kHz. Cable capture is 48 kHz; conversion to the physical native format delivered audio successfully. VM timing and sample counts do not establish real hardware latency or subjective sound quality.

Testers still choose their physical output and headphone model, confirm Windows Spatial Sound is Off, and select the app's virtual input in their game's audio settings. Windows permissions and a requested driver reboot require user action. If SonicPass stops, the game must be switched back to physical output to restore ordinary audio; Windows' default device is unchanged. Saved tunes work offline, while new catalog/target calculations require internet access.

Windows 10, alternate physical devices, third-party mixers, 7.1 game content and real game listening were not separately qualified in this VM run. They are tester coverage, not passes claimed by this report. The owner will test hardware latency and sound quality before deciding on wider release.
