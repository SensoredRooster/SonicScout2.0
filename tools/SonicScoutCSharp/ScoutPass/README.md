# Sonic Scout SonicPass

SonicScout.SonicPass.exe transports the virtual cable's processed stereo recording output to the selected physical playback device.

Game -> cable playback endpoint -> APO processing -> cable stereo recording endpoint -> SonicPass -> physical output.

Games still select the cable's playback endpoint. The existing playback ID stored by SonicScout is paired to its recording output through the shared device-topology adapter identity. Missing or ambiguous matches fail with an actionable error. The relay requires stereo capture; it does not fall back to multichannel render loopback or averaging.

## Development commands

Build with `dotnet build SonicScout.ScoutPass.csproj -c Release`. The resulting executable is named SonicScout.SonicPass.exe.

CLI options:

- `--input-id`: processed recording endpoint ID, or a legacy cable playback ID to pair automatically.
- `--input-name`: recording endpoint name fragment. More than one matching cable requires an explicit ID.
- `--output-id` / `--output-name`: physical playback device; default is Windows multimedia output. Virtual cables and outputs with fewer than two channels are rejected.
- `--buffer-ms`: 20–500 ms, default 20.
- `--input-gain-db` / `--output-gain-db`: -12 to +12 dB.

## Transport behavior

The relay preserves stereo left/right at unity gain, leaving extra physical-output channels silent. It resamples to the output rate and converts to the output's complete native format descriptor. It waits for capture packets before starting playback and reports an error if none arrive.

Silence-padded reads prevent brief gaps from ending playback. When queued capture audio exceeds max(2 × selected buffer, 40 ms), SonicPass clears stale queued data before adding the next packet. This limits accumulated queue delay by discarding audio; it is not adaptive clock-drift correction or a measured latency guarantee.

The relay does not implement the game tune or spatial processing. These must run on the cable's playback endpoint before stereo capture. Adaptive drift correction, device-loss recovery, profile/setup integration and real-hardware latency/quality acceptance remain follow-up work.

The UI reports STARTING until the engine confirms startup. See docs/testing/sonicpass-fixes-2026-10-12 for regression checks and validation limits.
