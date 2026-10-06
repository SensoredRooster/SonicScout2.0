@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0publish_sonic_scout.ps1" %*
exit /b %ERRORLEVEL%
