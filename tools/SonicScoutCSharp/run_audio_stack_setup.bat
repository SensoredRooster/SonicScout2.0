@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup_audio_stack.ps1" -Mode Install %*
exit /b %ERRORLEVEL%
