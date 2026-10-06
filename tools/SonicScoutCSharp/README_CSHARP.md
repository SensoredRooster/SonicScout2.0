# SonicScout Windows app

Source builds require the .NET 8 SDK. Run `publish_sonic_scout.bat` to create a self-contained Windows x64 package on your Desktop, or specify a destination:

```powershell
.\publish_sonic_scout.ps1 -OutputPath C:\Exports\SonicScout
```

Existing output is preserved on failure and kept as a dated backup after successful publishing. The package includes SonicScout, SonicPass, the LEQ companion, installer scripts, the tune library, plugins and Default HRIR files. Destination PCs do not need .NET installed separately.

Extract the complete package, then run `Install-SonicScout.bat`. Accept administrator elevation and confirm installation. Complete vendor dialogs; choose both SonicScout2.0 playback entries in Equalizer APO Device Selector when the + entry is listed (CABLE Input / CABLE In 16ch before renaming). If a restart is required, reboot and run the same batch again. The app starts after verification passes. Missing audio components require internet access; failed downloads remain incomplete and can be retried.

For source development, `run_sonic_scout_csharp.bat` builds and launches using the SDK. First-run checks are read-only. Use the installation wizard to install components and review failures. The wizard's single authorisation checkbox covers the requested installation changes.

Installation logs: `%LOCALAPPDATA%\SonicScout\logs`. Preserve that folder when reporting a problem.
