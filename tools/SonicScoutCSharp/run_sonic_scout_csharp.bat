@echo off
setlocal
cd /d "%~dp0\.."

set "SETUP_SCRIPT=CSharp\setup_audio_stack.ps1"
if exist "%SETUP_SCRIPT%" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%SETUP_SCRIPT%" -Mode Preflight -Quiet >nul 2>&1
  set "PRECHECK=%ERRORLEVEL%"
  if "%PRECHECK%"=="2" (
    echo Sonic Scout detected missing or incomplete audio dependencies.
    choice /C YN /N /M "Run guided audio stack setup now? [Y/N]: "
    if errorlevel 2 goto continue_launch
    call "CSharp\run_audio_stack_setup.bat"
    set "SETUP_RESULT=%ERRORLEVEL%"
    if not "%SETUP_RESULT%"=="0" (
      echo Guided setup reported pending issues.
      choice /C YN /N /M "Continue launching Sonic Scout anyway? [Y/N]: "
      if errorlevel 2 exit /b 1
    )
  )
)

:continue_launch
set "PROJECT=CSharp\SonicScout.CSharp.csproj"
set "APP=CSharp\bin\Release\net8.0-windows\SonicScout.exe"
if not exist "%APP%" goto build
for %%F in ("CSharp\*.xaml" "CSharp\*.cs" "CSharp\*.csproj") do if "%%~tF" GTR "%APP%" goto build
goto sync
:build
dotnet restore "%PROJECT%" --verbosity quiet
if errorlevel 1 goto fail
dotnet build "%PROJECT%" --configuration Release --no-restore --verbosity minimal
if errorlevel 1 goto fail
:sync
set "SCOUTPASS_PROJECT=CSharp\ScoutPass\SonicScout.ScoutPass.csproj"
set "SCOUTPASS_APP=CSharp\ScoutPass\bin\Release\net8.0-windows\SonicScout.SonicPass.exe"
if not exist "%SCOUTPASS_APP%" goto build_scoutpass
for %%F in ("CSharp\ScoutPass\*.cs" "CSharp\ScoutPass\*.csproj") do if "%%~tF" GTR "%SCOUTPASS_APP%" goto build_scoutpass
goto finish_sync
:build_scoutpass
dotnet restore "%SCOUTPASS_PROJECT%" --verbosity quiet
if errorlevel 1 goto fail
dotnet build "%SCOUTPASS_PROJECT%" --configuration Release --no-restore --verbosity minimal
if errorlevel 1 goto fail
:finish_sync
if not exist "CSharp\bin\Release\net8.0-windows\profiles" mkdir "CSharp\bin\Release\net8.0-windows\profiles"
copy /Y "profiles\*.txt" "CSharp\bin\Release\net8.0-windows\profiles\" >nul
start "" "%APP%"
endlocal
exit /b 0
:fail
echo Sonic Scout could not be built. Install the .NET 8 SDK and try again.
pause
exit /b 1
