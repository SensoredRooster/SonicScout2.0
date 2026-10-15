# SonicScout Windows app

Source builds require the .NET 8 SDK. Run `publish_sonic_scout.bat` to create a self-contained Windows x64 package on your Desktop, or specify a destination:

```powershell
.\publish_sonic_scout.ps1 -OutputPath C:\Exports\SonicScout
```

Existing output is kept if publishing fails, and kept as a dated backup after it succeeds. The package includes SonicScout, SonicPass, the LEQ companion, installer scripts, the tune library, plugins and Default HRIR files. Destination PCs do not need .NET installed separately. The tester EXE is built from this package with `tools/packaging/build_installer.ps1` (NSIS).

## Tester flow (build11)

1. `SonicScout-Setup.exe` → **UAC prompt 1** (installer).
2. Setup window: choose the output, tick authorisation, **Run install setup** → **UAC prompt 2** (`setup_audio_stack.ps1`: VB-CABLE, ReaPlugs, Equalizer APO, routing). Equalizer APO is verified by `DeviceSelector.exe` (E-APO 1.4.2) or `Configurator.exe` (older).
3. Restart when asked. `Register-SonicScoutResumeAfterRestart` writes `HKCU\...\RunOnce\SonicScoutResumeSetup`, which relaunches `SonicScout.exe --resume-setup` at the next sign-in. The resume runs a read-only preflight (up to 180 s) without elevation. The main window starts at once, and the setup dialog stays open.
4. EQ changes are written without admin rights to `%LOCALAPPDATA%\SonicScout\eapo\sonicscout.txt`, which is included from `config.txt`. Saved profiles go in `%LOCALAPPDATA%\SonicScout\profiles`, and the active filter is in `Documents\HAudioApp\active_profile.txt`.
5. The status (`%LOCALAPPDATA%\SonicScout\logs\eq-status.json`) is honest: **NO AUDIO** until processed signal is measured, then **RUNNING**. The meter survives `0x8889xxxx` device errors with dispose and backoff.

`run_sonic_scout_csharp.bat` builds and launches from source using the SDK. Known risks: builds are unsigned until Azure Artifact Signing is set up, and the post-reboot resume must happen on the same Windows account that started setup.

Installation logs: `%LOCALAPPDATA%\SonicScout\logs`. Keep that folder when reporting a problem. The VM end-to-end harness is in `tests/E2EHarness`.