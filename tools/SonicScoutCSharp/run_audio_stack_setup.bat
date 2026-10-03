@echo off
setlocal
cd /d "%~dp0"

net session >nul 2>&1
if errorlevel 1 (
  echo Requesting administrator access for Sonic Scout audio setup...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs -Wait"
  set "RESULT=%ERRORLEVEL%"
  endlocal
  exit /b %RESULT%
)

set "SETUP_SCRIPT=%~dp0setup_audio_stack.ps1"
if not exist "%SETUP_SCRIPT%" (
  echo setup_audio_stack.ps1 was not found.
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%SETUP_SCRIPT%" -Mode Install
set "RESULT=%ERRORLEVEL%"

if "%RESULT%"=="0" (
  echo.
  echo Sonic Scout audio stack setup completed successfully.
) else (
  echo.
  echo Sonic Scout audio stack setup needs attention. Exit code: %RESULT%
)

pause
endlocal
exit /b %RESULT%
