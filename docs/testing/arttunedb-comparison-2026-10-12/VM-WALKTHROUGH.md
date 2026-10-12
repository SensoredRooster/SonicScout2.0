# Original installation reference walkthrough

October 12, 2026. **Application installation completed; audio setup and playback are pending licensed sign-in.**

## Environment and preserved evidence

A separate VirtualBox VM, `ArtTuneDB-Reference-QA-20261012`, was cloned from the cold `Installation-verified-round1-20261006` snapshot of the SonicScout QA VM. The original VM and its snapshots were preserved. The clone runs Windows 11 Enterprise Evaluation x64 with a disposable local account. Its inherited guest computer name is SONICSCOUT-QA.

The guest baseline reset returned exit code 0. Its transcript records Equalizer APO and VB-Cable uninstall exit codes of 0, and preserves the previous configuration, plugins and app data under `C:\QA\previous-install-20261012-134834`. A shutdown was requested to finalize driver removal; post-reboot dependency and endpoint verification is still pending. This is a prepared baseline, not evidence of a completed original installation.

Raw logs, screenshots and the reference installer are kept locally at `C:\Users\brand\Documents\ArtTuneDB-Reference-QA-2026-10-12`. The reset transcript was copied out of the guest as `dependency-reset.txt`. Credentials are excluded from repository reports.

The current free guided installer was retrieved from the [official installer endpoint](https://artiswar.io/tools/ArtTuneGuided). Authenticode validation returned Valid. SHA256: `48F5D9D82ACF79683D59A498FA87EEA6DD82C7BD340571E54024B249133726C3`. It has been copied into the guest but has not been run.

## Product identity and architectural evidence

The local ArtTuneDB source contains the free installer and audio library, rather than the ArtTuneKit GUI application. The [ArtTuneDB README](https://github.com/ArtIsWar/ArtTuneDB) distinguishes its manual setup requirements from ArtTuneKit automation. The [ArtTuneKit download page](https://artiswar.io/download) requires account sign-in and an active license. A clarification about which product the user successfully installed is pending; the free script must not be presented as a full ArtTuneKit application test.

The [official device guide](https://artiswar.io/devices) identifies the GC7 Speakers endpoint as the game route and Headset as the voice route, renamed Art Tune (Game) and Normal Audio (Voice). SonicScout instead introduced a virtual cable and SonicPass relay on the user's GC7 system. This is a material routing difference to investigate alongside the confirmed channel-mapping defect in REPORT.md. Documentation does not establish that this difference alone caused the reported distortion or latency.

The virtual machine has no physical GC7. It can establish installation screens, file/configuration changes and generic virtual audio routing. GC7-specific APO processing, audible quality and end-to-end latency require a later hardware test.

## Remaining walkthrough

1. Verify the restarted baseline and preserve its dependency/endpoint inventory.
2. Identify the original product and obtain its legitimate installer if the GUI product was used.
3. Record installation screens, prompts, reboot handling, configuration files, device selection, APO effects registration/mode and completion checks.
4. Trace profile activation and the actual playback path; compare each stage with SonicScout implementation.
5. Turn verified differences into repairs and acceptance checks before a tester release. Existing SonicScout audio quality remains a failed user test.

## ArtTuneKit 1.3.9 installation observed

The user supplied the local ArtTuneKit-Setup-1.3.9.exe download, resolving the product identity. A copy is preserved outside the repository in the QA reference-source folder. Authenticode returned Valid; SHA256 is `38586286365AF37ECED2E29B00592901B2F8F2757294FF6037CD71774D149BCD`.

After the baseline reboot, EqualizerAPO's installation directory was absent and PnP enumeration showed only the standard High Definition Audio speakers and microphone. The supplied EXE was run inside the reference VM.

Observed flow: install scope (all users recommended, selected), UAC with verified publisher ArtIsWar, LLC, license agreement, information page, destination `C:\Program Files\ArtTuneKit` (647.2 MB minimum), desktop shortcut and elevated Windows startup options (both selected by default), installation summary, extraction, Visual C++ x64 redistributable stage, successful completion, and checked Launch ArtTuneKit option. No user-facing command prompt was needed for this application installation.

First launch displayed a modal requiring sign-in with the purchase account or purchase. Audio setup could not be accessed at this stage. The user was asked to complete sign-in personally in the open reference VM; no credentials were requested in chat, and no license bypass or purchase was attempted. Application installation success does not establish audio stack setup success.

Screenshots preserved locally: `02-installer-information.png`, `03-destination.png`, `04-shortcuts-startup.png`, `05-install-complete.png`, and `06-license-signin-required.png`. VirtualBox capture initially failed while the guest display was asleep; a harmless Shift key woke it and restored capture. This was a QA display issue, not an ArtTuneKit installer failure.
