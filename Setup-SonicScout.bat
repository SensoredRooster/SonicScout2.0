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

REM One installer, every time: the PowerShell menu. No Hi-Fi Cable, no second bat.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0powershell\Install-SonicScout2.0.ps1"
set "RESULT=%ERRORLEVEL%"
endlocal
exit /b %RESULT%
