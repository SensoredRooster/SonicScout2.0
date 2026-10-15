Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
$root=[Windows.Automation.AutomationElement]::RootElement
$p=Get-Process SonicScout -EA SilentlyContinue | Select -First 1
$c=New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ProcessIdProperty,$p.Id)
$out=foreach($w in $root.FindAll('Children',$c)){ "WINDOW: "+$w.Current.Name; foreach($e in $w.FindAll('Descendants',[Windows.Automation.Condition]::TrueCondition)){ $n=$e.Current.Name; if($n){ "  ["+$e.Current.ControlType.ProgrammaticName+"] "+$n+" enabled="+$e.Current.IsEnabled } } }
$out | Set-Content C:\QA\out\uia.txt
