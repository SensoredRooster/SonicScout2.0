# SonicScout automatic cable APO registration. Uses the installed Equalizer APO
# LFX/GFX classes and the project's existing LEQ engine. Never targets hardware.
function Get-SonicScoutApoTargets {
    $root = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render'
    foreach ($key in @(Get-ChildItem $root -ErrorAction SilentlyContinue)) {
        $props = Get-ItemProperty (Join-Path $key.PSPath 'Properties') -ErrorAction SilentlyContinue
        if ($null -eq $props) { continue }
        $nameProperty = $props.PSObject.Properties['{a45c254e-df1c-4efd-8020-67d146a850e0},2']
        $driverProperty = $props.PSObject.Properties['{b3f8fa53-0004-438e-9003-51a46e139bfc},6']
        if ($null -eq $nameProperty -or $null -eq $driverProperty) { continue }
        $name = [string]$nameProperty.Value
        $driver = [string]$driverProperty.Value
        if ($name -match '^SonicScout2\.0(?: \+)?$|^CABLE (?:Input|In 16ch)(?:\s|\(|$)|^Hi-Fi Cable Input(?:\s|\(|$)' -and
            $driver -match 'VB-Audio (?:Virtual|Hi-Fi) Cable') {
            [pscustomobject]@{ Guid=$key.PSChildName; Name=$name; Path=(Join-Path $root $key.PSChildName); Is16=($name -match '\+|16ch') }
        }
    }
}

function Set-SonicScoutApoSlots {
    param([Parameter(Mandatory)]$Target, [switch]$ChainLeq)
    $fx = Join-Path $Target.Path 'FxProperties'
    if (-not (Test-Path $fx)) { New-Item $fx -Force | Out-Null }
    $children = "HKLM:\SOFTWARE\EqualizerAPO\Child APOs\$($Target.Guid)"
    $pre = '{EACD2258-FCAC-4FF4-B36D-419E924A6D79}'
    $post = '{EC1CC9CE-FAED-4822-828A-82A81A6F018F}'
    foreach ($clsid in @($pre,$post)) {
        $server = Get-Item "HKLM:\SOFTWARE\Classes\CLSID\$clsid\InprocServer32" -ErrorAction Stop
        $dll = ([string]$server.GetValue('')).Trim('"')
        if ([IO.Path]::GetFileName($dll) -ine 'EqualizerAPO.dll' -or -not (Test-Path $dll)) {
            throw 'The installed Equalizer APO classes are invalid. Repair Equalizer APO and retry.'
        }
    }
    $base='{d04e05a6-594b-4fb6-a80d-01af5eed7d1d}'
    # Keep upstream uninstall metadata. Never replace an already saved original.
    if (-not (Test-Path $children)) {
        New-Item $children -Force | Out-Null
        $old=Get-ItemProperty $fx
        foreach($slot in @(1,2,5,6,7)) {
            $value=$old.PSObject.Properties["$base,$slot"]
            $original=if($null -eq $value){'!VALUE'}elseif([string]$value.Value -in @($pre,$post)){'!VALUE'}else{[string]$value.Value}
            New-ItemProperty $children -Name "$base,$slot" -Value $original -PropertyType String -Force | Out-Null
        }
    }
    # The cable carries only the managed chain; no hardware/vendor effects chain.
    $preChild=if($ChainLeq){$script:LEQ_APO_GUID}else{''}
    $postChild=if($ChainLeq){$script:OTHER_APO_GUID}else{''}
    foreach($entry in @{PreMixChild=$preChild;PostMixChild=$postChild;Version='2';AllowSilentBufferModification='true';DisableAutomaticAdjustment='true'}.GetEnumerator()) {
        New-ItemProperty $children -Name $entry.Key -Value $entry.Value -PropertyType String -Force | Out-Null
    }
    $values=@(
        @{Name="$base,1";Type=[uint32]1;Data=[Text.Encoding]::Unicode.GetBytes($pre+[char]0)},
        @{Name="$base,2";Type=[uint32]1;Data=[Text.Encoding]::Unicode.GetBytes($post+[char]0)}
    )
    if (-not (Write-RegistryValues -Path $fx -Values $values)) { throw "Could not register APO for $($Target.Name)." }
    $subkey=($fx -replace '^Microsoft.PowerShell.Core\\Registry::HKEY_LOCAL_MACHINE\\','' -replace '^HKLM:\\','')
    # Remove competing slots on this cable only; all originals are backed up.
    foreach($slot in @(5,6,7,13,14,15)) { [AIWRegHelper]::DeleteValue($subkey,"$base,$slot") | Out-Null }
    [AIWRegHelper]::DeleteValue($subkey,'{1da5d803-d492-4edd-8c23-e0c0ffee7f0e},5') | Out-Null
    $actual=Get-ItemProperty $fx
    if ($actual."$base,1" -ine $pre -or $actual."$base,2" -ine $post) { throw "APO slot verification failed for $($Target.Name)." }
    $removedNames = @(5,6,7,13,14,15 | ForEach-Object { "$base,$_" }) + @('{1da5d803-d492-4edd-8c23-e0c0ffee7f0e},5')
    foreach ($name in $removedNames) {
        if ($null -ne $actual.PSObject.Properties[$name]) { throw "Competing or disabled audio effects remain on $($Target.Name). Retry setup to repair them." }
    }
}

