param(
 [Parameter(Mandatory)][string]$CompilerPath,
 [Parameter(Mandatory)][string]$OutputDirectory,
 [string]$PayloadDirectory,
 [string]$ArchiveToolDirectory = "$env:ProgramFiles\7-Zip",
 [switch]$Sign,
 [string]$SignToolPath,
 [string]$DlibPath,
 [string]$SigningMetadataPath
)
$ErrorActionPreference='Stop'
# Optional Azure Artifact Signing. Enable with -Sign or SONICSCOUT_SIGN=1. Unsigned builds are unchanged.
if($env:SONICSCOUT_SIGN -in @('1','true','yes')){$Sign=$true}
function Find-SignTool {
 if($SignToolPath){return $SignToolPath}
 if($env:SONICSCOUT_SIGNTOOL){return $env:SONICSCOUT_SIGNTOOL}
 $c=@(Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe","$env:LOCALAPPDATA\Microsoft\MicrosoftArtifactSigningClientTools\signtool.exe","$env:LOCALAPPDATA\Microsoft\MicrosoftTrustedSigningClientTools\signtool.exe" -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)
 if(-not $c){throw 'signtool.exe (x64, Windows SDK 10.0.22621+) not found. Pass -SignToolPath or set SONICSCOUT_SIGNTOOL.'}
 $c[0].FullName
}
function Find-Dlib {
 if($DlibPath){return $DlibPath}
 if($env:SONICSCOUT_SIGN_DLIB){return $env:SONICSCOUT_SIGN_DLIB}
 $roots=@("$env:LOCALAPPDATA\Microsoft\MicrosoftArtifactSigningClientTools","$env:LOCALAPPDATA\Microsoft\MicrosoftTrustedSigningClientTools","$env:USERPROFILE\.nuget\packages\microsoft.artifactsigning.client","$env:USERPROFILE\.nuget\packages\microsoft.trusted.signing.client")
 $c=@(Get-ChildItem $roots -Recurse -Filter Azure.CodeSigning.Dlib.dll -ErrorAction SilentlyContinue | Sort-Object {$_.FullName -notmatch 'x64'})
 if(-not $c){throw 'Azure.CodeSigning.Dlib.dll not found. Install Microsoft.Azure.ArtifactSigningClientTools or pass -DlibPath.'}
 $c[0].FullName
}
function Invoke-Sign([string[]]$Files){
 if(-not $Sign -or -not $Files){return}
 & $script:signtool sign /v /fd SHA256 /tr http://timestamp.acs.microsoft.com /td SHA256 /dlib $script:dlib /dmdf $script:metadata @Files
 if($LASTEXITCODE -ne 0){throw 'Code signing failed. Run az login with an account holding the Artifact Signing Certificate Profile Signer role.'}
 & $script:signtool verify /pa /v @Files
 if($LASTEXITCODE -ne 0){throw 'Signature verification failed.'}
}
if($Sign){
 $script:signtool=Find-SignTool
 $script:dlib=Find-Dlib
 $script:metadata=if($SigningMetadataPath){$SigningMetadataPath}else{Join-Path $PSScriptRoot 'signing\metadata.json'}
 if(-not(Test-Path $script:metadata)){throw "Signing metadata not found: $script:metadata"}
}
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$output=[IO.Path]::GetFullPath($OutputDirectory)
New-Item $output -ItemType Directory -Force | Out-Null
if(-not $PayloadDirectory){
 $PayloadDirectory=Join-Path $output ('payload-'+[guid]::NewGuid().ToString('N'))
 & (Join-Path $repo 'tools\SonicScoutCSharp\publish_sonic_scout.ps1') -OutputPath $PayloadDirectory
 if($LASTEXITCODE -ne 0){throw 'Application publish failed.'}
}
$payload=[IO.Path]::GetFullPath($PayloadDirectory)
$archiveDestination=Join-Path $payload 'tools\archive'
New-Item $archiveDestination -ItemType Directory -Force | Out-Null
foreach($archiveFile in @('7z.exe','7z.dll','License.txt')) {
 $source=Join-Path $ArchiveToolDirectory $archiveFile
 if(-not(Test-Path $source)){throw 'Supply -ArchiveToolDirectory containing the official unmodified 7-Zip 7z.exe, 7z.dll and License.txt. No user installation is needed.'}
 Copy-Item -LiteralPath $source -Destination $archiveDestination -Force
}
# Sign only binaries we build (SonicScout*.exe/.dll); third-party tools keep their vendor signatures.
Invoke-Sign @(Get-ChildItem $payload -Recurse -File -Include 'SonicScout*.exe','SonicScout*.dll' | Where-Object {$_.FullName -notmatch '\\tools\\archive\\'} | ForEach-Object FullName)
Copy-Item -LiteralPath (Join-Path $repo 'tools\packaging\ThirdPartyNotices.txt') -Destination $payload -Force
Copy-Item -LiteralPath (Join-Path $repo 'LICENSE') -Destination (Join-Path $payload 'LICENSE') -Force
foreach($name in @('SonicScout.exe','SonicScout.SonicPass.exe','setup_audio_stack.ps1','apo_automation.ps1','LEQ-Engine.ps1')){
 if(-not(Test-Path (Join-Path $payload $name))){throw "Incomplete application payload: $name"}
}
# Delete only installed payload files; never recursively remove a user-selected folder.
$manifest=Join-Path $output 'uninstall-files.nsh'
$lines=@(Get-ChildItem $payload -Recurse -File | ForEach-Object {
 $relative=$_.FullName.Substring($payload.Length).TrimStart('\').Replace('$','$$')
 'Delete "$INSTDIR\'+$relative+'"'
})
$lines+=@(Get-ChildItem $payload -Recurse -Directory | Sort-Object {$_.FullName.Length} -Descending | ForEach-Object {
 'RMDir "$INSTDIR\'+$_.FullName.Substring($payload.Length).TrimStart('\').Replace('$','$$')+'"'
})
Set-Content $manifest $lines -Encoding UTF8
& $CompilerPath "/DPAYLOAD=$payload" "/DOUTPUT=$output" "/DLICENSE=$(Join-Path $repo 'LICENSE')" "/DUNINSTALL_MANIFEST=$manifest" (Join-Path $PSScriptRoot 'SonicScout.nsi')
if($LASTEXITCODE -ne 0){throw 'Windows installer compilation failed.'}
$setup=Join-Path $output 'SonicScout-Setup.exe'
Invoke-Sign @($setup)
Get-Item $setup
