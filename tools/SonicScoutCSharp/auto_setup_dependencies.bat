@echo off
setlocal
set "COMPONENT=all"
set "DOWNLOAD_ONLY=0"
:parse
if "%~1"=="" goto download
if /I "%~1"=="/download-only" set "DOWNLOAD_ONLY=1"
if /I "%~1"=="/equalizer-apo" set "COMPONENT=equalizer-apo"
if /I "%~1"=="/vb-cable" set "COMPONENT=vb-cable"
if /I "%~1"=="/reaplugs" set "COMPONENT=reaplugs"
if /I "%~1"=="/hi-fi-cable" set "COMPONENT=hi-fi-cable"
if /I "%~1"=="/hesuvi" set "COMPONENT=hesuvi"
shift
goto parse
:download
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0download_dependencies.ps1" -Component "%COMPONENT%"
if errorlevel 1 exit /b %ERRORLEVEL%
if "%DOWNLOAD_ONLY%"=="1" exit /b 0
call "%~dp0run_audio_stack_setup.bat"
exit /b %ERRORLEVEL%
