# SonicPass stereo transport correction

October 12, 2026. Candidate transport repair; not a tester release or a completed installation/setup repair.

## Changes

SonicPass now requires the virtual cable's processed stereo recording endpoint. A legacy cable playback ID supplied by the app is paired to the recording endpoint through the shared parent device-instance path in its connected topology device ID. Render/capture filter suffixes differ and are excluded from that comparison. Missing, inactive, ambiguous or non-cable inputs fail instead of silently selecting another route. No render-loopback fallback remains in the relay. Games continue to select the cable playback endpoint.

The grouped-average multichannel adapter was removed. Processed stereo L/R retain unity gain and placement in the physical output's front pair; additional physical channels are silent. Multichannel input is rejected rather than incorrectly downmixed. Native output-format conversion remains intact, including bit depth and descriptor details.

Default render buffering is 20 ms in the CLI and GUI (previously 100 ms). Capture FIFO data is cleared before adding a new packet when queued duration exceeds max(2 × selected buffer, 40 ms). This drops stale audio instead of preserving accumulated delay. It is not adaptive clock-drift correction, and does not measure total latency or remove all downstream converter buffering.

Startup requires capture packets. Device-resolution failures return an error code with an actionable message. The GUI's manual start reports STARTING until engine confirmation, and preserves the startup error in its failure message. Provisioning text now describes selecting an existing virtual route instead of falsely claiming to clone a physical device.

## Validation

Full WPF app and relay Release builds: passed, zero warnings/errors. Regression project compiles the actual relay source. Its impulse tests pass for stereo left/right into 2-, 8- and 16-channel outputs at nonzero buffer offsets, verify silent extra channels and unchanged surrounding samples, reject multichannel input, and check the 20 ms default. Invalid endpoint CLI invocation returns exit code 1 without an unhandled exception.

Run reproducible checks with `dotnet run --project docs/testing/sonicpass-fixes-2026-10-12/Regression.csproj -c Release`. The optional `--vm` harness targets disposable endpoints in the existing ArtTuneKit reference VM, not arbitrary user hardware. It verifies real legacy-render pairing and measures speaker loopback while the actual SonicPass engine transports a quiet test signal. Repeated guest-session start failures prevented a graceful guest reboot; the diagnostic VirtualBox log was preserved before a reference-VM reset.

Live VM test: passed after correcting the pairing comparison. The first comparison incorrectly used the entire connected topology ID; the driver exposes distinct out/in topology filter suffixes. Shared container IDs were also unusable on this driver. The final code compares the parent device-instance portion, with regression checks that distinguish different cable instances and reject malformed identities. The real 16ch render ID resolved to Art Tune Unified Output (Capture).

ArtTuneKit and its relay were stopped in the guest before measuring SonicPass alone. The actual SonicPass engine captured 48 kHz stereo float and rendered the physical-emulated output's native 44.1 kHz stereo float format. A 10-second quiet two-frequency test produced speaker-loopback peak `0.3238546550273895`, 4,485,936 loopback bytes and 163 capture packets; LastError was empty and the harness printed its final signal-passage PASS. Evidence is in vm-result.txt and vm-initialization.txt. The guest PowerShell wrapper did not preserve a usable numeric exit code; validation relies on the completed assertion output rather than claiming an exit-code result.

The VM needed 149 queue trims/drops and retained 50 ms in the FIFO at stop. This is evidence that the virtualized timing is unstable and that stale-queue trimming runs, not a smooth-playback or latency pass. This test uses the installed reference processing chain; it does not validate SonicScout's unfinished tune activation. The WPF app was compiled but its status changes have not been separately exercised through the GUI in this run.

## Remaining acceptance work

The processing/game-profile chain, APO device-scoping repair, fully automated APO setup, GC7 direct-hardware route, Voicemeeter fallback coverage, device-loss recovery, adaptive drift correction and professional EXE installation are separate unfinished work. Do not present signal passage as tune correctness, channel-isolation measurement on hardware, or latency/quality acceptance. A physical GC7 comparison against direct game audio is still required.
