@echo off
echo Sonic Scout setup report
echo Desktop: %USERPROFILE%\Desktop\SonicScout-Setup.log
echo Temp:    %TEMP%\SonicScout-Setup.log
if exist "%USERPROFILE%\Desktop\SonicScout-Setup.log" (
  notepad "%USERPROFILE%\Desktop\SonicScout-Setup.log"
) else if exist "%TEMP%\SonicScout-Setup.log" (
  notepad "%TEMP%\SonicScout-Setup.log"
) else (
  echo No setup log yet. Run Setup-SonicScout.bat first.
  pause
)
