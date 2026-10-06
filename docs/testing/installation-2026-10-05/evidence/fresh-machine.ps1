$ErrorActionPreference='Continue'
$root='C:\QA'
New-Item -ItemType Directory -Path "$root\evidence" -Force | Out-Null
Start-Transcript -Path "$root\evidence\fresh-machine.txt" -Force
Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,OSArchitecture
whoami
whoami /groups
Get-Command dotnet -ErrorAction SilentlyContinue
Get-ChildItem 'C:\Program Files\dotnet\shared' -ErrorAction SilentlyContinue
cmd.exe /d /c 'echo.|C:\QA\source\tools\SonicScoutCSharp\Install-SonicScout.bat'
"Source installer exit: $LASTEXITCODE"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\QA\source\tools\SonicScoutCSharp\setup_audio_stack.ps1 -Mode Preflight
"Fresh preflight exit: $LASTEXITCODE"
cmd.exe /d /c 'echo.|C:\QA\source\tools\SonicScoutCSharp\run_sonic_scout_csharp.bat'
"Source launcher exit: $LASTEXITCODE"
Get-ChildItem C:\QA\published -File | Where-Object Name -Match 'Install|SonicScout|setup'
Stop-Transcript
