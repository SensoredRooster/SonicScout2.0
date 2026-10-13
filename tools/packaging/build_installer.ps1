param(
 [Parameter(Mandatory)][string]$CompilerPath,
 [Parameter(Mandatory)][string]$OutputDirectory,
 [string]$PayloadDirectory
)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$output=[IO.Path]::GetFullPath($OutputDirectory)
New-Item $output -ItemType Directory -Force | Out-Null
if(-not $PayloadDirectory){
 $PayloadDirectory=Join-Path $output ('payload-'+[guid]::NewGuid().ToString('N'))
 & (Join-Path $repo 'tools\SonicScoutCSharp\publish_sonic_scout.ps1') -OutputPath $PayloadDirectory
 if($LASTEXITCODE -ne 0){throw 'Application publish failed.'}
}
$payload=[IO.Path]::GetFullPath($PayloadDirectory)
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
Get-Item (Join-Path $output 'SonicScout-Setup.exe')
