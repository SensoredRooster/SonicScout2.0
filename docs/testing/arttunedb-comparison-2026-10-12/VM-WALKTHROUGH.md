# Original installation reference walkthrough

October 12, 2026. **VM reference walkthrough completed through installation, managed virtual-path setup, profile activation, restart persistence, backend inspection and signal-passage measurement. Real hardware quality, channel isolation and end-to-end latency remain unverified.**

## Environment and preserved evidence

A separate VirtualBox VM, `ArtTuneDB-Reference-QA-20261012`, was cloned from the cold `Installation-verified-round1-20261006` snapshot of the SonicScout QA VM. The original VM and its snapshots were preserved. The clone runs Windows 11 Enterprise Evaluation x64 with a disposable local account. Its inherited guest computer name is SONICSCOUT-QA.

The guest baseline reset returned exit code 0. Its transcript records Equalizer APO and VB-Cable uninstall exit codes of 0, and preserves the previous configuration, plugins and app data under `C:\QA\previous-install-20261012-134834`. After reboot, the EqualizerAPO directory was absent and only the generic speakers and microphone endpoints were enumerated. Later installer detection found a residual driver-store package, so this is not a never-installed Windows baseline.

Raw logs, screenshots and the reference installer are kept locally at `C:\Users\brand\Documents\ArtTuneDB-Reference-QA-2026-10-12`. The reset transcript was copied out of the guest as `dependency-reset.txt`. Credentials are excluded from repository reports.

