@echo off
setlocal
cd /d "%~dp0"

set "PROJECT=ScoutPass\SonicScout.ScoutPass.csproj"
set "APP=ScoutPass\bin\Release\net8.0-windows\SonicScout.SonicPass.exe"
if not exist "%APP%" (
  dotnet build "%PROJECT%" --configuration Release --verbosity minimal
  if errorlevel 1 (
    echo SonicPass could not be built.
    pause
    exit /b 1
  )
)

"%APP%" %*
set "RESULT=%ERRORLEVEL%"
endlocal
exit /b %RESULT%
