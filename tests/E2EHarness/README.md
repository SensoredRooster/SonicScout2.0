# SonicScout VM end-to-end harness

Scripts that drive a brand-new-user install of `SonicScout-Setup.exe` inside a VirtualBox VM. They are used to qualify tester builds. All driver, APO and audio-device changes happen only inside the VM.

## Prerequisites (host)

- VirtualBox with a Windows 11 VM (default name `SonicScout-Phase0-E2E-20261014`). It needs a snapshot `clean-baseline-audio-v2` with a standard user `tester`, Guest Additions and UAC on.
- A QA folder (default `C:\Users\brand\Documents\SonicScout-QA-2026-10-14`, override with `SS_QA_DIR`) containing:
  - `vm-password.txt` (the guest password, never committed)
  - `<build>\SonicScout-Setup.exe`
  - `probe\SonicScout.E2EProbe.exe`
  - copies of these scripts under `e2e\`

## Scripts

| Script | Runs on | Purpose |
|---|---|---|
| `run-full.ps1 -Build buildN` | host | Full loop: restore snapshot → install → UAC 1 → app setup → UAC 2 → reboot → RunOnce auto-resume → `verify.ps1` → `user-flow.ps1`. Logs to `e2e\run-<build>.log`. |
| `gx-host.ps1 -Script '...'` | host | Runs a PowerShell snippet in the guest via `VBoxManage guestcontrol`. |
| `uac-yes.ps1` | host | Answers a pending UAC prompt (Alt+Y scancodes) while `consent.exe` is running. |
| `drive-app.ps1` | guest | UI Automation driver for the setup window. |
| `verify.ps1` | guest | Plays a probe tone through the game device and samples `eq-status.json` (expects NO AUDIO → RUNNING), and checks the E-APO, include and RunOnce state. |
| `user-flow.ps1` | guest | First-time user exercise: AutoEq profile + game target, device choice, tone/status, non-admin EQ change, Support & Diagnostics, close/reopen. Writes `C:\QA\out\user.txt`/`user.json`; `RESULT key=True/False` lines are folded into the run. |
| `uia-dump.ps1` | guest | Dumps the app's UI Automation tree for debugging. |

Guest UI scripts must run in the interactive session. Use a `/IT /RL LIMITED` scheduled task, not `guestcontrol run`. Note that WPF `StackPanel`s have no UIA peer, so find profile tiles by their button text, not by `ProfileStackPanel`.

Keep each wait under 10 minutes. On a headless VM, refresh a stale screenshot with `controlvm setvideomodehint` before `screenshotpng`.
