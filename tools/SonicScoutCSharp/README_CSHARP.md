# Sonic Scout C# Edition

This folder now contains a native Windows WPF version of the Sonic Scout profile manager.

## Start the app

For development, double-click `run_sonic_scout_csharp.bat`.

For a published Sonic Scout folder on another PC, run `Install-SonicScout.bat`. It performs audio setup first, downloads only required dependencies, and launches Sonic Scout after a successful setup.

The launcher builds the app automatically the first time, then starts:

```text
bin\Release\net8.0-windows\SonicScout.exe
```

A .NET 8 SDK is required to build from source. The published folder can run without the SDK when the .NET 8 desktop runtime is installed.

## What it does

- Selects and activates the available EQ profiles in `profiles\`.
- Copies the selected profile to `%USERPROFILE%\Documents\HAudioApp\active_profile.txt`.
- Equalizer APO can include that active file from its `config.txt`.
- Displays chain status and reports write errors in the app.
- Includes the Copper Signal default theme plus Singularity Camo, Dark Matter, Borealis, Abyss, Apocalypse, Brutalist, Instrument, and Psychotic theme choices.
- Provides seven live Equalizer APO controls: 60 Hz, 150 Hz, 400 Hz, 1 kHz, 2.5 kHz, 6 kHz, and 12 kHz.
- Includes Clip Guard, which cycles through output caps of 20%, 40%, 60%, and 80% before returning to off.

## Bridge architecture (UI <-> script engine)

The project now includes a dedicated bridge layer in [Bridge/](</c:/Users/brand/OneDrive/Documents/ItsHapa's Project/CSharp/Bridge>) for isolating the UI from script execution:

- [IScriptEngineBridge](</c:/Users/brand/OneDrive/Documents/ItsHapa's Project/CSharp/Bridge/IScriptEngineBridge.cs>): async contract for script discovery, queueing, completion, cancellation, and event streaming.
- [IScoutAudioController](</c:/Users/brand/OneDrive/Documents/ItsHapa's Project/CSharp/Bridge/IScoutAudioController.cs>): audio pipeline contract for hot reload and bypass fallback.
- [ScriptOrchestrator](</c:/Users/brand/OneDrive/Documents/ItsHapa's Project/CSharp/Bridge/ScriptOrchestrator.cs>): process orchestrator that writes JSON payload contracts, runs scripts off the UI thread, forwards logs/state events, and triggers audio hot reload or bypass on completion.
- [QueuedScoutAudioController](</c:/Users/brand/OneDrive/Documents/ItsHapa's Project/CSharp/Bridge/QueuedScoutAudioController.cs>): single-queue hardware mutation controller to avoid race conditions in WASAPI/NAudio re-init paths.

Script payloads are serialized to `%LOCALAPPDATA%\SonicScout\bridge\requests\` and exposed to workers through:

- `SONICSCOUT_EXECUTION_ID`
- `SONICSCOUT_PAYLOAD_PATH`

`SETUP` now invokes `setup_audio_stack.ps1` through the bridge:

- Runs `-Mode Install -Quiet` when the app is elevated.
- Runs `-Mode Preflight -Quiet` when not elevated, then continues UI checks and reports that admin relaunch is required for dependency installs.
- On script failure, bridge fallback forces safe physical-output bypass and reports status in setup checks.
- Script prompts are disabled for app-driven runs (`-NonInteractive`); ownership and routing choices come from the setup UI checkboxes/toggles.

Startup is now gated for turnkey install/setup:

- On launch, Sonic Scout runs a non-interactive preflight check before showing the main UI.
- If install/setup is incomplete, it opens the Setup wizard first.
- The main window is shown only after setup is verified complete.

## Setup wizard routing flow

- `SETUP` now runs an installation-style routing wizard.
- The wizard discovers active output endpoints and asks you to select your default physical output.
- The wizard requires explicit ownership/apply confirmations before it can write routing configuration.
- The wizard includes Sonic Scout routing profiles (`Sonic Scout Direct Route` and `Sonic Scout Compatibility Route`).
- It saves compatibility flags for Voicemeeter, Elgato Wave Link, Creative Sound Blaster, or similar mixers.
- It provisions the `Sonic Scout` virtual route when a compatible Hi-Fi/virtual cable endpoint is present.
- If no compatible tuned-channel route exists, setup calls out Voicemeeter / VB-Cable prerequisites so the tuned channel can still be created.
- If no compatible virtual cable endpoint is available, routing safely falls back to the selected physical output.

## Guided dependency installer order (tester flow)

Use `run_audio_stack_setup.bat` to run the staged install flow with consent prompts and verification logs.

## Sonic Scout SonicPass

`SonicPass\SonicScout.SonicPass.csproj` builds the Sonic Scout user-mode audio pass. It captures audio from the selected virtual endpoint (either a dedicated capture/recording endpoint or a render loopback) and sends it directly to the selected physical output, so Voicemeeter is not required.

Build or run it with:

```text
CSharp\run_scoutpass.bat
```

SonicPass still needs a virtual audio driver such as VB-Cable because a normal WPF application cannot create a Windows audio endpoint by itself. Use the `SCOUTPASS` panel in the main window after running `SETUP`; it selects the virtual input and physical output, applies input/output boost, sets the buffer, and starts or stops the pass. EQ processing and device-loss recovery remain separate follow-up layers.

### Lifecycle

- Sonic Scout automatically starts SonicPass once a valid saved route exists, right after startup finishes refreshing device state.
- The title bar provides setup, SonicPass, theme, minimize, maximize, and close controls. Closing the main window performs a real shutdown: it stops the audio monitor and any running SonicPass process before the app exits. It no longer minimizes to tray on close.
- When Windows LEQ is enabled, Sonic Scout starts or adopts the authenticated Art Relay process for the tuned audio path; disabling it stops a relay process Sonic Scout owns.
- Equalizer APO is a system-wide audio filter, not a process Sonic Scout starts or stops; only SonicPass is owned and managed by the app's lifecycle.

### SonicPass install order

1. Equalizer APO
2. VB-Cable base route (if no tuned virtual route is detected)
3. Hi-Fi Cable route (if missing)
4. Voicemeeter fallback (optional, prompted when tuned route is still missing)
5. Final verification and fallback safety checks

### SonicPass assets and logs

Place installer files in `CSharp\installers\` before running the setup script.

Logs are written to:

```text
%LOCALAPPDATA%\SonicScout\logs\
```

including JSON run reports and a rolling history file.

The setup verifier checks the actual Equalizer APO configuration/runtime files,
active Windows audio endpoints, installer exit codes, and the Windows Audio
service. A generic virtual cable endpoint is sufficient for the safe fallback
route; a dedicated Hi-Fi Cable endpoint is reported as an optional quality
upgrade rather than treated as a failed installation.

## Equalizer APO setup

Add this line once to Equalizer APO's configuration file, using the exact path shown below:

```text
Include: C:\Users\<your-user>\Documents\HAudioApp\active_profile.txt
```

Select a profile in Sonic Scout after changing the active profile. No administrator access is required because the active file lives in Documents.

## Build a distributable folder

```powershell
dotnet publish CSharp\SonicScout.CSharp.csproj --configuration Release --runtime win-x64 --self-contained false --output "$env:USERPROFILE\Desktop\SonicScout"

Copy-Item profiles\*.txt "$env:USERPROFILE\Desktop\SonicScout\profiles" -Force
```

Copy the complete `%USERPROFILE%\Desktop\SonicScout` folder to another Windows machine with the .NET 8 Desktop Runtime installed.
