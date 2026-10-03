@echo off
title Sonic Scout Setup
cd /d "%~dp0"
net session >nul 2>&1
if errorlevel 1 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b 0
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0powershell\Install-Unattended.ps1"
echo.
echo Setup log: %TEMP%\SonicScout-Setup.log
pause
