param($Mode,$WaveLinkRouting,$VoicemeeterFallback,[switch]$Quiet,[switch]$NonInteractive,[switch]$OwnershipAccepted)
if($env:COMPUTERNAME -ne 'SONICSCOUT-QA'){throw 'Guest-only QA fixture'}
Start-Process notepad.exe
Start-Sleep -Seconds 2
Set-Content C:\QA\elevation-worker-complete.txt 'Worker exited while its Notepad descendant stays open.'
exit 23
