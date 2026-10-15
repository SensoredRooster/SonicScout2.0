# Exercise Sonic Scout like a first-time user (QA VM, non-elevated, interactive session).
param([string]$Out='C:\QA\out')
Start-Transcript (Join-Path $Out 'user.txt') -Force | Out-Null
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
$root=[Windows.Automation.AutomationElement]::RootElement
$TrueCond=[Windows.Automation.Condition]::TrueCondition
function AppWins{ $p=Get-Process SonicScout -EA SilentlyContinue | Select -First 1; if(-not $p){return @()}; $c=New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ProcessIdProperty,$p.Id); @($root.FindAll('Children',$c)) }
function All{ foreach($w in AppWins){ $w; foreach($e in $w.FindAll('Descendants',$TrueCond)){ $e } } }
function ById($id,$t=20){ $d=(Get-Date).AddSeconds($t); while((Get-Date) -lt $d){ $e=All | ? { $_.Current.AutomationId -eq $id } | Select -First 1; if($e){return $e}; Start-Sleep 1 }; $null }
function BtnByName($pat,$t=20){ $d=(Get-Date).AddSeconds($t); while((Get-Date) -lt $d){ $e=All | ? { $_.Current.ControlType -eq [Windows.Automation.ControlType]::Button -and $_.Current.Name -like $pat } | Select -First 1; if($e){return $e}; Start-Sleep 1 }; $null }
function Click($e){ if(-not $e){ "  !! element missing"; return $false }; try{ $e.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke(); $true } catch { "  !! invoke failed: $($_.Exception.Message)"; $false } }
function DumpWins($tag){ "--- windows ($tag):"; foreach($w in AppWins){ "  WINDOW: $($w.Current.Name)" } }
function SetText($id,$v){ $e=ById $id 10; if($e){ $e.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($v); "  set $id=$v" } else { "  !! $id missing" } }
function Status{ $f="$env:LOCALAPPDATA\SonicScout\logs\eq-status.json"; if(Test-Path $f){ ([string](Get-Content $f -Raw) | ConvertFrom-Json).status } }
function FileInfo($p){ if(Test-Path $p){ $i=Get-Item $p; "$($i.LastWriteTime.ToString('HH:mm:ss')) len=$($i.Length) hash=$((Get-FileHash $p).Hash.Substring(0,12))" } else { '<missing>' } }
$inc="$env:LOCALAPPDATA\SonicScout\eapo\sonicscout.txt"
$res=[ordered]@{}
"== 0 start"; if(-not (Get-Process SonicScout -EA SilentlyContinue)){ Start-Process 'C:\Program Files\SonicScout\SonicScout.exe'; Start-Sleep 60 }
DumpWins 'start'
# close a leftover setup dialog like a user would
$done=ById 'DoneButton' 5; if($done){ "close setup dialog: $(Click $done)"; Start-Sleep 5 }
"include before: $(FileInfo $inc)"; $incLine=[string](Get-Content $inc -Raw -EA SilentlyContinue); "include content: $incLine"
$target = if($incLine -match 'Include:\s*(.+)'){ $Matches[1].Trim() } else { $null }; "include target: $target -> $(if($target){FileInfo $target})"
$before1=FileInfo $inc; $before2= if($target){FileInfo $target}
"== 1 create game profile"
Click (ById 'NewProfileButton' 30) | Out-Null; Start-Sleep 8; DumpWins 'after PROFILES +'
$st=ById 'StatusText' 20; for($i=0;$i -lt 90 -and $st -and $st.Current.Name -match 'Loading';$i++){ Start-Sleep 2 }; "catalog status: $($st.Current.Name)"
$sb=ById 'SearchBox' 5; if($sb){ $sb.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue('HD 600'); Start-Sleep 6 }
$lb=ById 'ProfileListBox' 10; $items=@(); if($lb){ $items=@($lb.FindAll('Children',$TrueCond)) }; "catalog items shown: $($items.Count)"
if($items.Count){ "pick: $(($items[0].FindAll('Descendants',$TrueCond) | % { $_.Current.Name } | ? { $_ }) -join ' / ')"; $items[0].GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select(); Start-Sleep 2 }
$tc=ById 'TargetCurveComboBox' 5; if($tc){ try{ $tc.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand(); Start-Sleep 2; $opts=@($tc.FindAll('Descendants',(New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::ListItem)))); "game targets: $(($opts | % { $_.Current.Name }) -join ' | ')"; $pick=$opts | ? { $_.Current.Name -match 'Valorant|FPS|Competitive|Footstep' } | Select -First 1; if(-not $pick -and $opts.Count -gt 1){$pick=$opts[1]}; if($pick){ $pick.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select(); "game target: $($pick.Current.Name)" }; $tc.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Collapse() } catch { "  !! target combo: $($_.Exception.Message)" } }
"selected item: $(($lb.GetCurrentPattern([Windows.Automation.SelectionPattern]::Pattern).Current.GetSelection() | % { $_.Current.Name }) -join ',')"
"target selected: $(try{$tc.GetCurrentPattern([Windows.Automation.SelectionPattern]::Pattern).Current.GetSelection()[0].Current.Name}catch{'?'})"
Click (BtnByName 'USE PROFILE' 5) | Out-Null
for($i=0;$i -lt 36;$i++){ Start-Sleep 5; $sbx=All | ? { $_.Current.AutomationId -eq 'SearchBox' } | Select -First 1; $stx=All | ? { $_.Current.AutomationId -eq 'StatusText' } | Select -First 1; "  t+$(5*($i+1))s picker=$([bool]$sbx) status: $($stx.Current.Name)"; if(-not $sbx){break} }
"message text: $((All | ? { $_.Current.AutomationId -eq 'MessageText' } | Select -First 1).Current.Name)"
"profiles dir: $((gci "$env:USERPROFILE\Documents\HAudioApp" -Recurse -File | % Name) -join ', ')"
DumpWins 'after USE PROFILE'
# ProfileStackPanel is a StackPanel (no UIA peer), so find tile buttons by their text instead.
$pdir="$env:LOCALAPPDATA\SonicScout\profiles"; $pfiles=@(gci $pdir -File -EA 0 | ? Name -match 'HD.?600'); "profile files ($pdir): $(($pfiles | % Name) -join ', ')"
$pbtns=@(); $dl=(Get-Date).AddSeconds(20); while(-not $pbtns.Count -and (Get-Date) -lt $dl){ $pbtns=@(All | ? { $_.Current.ControlType -eq [Windows.Automation.ControlType]::Button -and (($_.FindAll('Descendants',$TrueCond) | % { $_.Current.Name }) -join ' ') -match 'HD 600' }); if(-not $pbtns.Count){Start-Sleep 2} }
"profile buttons: $(($pbtns | % { ($_.FindAll('Descendants',$TrueCond) | % { $_.Current.Name } | ? { $_ }) -join ' / ' }) -join ' | ')"
$prof = $pbtns | Select -First 1
DumpWins 'after create'
"profile button: $(if($prof){$prof.Current.Name}else{'<none>'})"; if($prof){ Click $prof | Out-Null; Start-Sleep 6 }
"active profile text: $((ById 'ActiveProfileText' 5).Current.Name)"
$res.profileCreated = [bool]$prof -and $pfiles.Count -gt 0
"== 2 game device"
foreach($id in 'SonicPassInputComboBox','SonicPassOutputComboBox','OutputDeviceComboBox'){ $c=ById $id 5; $v=''; try{ $v=($c.GetCurrentPattern([Windows.Automation.SelectionPattern]::Pattern).Current.GetSelection() | % { $_.Current.Name }) -join ',' }catch{}; "  $id = $v" }
"== 3 tone + status"
$job=Start-Job { & C:\QA\SonicScout.E2EProbe.exe --game 'SonicScout2.0' --output 'Speakers' --seconds 20 }
for($i=0;$i -lt 60 -and -not (Get-Process SonicScout.E2EProbe -EA SilentlyContinue);$i++){ Start-Sleep 1 }
$seen=@(); while($job.State -eq 'Running'){ Start-Sleep 1; $seen+=Status }
$probe=(Receive-Job $job -Wait -AutoRemoveJob) -join ''; "probe: $probe"; "statuses: $(($seen | Select -Unique) -join ',')"
$res.running = ($seen -contains 'RUNNING'); $res.tone = ($probe -match '"ok":true')
"== 4 change EQ"
$sl = @(All | ? { $_.Current.ControlType -eq [Windows.Automation.ControlType]::Slider })
"sliders: $($sl.Count)"
if($sl.Count){ $rv=$sl[0].GetCurrentPattern([Windows.Automation.RangeValuePattern]::Pattern); "slider0 $($rv.Current.Value) [$($rv.Current.Minimum),$($rv.Current.Maximum)]"; $nv=[Math]::Min($rv.Current.Maximum,$rv.Current.Value+3); if($nv -eq $rv.Current.Value){$nv=$rv.Current.Value-3}; try{ $rv.SetValue($nv); "  set -> $nv" }catch{ "  !! set failed $($_.Exception.Message)" } }
Start-Sleep 8
$after1=FileInfo $inc; $after2= if($target){FileInfo $target}
"include after: $after1 (before $before1)"; "target after: $after2 (before $before2)"
$res.eqWritten = ($after1 -ne $before1) -or ($after2 -ne $before2)
"== 5 diagnostics window"
Click (BtnByName 'DIAGNOSTICS') | Out-Null; Start-Sleep 10; DumpWins 'after diagnostics'
$diag=ById 'DiagnosticsText' 15; $sess=ById 'SessionText' 3
"session: $($sess.Current.Name)"; $dt= if($diag){ try{$diag.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value}catch{$diag.Current.Name} }; "diagnostics (first 1500): $(([string]$dt).Substring(0,[Math]::Min(1500,([string]$dt).Length)))"
$res.diagnostics = [bool]$diag -and -not ([string]$dt -match 'Exception|failed')
foreach($w in AppWins){ if($w.Current.Name -match 'Support|Diagnos'){ $x=$w.FindAll('Descendants',$TrueCond) | ? { $_.Current.ControlType -eq [Windows.Automation.ControlType]::Button -and $_.Current.Name -match '^(x|CLOSE|Close)$' } | Select -First 1; "close support: $(Click $x)" } }
Start-Sleep 4; DumpWins 'after closing diagnostics'
"== 6 close and reopen"
$profBefore=(ById 'ActiveProfileText' 5).Current.Name
Click (ById 'CloseButton' 10) | Out-Null; Start-Sleep 15; DumpWins 'after close'; "running after close: $([bool](Get-Process SonicScout -EA SilentlyContinue))"
Get-Process SonicScout -EA SilentlyContinue | Stop-Process -Force
Start-Process 'C:\Program Files\SonicScout\SonicScout.exe'; Start-Sleep 90; DumpWins 'reopened'
$profAfter=(ById 'ActiveProfileText' 30).Current.Name; "active profile before/after reopen: $profBefore / $profAfter"
$res.reopen = [bool](Get-Process SonicScout -EA SilentlyContinue) -and ($profAfter -eq $profBefore)
"status after reopen: $(Status)"
"== 7 errors"
$l="$env:LOCALAPPDATA\SonicScout\logs"; $crash= if(Test-Path "$l\wizard-crash.log"){ Get-Content "$l\wizard-crash.log" -Tail 20 }; "crash log: $crash"
$errs=Get-Content "$l\sonic-scout.jsonl" | Select-String '"level":"ERROR"|"error":true' | Select -Last 10 | % Line; "error events:"; $errs
$res.noCrash = -not $crash
$res.GetEnumerator() | % { "RESULT $($_.Key)=$($_.Value)" }
$res | ConvertTo-Json | Set-Content (Join-Path $Out 'user.json')
Stop-Transcript | Out-Null






