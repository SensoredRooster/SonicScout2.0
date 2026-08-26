@echo off
setlocal

set "PROJECT_DIR=%~dp0"
if not exist "%PROJECT_DIR%SonicScout.CSharp.csproj" (
  if exist "%~dp0CSharp\SonicScout.CSharp.csproj" (
    set "PROJECT_DIR=%~dp0CSharp\"
  ) else (
    echo Could not locate SonicScout.CSharp.csproj next to the launcher.
    pause
    exit /b 1
  )
)

set "SETUP_SCRIPT=%PROJECT_DIR%setup_audio_stack.ps1"
if exist "%SETUP_SCRIPT%" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%SETUP_SCRIPT%" -Mode Preflight -Quiet >nul 2>&1
  set "PRECHECK=%ERRORLEVEL%"
  if "%PRECHECK%"=="2" (
    echo Sonic Scout detected missing or incomplete audio dependencies.
    choice /C YN /N /M "Run guided audio stack setup now? [Y/N]: "
    if errorlevel 2 goto continue_launch
    call "%PROJECT_DIR%run_audio_stack_setup.bat"
    set "SETUP_RESULT=%ERRORLEVEL%"
    if not "%SETUP_RESULT%"=="0" (
      echo Guided setup reported pending issues.
      choice /C YN /N /M "Continue launching Sonic Scout anyway? [Y/N]: "
      if errorlevel 2 exit /b 1
    )
  )
)

:continue_launch
set "PROJECT=%PROJECT_DIR%SonicScout.CSharp.csproj"
set "APP_DIR=%PROJECT_DIR%bin\Release\net8.0-windows\"
set "APP=%APP_DIR%SonicScout.exe"
if not exist "%APP%" goto build
for %%F in ("%PROJECT_DIR%*.xaml" "%PROJECT_DIR%*.cs" "%PROJECT_DIR%*.csproj") do if "%%~tF" GTR "%APP%" goto build
goto sync
:build
dotnet restore "%PROJECT%" --verbosity quiet
if errorlevel 1 goto fail
dotnet build "%PROJECT%" --configuration Release --no-restore --verbosity minimal
if errorlevel 1 goto fail
:sync
set "SCOUTPASS_PROJECT=%PROJECT_DIR%ScoutPass\SonicScout.ScoutPass.csproj"
set "SCOUTPASS_APP=%PROJECT_DIR%ScoutPass\bin\Release\net8.0-windows\SonicScout.SonicPass.exe"
if not exist "%SCOUTPASS_APP%" goto build_scoutpass
for %%F in ("%PROJECT_DIR%ScoutPass\*.cs" "%PROJECT_DIR%ScoutPass\*.csproj") do if "%%~tF" GTR "%SCOUTPASS_APP%" goto build_scoutpass
goto finish_sync
:build_scoutpass
dotnet restore "%SCOUTPASS_PROJECT%" --verbosity quiet
if errorlevel 1 goto fail
dotnet build "%SCOUTPASS_PROJECT%" --configuration Release --no-restore --verbosity minimal
if errorlevel 1 goto fail
:finish_sync
if exist "%PROJECT_DIR%profiles" if not exist "%APP_DIR%profiles" mkdir "%APP_DIR%profiles"
if exist "%PROJECT_DIR%profiles\*.txt" copy /Y "%PROJECT_DIR%profiles\*.txt" "%APP_DIR%profiles\" >nul
start "" "%APP%"
endlocal
exit /b 0
:fail
echo Sonic Scout could not be built. Install the .NET 8 SDK and try again.
pause
exit /b 1
