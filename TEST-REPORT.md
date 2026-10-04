# Test report

Date: 2026-10-04

## Validation performed

| Check | Result | Notes |
|---|---|---|
| Windows PowerShell 5.1 parser | Passed | Parsed `tools/SonicScoutCSharp/setup_audio_stack.ps1` with no syntax errors. |
| Installer dry run | Passed | Ran `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\SonicScoutCSharp\setup_audio_stack.ps1 -Mode Install -DryRun -NonInteractive`; completed with exit code 0 and emitted conditional install, prompt, verification, configuration, and report traces. |
| Dry-run log-write check | Passed | Compared the Sonic Scout setup log directory before and after the dry run; no files were added, removed, or changed. |
| SonicScout C# application Release build | Passed | `dotnet build tools\SonicScoutCSharp\SonicScout.CSharp.csproj --configuration Release` |
| ScoutPass Release build | Passed | `dotnet build tools\SonicScoutCSharp\ScoutPass\SonicScout.ScoutPass.csproj --configuration Release` |
| LEQ Control Panel Release build | Passed | `dotnet build tools\LEQControlPanel\src\LEQControlPanel\LEQControlPanel.csproj --configuration Release` |
| Git whitespace check | Passed | `git diff --check` |
| Setup-window scenario harness | Passed | 30 assertions, 0 failures (see below). |

## Dry-run behavior covered

The dry run did not request elevation, prompt for authorization, download dependencies, launch installers, configure audio endpoints, dot-source the main installer, write Equalizer APO configuration, or write setup history. It simulated interactive routing choices and marked planned installation and verification steps as conditional.

## Setup-window scenario harness

A dedicated harness was added at `C:\Users\brand\AppData\Local\Temp\kilo\setupshot/` and
links the **real** `SetupWindow.xaml` / `.xaml.cs` via `setupshot.csproj`
(`<Page>`/`<Compile>` with `Link=` overrides). Nothing in the product is modified;
every behaviour is injected as a stub. Run with:

```
dotnet run --project C:\Users\brand\AppData\Local\Temp\kilo\setupshot\setupshot.csproj \
  -p:SrcDir="C:\Users\brand\OneDrive\Documents\SonicScout2.0\SonicScout-main\tools\SonicScoutCSharp" \
  -- C:\Users\brand\AppData\Local\Temp\kilo\setupshot\out
```

Result: **PASS 30 / FAIL 0 / TOTAL 30**, exit 0. The 5 PNGs in `out/` were
re-verified with PIL: every one is a real render (`distinct` 1198-1523) and all 5
MD5s are distinct. The harness deletes stale PNGs at start, so the directory can
only ever contain frames from the invocation that just ran.

Scenarios covered: (1) fresh install with physical cable + mixers present, (2) all
endpoints virtual, (3) no active output endpoints, (4) `COMException` during
discovery, (5) checks come back failing, (6) checks come back clean,
(7) speakers-only machine.

WPF gotchas the harness had to work around: the window must be `Show()`n or
` RenderTargetBitmap` returns blank; a bare `DispatcherSynchronizationContext`
must be set before the app or `Progress<T>` marshals to a threadpool thread and
throws "must be STA"; `CheckBox` is ambiguous under `UseWindowsForms=true`;
`throw new COMException(...)` inside a `Func<Task<...>>` lambda is invalid, so the
COM-failure scenario uses `Task.FromException<...>`; and `CheckList` is a `ListBox`
whose item containers are not created until a layout pass, so its text is collected
by walking the visual tree rather than reading `DataContext`.

## Not run

- End-to-end testing in `ArtTuneDB-mainVM` was not run; no matching VM project directory was available in the inspected Documents folder.
- No driver installation or live audio-routing changes were attempted.