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
!insertmacro MUI_PAGE_LICENSE "${PAYLOAD}\ThirdPartyNotices.txt"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!define MUI_FINISHPAGE_RUN
!define MUI_FINISHPAGE_RUN_FUNCTION LaunchSonicScoutAsUser
!define MUI_FINISHPAGE_RUN_TEXT "Open Sonic Scout and complete audio setup"
!insertmacro MUI_PAGE_FINISH
!define MUI_UNCONFIRMPAGE_TEXT_TOP "This removes the Sonic Scout application and shortcuts. Your profiles and shared Equalizer APO / VB-Cable components remain.$\r$\n$\r$\nBefore uninstalling, select your physical headphones or speakers in any game routed through Sonic Scout."
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"
; The installer is elevated; launching the app directly would make it run as admin.
; Explorer starts it with the signed-in user's normal (non-admin) token.
Function LaunchSonicScoutAsUser
 Exec '"$WINDIR\explorer.exe" "$INSTDIR\SonicScout.exe"'
FunctionEnd
; Sonic Scout now starts with Windows, so it is normally running during an upgrade. Locked
; files would otherwise be skipped silently, leaving a mixed old/new install. Close the app
; and its SonicPass relay first; $R9 = 1 when the app was running (relaunched afterwards).
!macro CloseSonicScout
 StrCpy $R9 0
 nsExec::ExecToStack '"$SYSDIR\tasklist.exe" /FI "IMAGENAME eq SonicScout.exe" /NH'
 Pop $0
 Pop $1
 StrCpy $2 $1 1024
 Push $2
 Push "SonicScout.exe"
 Call StrContains
 Pop $3
 ${If} $3 != ""
  StrCpy $R9 1
 ${EndIf}
 nsExec::Exec '"$SYSDIR\taskkill.exe" /F /T /IM SonicScout.exe'
 nsExec::Exec '"$SYSDIR\taskkill.exe" /F /IM SonicScout.SonicPass.exe'
 Sleep 1500
!macroend
; Push haystack, push needle, Call StrContains, Pop result ("" when not found).
Function StrContains
 Exch $R1
 Exch
 Exch $R2
 Push $R3
 Push $R4
 Push $R5
 StrLen $R3 $R1
 StrCpy $R4 0
 loop:
  StrCpy $R5 $R2 $R3 $R4
  StrCmp $R5 $R1 found
  StrCmp $R5 "" notfound
  IntOp $R4 $R4 + 1
  Goto loop
 found:
  StrCpy $R1 $R1
  Goto done
 notfound:
  StrCpy $R1 ""
 done:
 Pop $R5
 Pop $R4
 Pop $R3
 Pop $R2
 Exch $R1
FunctionEnd
Function un.CloseSonicScout
 nsExec::Exec '"$SYSDIR\taskkill.exe" /F /T /IM SonicScout.exe'
 nsExec::Exec '"$SYSDIR\taskkill.exe" /F /IM SonicScout.SonicPass.exe'
 Sleep 1500
FunctionEnd
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
 !insertmacro CloseSonicScout
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
 ; Silent upgrade of a running copy: bring it back (non-elevated) so audio routing resumes.
 ${If} ${Silent}
 ${AndIf} $R9 == 1
  Call LaunchSonicScoutAsUser
 ${EndIf}
SectionEnd
Section "Uninstall"
 SetRegView 64
 SetShellVarContext all
 Call un.CloseSonicScout
 !include "${UNINSTALL_MANIFEST}"
 Delete "$INSTDIR\Uninstall.exe"
 Delete "$DESKTOP\Sonic Scout.lnk"
 Delete "$SMPROGRAMS\Sonic Scout\Sonic Scout.lnk"
 Delete "$SMPROGRAMS\Sonic Scout\Uninstall.lnk"
 RMDir "$SMPROGRAMS\Sonic Scout"
 RMDir "$INSTDIR"
 DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\SonicScout"
 ; Per-user "start with Windows" entry written by the app (tray menu: Start with Windows).
 DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "SonicScout"
SectionEnd
