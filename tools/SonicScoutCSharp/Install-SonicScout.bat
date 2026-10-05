@echo off
setlocal
cd /d "%~dp0"

echo Sonic Scout setup package: 2026.08.21.4

if not exist "%~dp0SonicScout.exe" (
  if exist "%~dp0SonicScout.CSharp.csproj" (
    echo Source checkout detected. Starting the source launcher, which will build Sonic Scout if needed.
    call "%~dp0run_sonic_scout_csharp.bat"
    set "RESULT=%ERRORLEVEL%"
    endlocal
    exit /b %RESULT%
  )
  echo SonicScout.exe was not found and this does not look like a source checkout.
  echo Re-extract the published SonicScout folder or download a complete release package.
  pause
  exit /b 1
)

where dotnet >nul 2>&1
if errorlevel 1 (
  echo Sonic Scout requires the Microsoft .NET 8 Desktop Runtime before audio setup can begin.
  echo Download it from: https://dotnet.microsoft.com/download/dotnet/8.0
  pause
  exit /b 3
)

dotnet --list-runtimes 2>nul | findstr /C:"Microsoft.WindowsDesktop.App 8." >nul
if errorlevel 1 (
  echo Sonic Scout requires the Microsoft .NET 8 Desktop Runtime before audio setup can begin.
  echo Download the Windows Desktop Runtime 8.x from:
  echo https://dotnet.microsoft.com/download/dotnet/8.0
  pause
  exit /b 3
)

call "%~dp0run_audio_stack_setup.bat"
set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" (
  echo Sonic Scout audio setup did not complete. Sonic Scout was not started.
  pause
  exit /b %RESULT%
)

start "" "%~dp0SonicScout.exe"
endlocal
exit /b 0