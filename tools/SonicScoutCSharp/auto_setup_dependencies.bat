@echo off
REM Sonic Scout - Auto Dependency Downloader + Installer
setlocal

set "DOWNLOAD_ONLY=0"
set "DOWNLOAD_EQUALIZER=1"
set "DOWNLOAD_VBCABLE=1"
set "DOWNLOAD_HIFI=1"
set "DOWNLOAD_REAPLUGS=0"

:parse_arguments
if "%~1"=="" goto arguments_parsed
if /I "%~1"=="/download-only" set "DOWNLOAD_ONLY=1"
if /I "%~1"=="/equalizer-apo" (
  set "DOWNLOAD_EQUALIZER=1"
  set "DOWNLOAD_VBCABLE=0"
  set "DOWNLOAD_HIFI=0"
)
if /I "%~1"=="/vb-cable" (
  set "DOWNLOAD_EQUALIZER=0"
  set "DOWNLOAD_VBCABLE=1"
  set "DOWNLOAD_HIFI=0"
)
if /I "%~1"=="/reaplugs" (
  set "DOWNLOAD_EQUALIZER=0"
  set "DOWNLOAD_VBCABLE=0"
  set "DOWNLOAD_HIFI=0"
  set "DOWNLOAD_REAPLUGS=1"
)
if /I "%~1"=="/hi-fi-cable" (
  set "DOWNLOAD_EQUALIZER=0"
  set "DOWNLOAD_VBCABLE=0"
  set "DOWNLOAD_HIFI=1"
)
shift
goto parse_arguments

:arguments_parsed

if "%DOWNLOAD_ONLY%"=="0" (
  net session >nul 2>&1
  if errorlevel 1 (
    echo Requesting admin access...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs -Wait"
    set "RESULT=%ERRORLEVEL%"
    endlocal
    exit /b %RESULT%
  )
)

title Sonic Scout - Dependency Setup
cd /d "%~dp0"
cls

echo.
echo =====================================================
echo    SONIC SCOUT - AUTO DEPENDENCY SETUP
echo =====================================================
echo.

set "INSTALLERS=%~dp0installers"
if not exist "%INSTALLERS%" mkdir "%INSTALLERS%"
set "SS_INSTALLERS=%INSTALLERS%"

if "%DOWNLOAD_EQUALIZER%"=="1" (
  echo [1/3] Downloading Equalizer APO...
  powershell -NoProfile -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; (New-Object Net.WebClient).DownloadFile('https://sourceforge.net/projects/equalizerapo/files/1.4.2/EqualizerAPO-x64-1.4.2.exe/download', (Join-Path $env:SS_INSTALLERS 'EqualizerAPO_Setup.exe'))"
  if exist "%INSTALLERS%\EqualizerAPO_Setup.exe" (
    powershell -NoProfile -Command "$bytes = [System.IO.File]::ReadAllBytes((Join-Path $env:SS_INSTALLERS 'EqualizerAPO_Setup.exe')); if ($bytes.Length -lt 1048576 -or $bytes[0] -ne 77 -or $bytes[1] -ne 90) { exit 1 }"
    if errorlevel 1 (
      del /q "%INSTALLERS%\EqualizerAPO_Setup.exe" >nul 2>&1
      echo [FAIL] Equalizer APO download was not a valid Windows installer
    ) else (
      echo [OK] Equalizer APO downloaded
    )
  ) else (
    echo [FAIL] Equalizer APO download failed
  )
)
echo.

if "%DOWNLOAD_VBCABLE%"=="1" (
echo [2/3] Downloading VB-Cable...
powershell -NoProfile -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; (New-Object Net.WebClient).DownloadFile('https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack45.zip', (Join-Path $env:SS_INSTALLERS 'VBCABLE_Driver.zip'))"
if exist "%INSTALLERS%\VBCABLE_Driver.zip" (
  powershell -NoProfile -Command "Expand-Archive -Path (Join-Path $env:SS_INSTALLERS 'VBCABLE_Driver.zip') -DestinationPath (Join-Path $env:SS_INSTALLERS 'VBCABLE') -Force"
  copy /Y "%INSTALLERS%\VBCABLE\VBCABLE_Setup_x64.exe" "%INSTALLERS%\VBCABLE_Setup_x64.exe" >nul 2>&1
  if exist "%INSTALLERS%\VBCABLE_Setup_x64.exe" (
    echo [OK] VB-Cable downloaded
  ) else (
    echo [FAIL] VB-Cable installer was not found in the downloaded package
  )
) else (
  echo [FAIL] VB-Cable download failed
)
)
echo.

if "%DOWNLOAD_REAPLUGS%"=="1" (
echo [3/3] Downloading ReaPlugs...
powershell -NoProfile -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; (New-Object Net.WebClient).DownloadFile('https://www.reaper.fm/reaplugs/reaplugs236_x64-install.exe', (Join-Path $env:SS_INSTALLERS 'reaplugs_x64.exe'))"
if exist "%INSTALLERS%\reaplugs_x64.exe" (
  echo [OK] ReaPlugs downloaded
) else (
  echo [FAIL] ReaPlugs download failed
)
)
echo.

if "%DOWNLOAD_HIFI%"=="1" (
echo [3/3] Downloading VB-Cable Hi-Fi...
powershell -NoProfile -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; (New-Object Net.WebClient).DownloadFile('https://download.vb-audio.com/Download_CABLE/HiFiCableAsioBridgeSetup_v1007.zip', (Join-Path $env:SS_INSTALLERS 'VBHIFI_Driver.zip'))"
if exist "%INSTALLERS%\VBHIFI_Driver.zip" (
  powershell -NoProfile -Command "Expand-Archive -Path (Join-Path $env:SS_INSTALLERS 'VBHIFI_Driver.zip') -DestinationPath (Join-Path $env:SS_INSTALLERS 'VBHIFI') -Force"
  powershell -NoProfile -Command "$installer = Get-ChildItem -Path (Join-Path $env:SS_INSTALLERS 'VBHIFI') -Recurse -File -Filter '*Setup*.exe' | Select-Object -First 1; if ($null -eq $installer) { exit 1 }; Copy-Item -Path $installer.FullName -Destination (Join-Path $env:SS_INSTALLERS 'HIFI_CABLE_Setup_x64.exe') -Force"
  if exist "%INSTALLERS%\HIFI_CABLE_Setup_x64.exe" (
    echo [OK] VB-Cable Hi-Fi downloaded
  ) else (
    echo [FAIL] VB-Cable Hi-Fi installer was not found in the downloaded package
  )
) else (
  echo [FAIL] VB-Cable Hi-Fi download failed
)
)
echo.

if "%DOWNLOAD_ONLY%"=="1" (
  if "%DOWNLOAD_EQUALIZER%"=="1" if not exist "%INSTALLERS%\EqualizerAPO_Setup.exe" exit /b 1
  if "%DOWNLOAD_VBCABLE%"=="1" if not exist "%INSTALLERS%\VBCABLE_Setup_x64.exe" exit /b 1
  if "%DOWNLOAD_REAPLUGS%"=="1" if not exist "%INSTALLERS%\reaplugs_x64.exe" exit /b 1
  if "%DOWNLOAD_HIFI%"=="1" if not exist "%INSTALLERS%\HIFI_CABLE_Setup_x64.exe" exit /b 1
  echo Audio dependency downloads completed.
  endlocal
  exit /b 0
)

echo Running Sonic Scout audio stack setup...
echo.
call "%~dp0run_audio_stack_setup.bat"

echo.
echo =====================================================
echo    DONE - RESTART YOUR PC WHEN COMPLETE
echo =====================================================
echo.
pause
