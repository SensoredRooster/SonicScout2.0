@echo off
setlocal
if exist "%~dp0SonicScout.exe" goto install
if not exist "%~dp0SonicScout.CSharp.csproj" goto missing
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0publish_sonic_scout.ps1"
if errorlevel 1 exit /b %ERRORLEVEL%
powershell.exe -NoProfile -Command "$folder=Join-Path ([Environment]::GetFolderPath('Desktop')) 'SonicScout'; & (Join-Path $folder 'Install-SonicScout.bat'); exit $LASTEXITCODE"
exit /b %ERRORLEVEL%
:install
call "%~dp0run_audio_stack_setup.bat"
if errorlevel 1 exit /b %ERRORLEVEL%
start "" "%~dp0SonicScout.exe"
exit /b 0
:missing
echo Incomplete SonicScout package. Extract the complete package, then retry.
exit /b 1
