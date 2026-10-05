@echo off
setlocal
cd /d "%~dp0"

set "OUTPUT=%USERPROFILE%\Desktop\SonicScout"
if exist "%OUTPUT%" rmdir /S /Q "%OUTPUT%"

dotnet publish "SonicScout.CSharp.csproj" --configuration Release --runtime win-x64 --self-contained false --output "%OUTPUT%"
if errorlevel 1 (
  echo Publish failed. Make sure the .NET 8 SDK is installed, then try again.
  exit /b 1
)

if not exist "%OUTPUT%\profiles" mkdir "%OUTPUT%\profiles"
if exist "profiles\*.txt" copy /Y "profiles\*.txt" "%OUTPUT%\profiles\" >nul
copy /Y "setup_audio_stack.ps1" "%OUTPUT%\setup_audio_stack.ps1" >nul
copy /Y "run_audio_stack_setup.bat" "%OUTPUT%\run_audio_stack_setup.bat" >nul
copy /Y "auto_setup_dependencies.bat" "%OUTPUT%\auto_setup_dependencies.bat" >nul
copy /Y "Install-SonicScout.bat" "%OUTPUT%\Install-SonicScout.bat" >nul

if exist "installers" (
  xcopy /E /I /Y "installers" "%OUTPUT%\installers" >nul
) else (
  mkdir "%OUTPUT%\installers"
)

if not exist "%OUTPUT%\SonicScout.exe" (
  echo Publish completed without SonicScout.exe.
  exit /b 1
)

echo Published to:
echo %OUTPUT%
echo.
echo On the destination PC, run Install-SonicScout.bat from the published SonicScout folder.
endlocal
exit /b 0
