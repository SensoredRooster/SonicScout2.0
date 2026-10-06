function Get-SonicScout20Endpoints { [pscustomobject]@{Render8='fake8';Render16='fake16';Capture='fakecapture'} }
function Test-VoicemeeterEdition { [pscustomobject]@{Standard=$false;PaidPresent=$false} }
function Set-SonicScout20Endpoints { param($IconBaseUrl,$IncludeVoicemeeter) Write-Host 'HARNESS: endpoint mutation invoked during Preflight'; [pscustomobject]@{Render8='fake8';Render16='fake16';Capture='fakecapture'} }
function Write-InitialConfig { param($RenderGuid8,$RenderGuid16) Write-Host 'HARNESS: config overwrite invoked during Preflight' }