function Get-SonicScoutRegistrySnapshot {
    param([string]$Path)
    $exists=Test-Path $Path
    $values=@()
    if($exists){
        $key=Get-Item $Path
        foreach($name in $key.GetValueNames()){
            $value=$key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $kind=$key.GetValueKind($name)
            $data=switch($kind){
                'String' {[Text.Encoding]::Unicode.GetBytes([string]$value+[char]0)}
                'ExpandString' {[Text.Encoding]::Unicode.GetBytes([string]$value+[char]0)}
                'MultiString' {[Text.Encoding]::Unicode.GetBytes((([string[]]$value)-join [char]0)+[char]0+[char]0)}
                'DWord' {[BitConverter]::GetBytes([int]$value)}
                'QWord' {[BitConverter]::GetBytes([long]$value)}
                'Binary' {[byte[]]$value}
                default {throw "Unsupported registry value kind $kind; stopped before changing audio."}
            }
            $values+=@{Name=$name;Type=[uint32]$kind;Data=[byte[]]$data}
        }
    }
    [pscustomobject]@{Path=$Path;Exists=$exists;Values=$values}
}

function Restore-SonicScoutRegistrySnapshot {
    param($Snapshot)
    $path=$Snapshot.Path
    if($path -notmatch '^HKLM:\\SOFTWARE\\(?:Microsoft\\Windows\\CurrentVersion\\MMDevices\\Audio\\Render\\\{[0-9a-f-]+\}\\(?:FxProperties|Properties)|EqualizerAPO\\Child APOs\\\{[0-9a-f-]+\})$') {throw 'Refused an unexpected audio rollback path.'}
    if(-not(Test-Path $path)){New-Item $path -Force -ErrorAction Stop | Out-Null}
    $subkey=$path -replace '^HKLM:\\',''
    $originalNames=@($Snapshot.Values | ForEach-Object {$_.Name})
    foreach($name in (Get-Item $path).GetValueNames()){
        if($name -notin $originalNames){[AIWRegHelper]::DeleteValue($subkey,$name) | Out-Null}
    }
    if($Snapshot.Values.Count -gt 0 -and -not(Write-RegistryValues -Path $path -Values $Snapshot.Values)){throw "Audio rollback could not restore $path"}
    if(-not $Snapshot.Exists -and $path -like '*\Child APOs\*'){Remove-Item -LiteralPath $path -ErrorAction Stop}
}

