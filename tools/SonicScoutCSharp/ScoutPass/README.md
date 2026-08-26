# Sonic Scout SonicPass

`SonicScout.SonicPass.exe` is the Sonic Scout user-mode audio pass. It removes the need for Voicemeeter as a mixer by moving audio directly from a virtual render endpoint to a physical render endpoint.

```text
Application or game
    -> virtual audio render endpoint
    -> SonicScout.SonicPass.exe
    -> selected physical output
```

SonicPass still requires a virtual audio driver. The current setup can use VB-Cable or another compatible virtual endpoint. SonicPass itself does not create a Windows audio device; creating one requires a separate signed virtual audio driver.

## Run

From the `CSharp` folder, run:

```text
run_scoutpass.bat
```

SonicPass automatically selects the first active endpoint matching `Sonic Scout`, `VB-Audio`, `VB-Cable`, `Virtual Cable`, `CABLE Input`, or `Hi-Fi Cable` as its virtual input. It renders to the Windows default multimedia output.

For explicit device selection:

```powershell
.\SonicPass\bin\Release\net8.0-windows\SonicScout.SonicPass.exe `
  --input-name "VB-Audio Virtual Cable" `
  --output-name "Speakers" `
  --buffer-ms 100
```

Device IDs are more stable than names:

```text
--input-id <Windows endpoint ID>
--output-id <Windows endpoint ID>
```

## Current scope

- Shared-mode WASAPI capture and render
- Supports both a dedicated capture/recording endpoint and a render-loopback endpoint as input
- Physical output selection
- Bounded jitter buffer with silence-padded reads (no premature stream termination on brief gaps)
- Packet count and buffer-drop telemetry (drops only occur when the jitter buffer is genuinely full)
- Graceful Ctrl+C shutdown
- No Voicemeeter dependency

The current pass includes transport and input/output gain. EQ, limiter, channel mapping, device-loss recovery, and named-pipe control remain follow-up layers. The WPF app remains separate so a UI failure cannot directly run inside the audio callback.

### Startup ordering (important)

Capture must start and buffer at least one packet before playback starts. NAudio's `WasapiOut` treats an empty first read as end-of-stream and will silently exit its render thread without ever starting the underlying audio engine, while still reporting `PlaybackState = Playing`. `SonicPassEngine.Start()` starts capture first, waits briefly for real audio data, and only then starts playback, avoiding this failure mode.

### Buffer sizing

The jitter buffer uses `ReadFully = true`, so a brief gap plays silence instead of ending the stream. Use a `--buffer-ms` of at least 150-250 when the source is a shared virtual-cable endpoint, since smaller buffers can still produce occasional buffer drops under normal jitter.
