Unicode true
!include "MUI2.nsh"
!include "x64.nsh"
!include "LogicLib.nsh"
!include "WinVer.nsh"
!ifndef PAYLOAD
 !error "Build with build_installer.ps1"
!endif
Name "Sonic Scout"
OutFile "${OUTPUT}\SonicScout-Setup.exe"
InstallDir "$PROGRAMFILES64\SonicScout"
RequestExecutionLevel admin
SetCompressor /SOLID lzma
VIProductVersion "2.9.0.0"
VIAddVersionKey "ProductName" "Sonic Scout"
VIAddVersionKey "FileDescription" "Sonic Scout Windows Setup (development build)"
VIAddVersionKey "FileVersion" "2.9.0.0"
VIAddVersionKey "LegalCopyright" "Sonic Scout contributors"
!define MUI_ABORTWARNING
!define MUI_WELCOMEPAGE_TITLE "Install Sonic Scout"
!define MUI_WELCOMEPAGE_TEXT "This installs Sonic Scout and its audio setup wizard.$\r$\n$\r$\nAfter installation, choose your headphones or speakers in the app. Sonic Scout will guide audio component installation and configure Equalizer APO automatically.$\r$\n$\r$\nWindows may request permission to install audio drivers."
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "${LICENSE}"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!define MUI_FINISHPAGE_RUN "$INSTDIR\SonicScout.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Open Sonic Scout and complete audio setup"
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"
Function .onInit
 ${IfNot} ${IsNativeAMD64}
  MessageBox MB_ICONSTOP "Sonic Scout requires Windows x64."
  Abort
 ${EndIf}
 ${IfNot} ${AtLeastWin10}
  MessageBox MB_ICONSTOP "Sonic Scout requires Windows 10 or Windows 11."
  Abort
 ${EndIf}
 SetRegView 64
FunctionEnd
Section "Sonic Scout"
 SetShellVarContext all
 SetOutPath "$INSTDIR"
 File /r "${PAYLOAD}\*"
 WriteUninstaller "$INSTDIR\Uninstall.exe"
 CreateDirectory "$SMPROGRAMS\Sonic Scout"
 CreateShortcut "$SMPROGRAMS\Sonic Scout\Sonic Scout.lnk" "$INSTDIR\SonicScout.exe"
 CreateShortcut "$SMPROGRAMS\Sonic Scout\Uninstall.lnk" "$INSTDIR\Uninstall.exe"
 CreateShortcut "$DESKTOP\Sonic Scout.lnk" "$INSTDIR\SonicScout.exe"
 WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\SonicScout" "DisplayName" "Sonic Scout"
 WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\SonicScout" "DisplayVersion" "2.9.0 development"
 WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\SonicScout" "UninstallString" '"$INSTDIR\Uninstall.exe"'
 WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\SonicScout" "DisplayIcon" "$INSTDIR\SonicScout.exe"
 WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\SonicScout" "InstallLocation" "$INSTDIR"
 WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\SonicScout" "NoModify" 1
 WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\SonicScout" "NoRepair" 1
SectionEnd
Section "Uninstall"
 SetRegView 64
 SetShellVarContext all
 !include "${UNINSTALL_MANIFEST}"
 Delete "$INSTDIR\Uninstall.exe"
 Delete "$DESKTOP\Sonic Scout.lnk"
 Delete "$SMPROGRAMS\Sonic Scout\Sonic Scout.lnk"
 Delete "$SMPROGRAMS\Sonic Scout\Uninstall.lnk"
 RMDir "$SMPROGRAMS\Sonic Scout"
 RMDir "$INSTDIR"
 DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\SonicScout"
SectionEnd