function Install-SonicScoutAutomaticApo {
    $engine=Join-Path $PSScriptRoot 'LEQ-Engine.ps1'
    if (-not (Test-Path $engine)) { throw 'The audio setup package is incomplete: LEQ engine is missing.' }
    # Isolate the LEQ engine's strict mode and script variables from setup.
    & {
        . $engine
        Initialize-RegHelper
        $targets=@(Get-SonicScoutApoTargets)
        if ($targets.Count -eq 0) { throw 'No SonicScout cable playback endpoints were found.' }
        $backup=Join-Path $env:LOCALAPPDATA ('SonicScout\backups\apo-'+(Get-Date -Format yyyyMMdd-HHmmss))
        New-Item $backup -ItemType Directory -Force | Out-Null
        foreach($target in $targets) {
            $regPath='HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render\'+$target.Guid
            & reg.exe export $regPath (Join-Path $backup ($target.Guid+'.reg')) /y | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Could not back up audio settings; setup stopped before making changes.' }
        }
        $snapshots=@(foreach($target in $targets){
            Get-SonicScoutRegistrySnapshot (Join-Path $target.Path 'FxProperties')
            Get-SonicScoutRegistrySnapshot (Join-Path $target.Path 'Properties')
            Get-SonicScoutRegistrySnapshot "HKLM:\SOFTWARE\EqualizerAPO\Child APOs\$($target.Guid)"
        })
        $snapshots | Export-Clixml (Join-Path $backup 'rollback-snapshots.xml')
        try {
        Write-Stage 'Equalizer APO registration' 'RUNNING' 'Registering LFX/GFX processing on the SonicScout cable.'
        foreach($target in $targets) { Set-SonicScoutApoSlots $target }
        Restart-Service Audiosrv -Force -ErrorAction Stop
        Write-Stage 'Equalizer APO registration' 'READY' 'Cable LFX/GFX slots registered and verified.'
        Write-Stage 'Loudness equalization' 'RUNNING' 'Configuring the 8-channel cable; the 16-channel path stays separate.'
        foreach($target in $targets) {
            if (-not $target.Is16) {
                $result=@(Install-LEQRegistry -Device ([pscustomobject]@{Guid=$target.Guid;Name=$target.Name}) -ReleaseTime 4 -Force)
                if ($result[-1] -ne $true) { throw ("Loudness setup failed for $($target.Name). " + (($result | Select-Object -Last 6) -join ' ')) }
            }
        }
        Restart-Service Audiosrv -Force -ErrorAction Stop
        Write-Stage 'Loudness equalization' 'READY' 'Loudness configuration applied.'
        Write-Stage 'Audio configuration verification' 'RUNNING' 'Finalizing APO registration and restarting Windows audio.'
        foreach($target in $targets) { Set-SonicScoutApoSlots $target -ChainLeq:(-not $target.Is16) }
        Restart-Service Audiosrv -Force -ErrorAction Stop
        $privateHeSuvi=Join-Path $env:ProgramFiles 'EqualizerAPO\config\SonicScout2.0\HeSuVi'
        if(Test-Path (Join-Path $privateHeSuvi 'HeSuVi.exe')){
            $ids=(@($targets | Where-Object {-not $_.Is16} | ForEach-Object {$_.Guid.Trim('{}')})) -join ';'
            $init=Start-Process -FilePath (Join-Path $privateHeSuvi 'HeSuVi.exe') -WorkingDirectory $privateHeSuvi -ArgumentList @('-v','EAC_Default.wav','-l',$ids,'-d','0','-m','0') -WindowStyle Hidden -Wait -PassThru
            if($init.ExitCode -ne 0 -or -not(Test-Path (Join-Path $privateHeSuvi 'conv.txt'))){throw 'Private surround configuration failed.'}
        }
        $config=Join-Path $env:ProgramFiles 'EqualizerAPO\config\config.txt'
        $legacyProfile=Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'HAudioApp\active_profile.txt'
        if(Test-Path $config) {
            $lines=@(Get-Content $config)
            $updated=@($lines | Where-Object { $_.Trim() -ine "Include: $legacyProfile" })
            if($updated.Count -ne $lines.Count) {
                Copy-Item $config (Join-Path $backup 'config-before-profile-repair.txt')
                Set-Content $config $updated
            }
        }
        $managed=Join-Path $env:ProgramFiles 'EqualizerAPO\config\SonicScout2.0\active-config'
        if(Test-Path $managed) {
            $acl=Get-Acl $managed
            $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
            $rule=New-Object Security.AccessControl.FileSystemAccessRule($sid,'Modify','ContainerInherit,ObjectInherit','None','Allow')
            $acl.SetAccessRule($rule)
            Set-Acl $managed $acl
        }
        Write-Stage 'Audio configuration verification' 'READY' 'Automatic APO configuration completed; settings were backed up.'
        } catch {
            $failure=$_.Exception.Message
            try {
                foreach($snapshot in $snapshots){Restore-SonicScoutRegistrySnapshot $snapshot}
                $savedConfig=Join-Path $backup 'config-before-profile-repair.txt'
                if(Test-Path $savedConfig){Copy-Item $savedConfig (Join-Path $env:ProgramFiles 'EqualizerAPO\config\config.txt') -Force}
                Restart-Service Audiosrv -Force -ErrorAction Stop
                Write-Stage 'Audio rollback' 'READY' 'Prior cable effect values restored after a failed configuration. Audio setup can be retried.'
            } catch {
                Write-Stage 'Audio rollback' 'ERROR' "Automatic recovery failed. Backups are in $backup. $($_.Exception.Message)"
            }
            throw $failure
        }
    }
}
