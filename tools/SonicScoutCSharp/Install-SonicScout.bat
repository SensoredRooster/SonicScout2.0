@echo off
setlocal
cd /d "%~dp0"

echo Sonic Scout setup package: 2026.08.21.4

if not exist "%~dp0SonicScout.exe" (
  echo SonicScout.exe was not found. Run publish_sonic_scout.bat again and use the published SonicScout folder.
  pause
  exit /b 1
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