@echo off
setlocal
cd /d "%~dp0"

set "OUTPUT=%USERPROFILE%\Desktop\SonicScout"
if exist "%OUTPUT%" rmdir /S /Q "%OUTPUT%"

dotnet publish "SonicScout.CSharp.csproj" --configuration Release --runtime win-x64 --self-contained false --output "%OUTPUT%"
if errorlevel 1 (
  echo Publish failed.
  pause
  exit /b 1
)

REM The project file already copies runtime setup scripts, installer payloads,
REM logo/targets, and SonicPass. Copy only entry-point files not included by MSBuild.
copy /Y "Install-SonicScout.bat" "%OUTPUT%\Install-SonicScout.bat" >nul
if errorlevel 1 (
  echo Failed to copy Install-SonicScout.bat into the published folder.
  pause
  exit /b 1
)

if exist "profiles\*.txt" (
  if not exist "%OUTPUT%\profiles" mkdir "%OUTPUT%\profiles"
  copy /Y "profiles\*.txt" "%OUTPUT%\profiles\" >nul
)

echo Published to:
echo %OUTPUT%
echo.
echo On the destination PC, run Install-SonicScout.bat from the published SonicScout folder.
pause
endlocal
exit /b 0
