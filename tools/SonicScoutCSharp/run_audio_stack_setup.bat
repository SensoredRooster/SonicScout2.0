@echo off
echo This file is not the setup. Opening the one setup window.
cd /d "%~dp0\..\.."
if not exist "%cd%\Setup-SonicScout.bat" cd /d "%~dp0\.."
call "%cd%\Setup-SonicScout.bat"
