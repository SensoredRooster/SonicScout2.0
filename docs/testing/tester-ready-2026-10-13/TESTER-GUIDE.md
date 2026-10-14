# Sonic Scout tester instructions

Use the supplied **SonicScout-Setup.exe**, not the repository ZIP or batch files.
This is a Windows 10/11 x64 tester build. Initial component downloads and new
headphone/game-target calculations require internet access. Saved tunes work offline.

1. Open the EXE, approve its Windows permission request, review the app and component notices, and install. Leave **Open Sonic Scout** checked and click **Finish**.
2. In setup, select the real headphones/speakers you listen through. Use **Sonic Scout Direct Route**. Authorise the audio changes and click **Run install setup**. Audio components and cable APO registration are automatic; Windows may request driver permission.
3. If asked to restart, save your work and restart Windows. Reopen Sonic Scout from its shortcut and run **SETUP** to finish verification. Do not assign a game to the cable while setup is incomplete.
4. Use **Verify settings** to check the physical output volume and running route. Confirm Spatial Sound is off for the Sonic Scout cable and your physical output. Close setup with **Done**.
5. Click **Select headphone/IEM profile** (or **+**), find the correct measured model, select the game target you want, and click **Use profile**. Calculation may take a few seconds. The resulting profile activates automatically.
6. Confirm the **SonicPass audio route** shows **RUNNING**. Its **Physical output** must be your headphones/speakers. In the game's own audio settings, select the exact **Virtual input** shown in Sonic Scout. Keep the Windows default output on your normal physical device.
7. Start with both boosts at **0 dB** and buffer at **20 ms**. Test ordinary game audio, a profile switch, EQ slider changes, stop/start, and closing/reopening the app. The developer is separately testing real-hardware latency and sound quality; report these observations rather than assuming they have passed.

If sound stops, select your physical headphones/speakers in the game's audio settings to restore normal game audio. Then open Sonic Scout **Diagnostics**, choose **Create support bundle**, and save the ZIP for your report. Diagnostics stay local until you explicitly choose to send them.

Report the physical audio device, game, selected profile/target, exact action that failed, and what appeared on screen. Attach the local ZIP when submitting your test report.

To remove the app, switch any game back to its physical output first, then uninstall **Sonic Scout** from Windows Installed Apps. Profiles and shared audio components remain; the uninstaller explains this. This tester build is unsigned and its Windows publisher prompt shows that fact.

Optional third-party mixer configurations are compatibility tests, not prerequisites for the direct route. Do not change an existing working mixer configuration merely to test Sonic Scout.
