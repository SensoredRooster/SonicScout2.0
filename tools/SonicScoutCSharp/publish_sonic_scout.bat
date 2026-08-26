@echo off
setlocal
cd /d "%~dp0\.."
set "OUTPUT=%USERPROFILE%\Desktop\SonicScout"
if exist "%OUTPUT%" rmdir /S /Q "%OUTPUT%"
dotnet publish CSharp\SonicScout.CSharp.csproj --configuration Release --runtime win-x64 --self-contained false --output "%OUTPUT%"
if errorlevel 1 (
  echo Publish failed.
  pause
  exit /b 1
)
if not exist "%OUTPUT%\profiles" mkdir "%OUTPUT%\profiles"
copy /Y "profiles\*.txt" "%OUTPUT%\profiles\" >nul
copy /Y "CSharp\setup_audio_stack.ps1" "%OUTPUT%\setup_audio_stack.ps1" >nul
copy /Y "CSharp\run_audio_stack_setup.bat" "%OUTPUT%\run_audio_stack_setup.bat" >nul
copy /Y "CSharp\auto_setup_dependencies.bat" "%OUTPUT%\auto_setup_dependencies.bat" >nul
copy /Y "CSharp\Install-SonicScout.bat" "%OUTPUT%\Install-SonicScout.bat" >nul
mkdir "%OUTPUT%\installers"
echo Published to:
echo %OUTPUT%
echo.
echo On the destination PC, run Install-SonicScout.bat from the published SonicScout folder.
pause
endlocal
