@echo off
setlocal
cd /d "%~dp0"
title Sonic Scout Setup

net session >nul 2>&1
if errorlevel 1 (
  echo Requesting administrator access...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b 0
)

echo.
echo =====================================================
echo    SONIC SCOUT SETUP
echo    Same window every time. Do not open another bat.
echo =====================================================
echo.

call "%~dp0tools\SonicScoutCSharp\auto_setup_dependencies.bat" /download-only
if errorlevel 1 (
  echo.
  echo Download did not finish. Leave this window open and send a screenshot.
  pause
  exit /b 1
)

echo.
echo Downloads finished. Starting the installer in this same window.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\SonicScoutCSharp\setup_audio_stack.ps1" -Mode Install
set "RESULT=%ERRORLEVEL%"

echo.
if "%RESULT%"=="0" (
  echo Sonic Scout setup finished.
) else (
  echo Sonic Scout setup needs attention. Exit code: %RESULT%
)
echo.
pause
endlocal
exit /b %RESULT%
