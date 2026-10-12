# Physical-PC SonicPass startup failure

Status: audio functionality blocked; no audio fix verified yet.

Source: https://github.com/SensoredRooster/SonicScout2.0/issues/4, support session aaec5e278ae8. The attachment was downloaded and extracted into the persistent QA folder, without executing its contents. ZIP SHA256: C36A8334363F3543124A0074E9AC0DC844DF2483645C85C387E037457071BC76.

The recorded error is: System.ArgumentException: Value does not fall within the expected range. Stack: Marshal.ThrowExceptionForHR -> NAudio.CoreAudioApi.AudioClient.Initialize -> NAudio.Wave.WasapiOut.Init -> SonicPassEngine.Start (Program.cs line 256). It repeats on startup attempts in this session.

The routing configuration selects SonicScout2.0 (VB-Audio Virtual Cable) and Speakers (Sound Blaster GC7). The failure occurs during output-stream initialization, before capture starts and before the running message. Diagnostics retrieval and stderr capture now work.

This establishes the failing boundary, not the exact rejected parameter. The bundle does not include capture/mix/playback formats or WASAPI initialization flags/timing. Possible format, event-mode or driver constraints must be distinguished before claiming a fix. NAudio 2.2.1 source reviewed: https://github.com/naudio/NAudio/blob/v2.2.1/NAudio.Wasapi/WasapiOut.cs. Its shared-mode event initialization uses the provided format and requested buffer duration with automatic conversion flags.

The GC7 is on the user's physical PC, not the QA VM. Installation/preflight/build and binary --help successes do not verify this playback path. Preserve existing game audio on the working physical output until a routing fix has been verified.