The current free guided installer was retrieved from the [official installer endpoint](https://artiswar.io/tools/ArtTuneGuided). Authenticode validation returned Valid. SHA256: `48F5D9D82ACF79683D59A498FA87EEA6DD82C7BD340571E54024B249133726C3`. It has been copied into the guest but has not been run.

## Product identity and architectural evidence

The local ArtTuneDB source contains the free installer and audio library, rather than the ArtTuneKit GUI application. The [ArtTuneDB README](https://github.com/ArtIsWar/ArtTuneDB) distinguishes its manual setup requirements from ArtTuneKit automation. The user supplied the ArtTuneKit 1.3.9 EXE and completed its licensed sign-in, resolving product access. This walkthrough exercises that GUI product rather than the free script.

The [official device guide](https://artiswar.io/devices) identifies the GC7 Speakers endpoint as the game route and Headset as the voice route, renamed Art Tune (Game) and Normal Audio (Voice). SonicScout instead introduced a virtual cable and SonicPass relay on the user's GC7 system. This is a material routing difference to investigate alongside the confirmed channel-mapping defect in REPORT.md. Documentation does not establish that this difference alone caused the reported distortion or latency.

The virtual machine has no physical GC7. It can establish installation screens, file/configuration changes and generic virtual audio routing. GC7-specific APO processing, audible quality and end-to-end latency require a later hardware test.

## Remaining walkthrough

1. Finish signal-path checks and document their limits; measure actual GC7 playback separately.
2. Turn verified differences into SonicScout repairs and acceptance checks before a tester release. Existing SonicScout audio quality remains a failed user test.

## ArtTuneKit 1.3.9 installation observed

The user supplied the local ArtTuneKit-Setup-1.3.9.exe download, resolving the product identity. A copy is preserved outside the repository in the QA reference-source folder. Authenticode returned Valid; SHA256 is `38586286365AF37ECED2E29B00592901B2F8F2757294FF6037CD71774D149BCD`.

After the baseline reboot, EqualizerAPO's installation directory was absent and PnP enumeration showed only the standard High Definition Audio speakers and microphone. The supplied EXE was run inside the reference VM.

Observed flow: install scope (all users recommended, selected), UAC with verified publisher ArtIsWar, LLC, license agreement, information page, destination `C:\Program Files\ArtTuneKit` (647.2 MB minimum), desktop shortcut and elevated Windows startup options (both selected by default), installation summary, extraction, Visual C++ x64 redistributable stage, successful completion, and checked Launch ArtTuneKit option. No user-facing command prompt was needed for this application installation.

First launch displayed a modal requiring sign-in with the purchase account or purchase. Audio setup could not be accessed at this stage. The user was asked to complete sign-in personally in the open reference VM; no credentials were requested in chat, and no license bypass or purchase was attempted. Application installation success does not establish audio stack setup success.

Screenshots preserved locally: `02-installer-information.png`, `03-destination.png`, `04-shortcuts-startup.png`, `05-install-complete.png`, and `06-license-signin-required.png`. VirtualBox capture initially failed while the guest display was asleep; a harmless Shift key woke it and restored capture. This was a QA display issue, not an ArtTuneKit installer failure.

## Signed-in setup and profile walkthrough

The user completed sign-in personally. The app reported a license transfer from the previous physical device and one active device at a time; the user was informed. No account tokens or credentials are included here.

The app presented a welcome video, tuning release notes and an incomplete-audio-setup prompt. A library update downloaded, checked integrity, extracted and loaded successfully. The setup wizard then showed Detect, Software, Configure and Complete stages, including separate progress for tools, download, E-APO, HeSuVi, ReaPlugs, VB Cable, LEQ and configuration.

Detection selected the ATK-managed relay path because no user router was detected. This is the VM's generic-device path, not the GC7-specific path. The visible log classified VB-Cable as absent, while noting driver-store residue (`oem5.inf`); therefore this clone is a dependency-removed baseline, not a pristine never-installed Windows image.

The wizard installed the audio chain and reported the relay reached Running. It explicitly skipped default-device assignment and instructed games to select Art Tune. No Equalizer APO selector window was observed during this walkthrough. At completion, a named-hardware verification prompt asked the user to disable physical-output loudness EQ, virtual surround, bass/room effects and spatial sound to avoid double processing. This check remains a manual reference step, not total automation. Its OK was acknowledged, but physical enhancement settings have not yet been independently inspected.

A BO7 Version 5, Classic+, Ultra Low test profile was created with the explicit Flat EQ fallback. That fallback describes skipping headphone correction/target while retaining spatial processing. The review showed 16 channels. The app offered a profile desktop shortcut and activation; both were exercised. The active dashboard showed Art Tune + at 16 channels/48 kHz, ATK Spatial Engine, E-APO OK, and a relay output of stereo/44.1 kHz/16-bit Speakers (High Definition Audio Device). These are UI observations, not measured processing correctness or latency.

Evidence screenshots: `07-setup-welcome.png`, `08-audio-chain-install.png`, `09-hardware-verification.png`, `10-profile-game-version.png`, `11-profile-review.png`, `12-profile-active.png`. Some profile/screens changed while the user was also interacting; the user agreed to leave the VM idle, and the recorded Flat EQ profile sequence was then performed independently.

VirtualBox guest-control calls subsequently timed out or failed starting sessions. A graceful reference-VM reboot was requested to recover file/log collection and check startup persistence. This integration failure must not be attributed to ArtTuneKit without evidence.

## Implications for SonicScout

The reference coordinates game version, channel requirement, active virtual endpoint, spatial engine and relay automatically, with distinct hardware-routing detection. SonicScout's known disconnected configuration paths and incorrect multichannel averaging need repair before packaging. The reference UI supports a coherent installation/setup flow; it does not validate SonicScout's audio quality, prove exact APO LFX/GFX mode, or justify forcing the generic VM relay path onto a GC7. Recover the applied backend files/registration next, then test the actual SonicScout processing contract and direct GC7 route.

## Recovered backend and restart evidence

The reference VM rebooted successfully. ArtTuneKit launched automatically, retained the test profile and showed the relay running. Guest file access recovered. Applied `config.txt`, active-config files, setup/application logs, relay configuration/session logs and endpoint FxProperties were copied to the local QA evidence directory. Authentication files were excluded.

The managed config has explicit Art Tune (8ch) and Art Tune + (16ch) device sections, followed by `Device: all`. Both sections include the shared headphone EQ and boost. The 16ch section includes `16chConfig.txt`, whose populated content references the installed ATK spatial-engine DLL with serialized tune parameters. This is evidence of activation/configuration, not permission to redistribute or copy the proprietary engine into SonicScout.

Setup logs establish a stereo **recording/capture** endpoint, Art Tune Unified Output, configured at 48 kHz. Relay config points at `{0.0.1.00000000}` capture, whereas SonicPass currently uses render loopback. The relay session confirms 48 kHz stereo float capture, 44.1 kHz stereo float render, resampling, small buffer mode, a reported 6.3 ms render buffer and approximately 15.9 ms initial pre-roll. Those are internal settings, not measured end-to-end latency. Logs describe drift correction, queue ceiling resets, discontinuity trimming and delayed retry after an initial capture-open failure during setup audio-service restarts.

The profile activation log enables the 16ch endpoint, disables its 8ch sibling, copies the selected 16ch tune into the managed include, and skips the 8ch-specific LEQ path. The active dashboard's spatial-engine indication matches the referenced plugin. This means modern ArtTuneKit V5 is not merely the historical HeSuVi files in the local stale database.

Both cable render endpoints have FxProperties `{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},1` and `,2` populated with CLSIDs whose InprocServer32 resolves to EqualizerAPO.dll. The raw property inventory is saved locally as `reference-fxproperties.json`. This registry evidence must still be distinguished from verified runtime processing. Microsoft's [audio INF settings documentation](https://learn.microsoft.com/en-us/windows-hardware/drivers/audio/media-class-inf-extensions) describes endpoint effect-property registration.

The VM relay also logged repeated capture discontinuities, render stalls, underruns and queue resets. This virtualized environment does not establish stable real-time playback. The Windows Test button on Art Tune + completed without an error dialog, but sampled relay telemetry did not establish nonzero signal during that short test. Its Properties confirmed 16 channels, 24 bit, 48 kHz and enabled audio enhancements (`13-16ch-properties.png`). No audible quality or latency pass is claimed.

## Measured signal passage

A self-contained .NET 8/NAudio 2.2.1 QA harness played a quiet 440 Hz signal (0.01 input amplitude) in the first two channels of the 16-channel Art Tune + render endpoint for 10 seconds. It simultaneously captured Art Tune Unified Output and loopback from the physical-emulated Speakers output. Native endpoint formats were 16-channel float/48 kHz input, stereo float/48 kHz cable capture and stereo float/44.1 kHz speaker loopback.

The resulting file reports cable peak `0.041728973388671875`, speaker peak `0.041732288897037506`, 1,063,680 cable capture bytes and 944,656 speaker loopback bytes, with `signalDetected: true`. This establishes nonzero passage through the configured reference route. It does not establish correct channel isolation, tune response, full-duration stability or latency. The guest-control parent timed out, but the actual completed guest result file was retrieved successfully; the file, not the CLI timeout, establishes test completion. Harness source and result are preserved alongside this report. Build succeeded; raw transcript and binaries remain in local QA storage.

## Repair priorities established by this walkthrough

1. Replace SonicPass render loopback/multichannel averaging with an explicit contract for the processed stereo capture endpoint. Verify channel isolation with signals before recommending playback.
2. Implement coordinated game version/tune, headphone EQ and channel/device activation with explicit APO device scopes. Validate active processing independently of configuration-file existence.
3. Implement and measure relay buffering, drift/queue control, startup recovery and persistence against a direct-output baseline.
4. Select and validate the approved GC7 hardware path separately from the generic virtual path. The VM cannot establish that route.
5. Package the verified backend behind a guided EXE installer/setup wizard with precise progress, recovery, restart handling and actionable verification. SonicScout remains unsuitable for a tester release until these acceptance checks pass.

## Routing coverage clarification and APO automation sequence

The user highlighted the original non-7.1 hardware fallback through Voicemeeter and Hi-Fi Cable. That branch has **not** been exercised in this GUI walkthrough. ArtTuneKit 1.3.9 on this generic VM explicitly logged that Voicemeeter configuration was not required and selected its own managed relay with VB-Audio Virtual Cable. The current free installer also contains a DAC/amp/onboard PATH B that can download Voicemeeter, but explicitly says it does not configure APO, mixer routing, LEQ or profiles. Its comments identify Hi-Fi Cable as retired. These sources must not be conflated with the historical automatic fallback the user remembers; its version-specific behavior and mixer configuration remain a coverage gap.

The GUI's automatic APO sequence **was observed**: register the clean 16ch APO separately without LEQ residue; then for the 8ch endpoint register E-APO, restart audio services, apply LEQ configuration, restart services, finalize configuration, and restart services again. It writes the scoped managed configuration and verifies endpoint formats afterward. Application logs record audiodg termination during each service restart. The final registry inventory and resulting configuration were captured; intermediate per-phase registry changes and the complete internal algorithm were not captured. This supports reproducing and testing a staged automated sequence, not claiming full recovery of proprietary implementation.
