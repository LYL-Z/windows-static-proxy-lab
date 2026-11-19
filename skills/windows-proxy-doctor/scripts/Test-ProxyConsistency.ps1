#Requires -Version 5.1
<#
Read-only consistency check. Accepts a snapshot JSON (synthetic or captured)
and reports whether OS proxy, UI, listener and process agree.
#>
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$SnapshotFile, [switch]$Json)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProxyTarget.ps1')
if (-not (Test-Path -LiteralPath $SnapshotFile)) { Write-Error 'snapshot file not found'; exit 3 }
$s = Get-Content -LiteralPath $SnapshotFile -Raw | ConvertFrom-Json
$issues = New-Object System.Collections.Generic.List[string]
if ($null -ne $s.uiEnabled -and [bool]$s.proxyEnabled -ne [bool]$s.uiEnabled) { $issues.Add('UI and HKCU system-proxy state differ') }
$target = if ($s.PSObject.Properties['proxyTargetsMixedPort']) { $s.proxyTargetsMixedPort }
    else { Test-ProxyDoctorTarget -Server $s.proxyServer -Port $s.mixedPort }
if ([bool]$s.proxyEnabled -and $target -eq $false) { $issues.Add('Windows manual HTTP(S) proxy points away from the expected mixed port') }
if ([bool]$s.proxyEnabled -and -not [bool]$s.mixedPortOpen) { $issues.Add('system proxy is on but mixed port is closed') }
if (-not [bool]$s.processRunning) { $issues.Add('proxy client process is not running') }
if ([bool]$s.mixedPortOpen -and -not [bool]$s.processRunning) { $issues.Add('mixed port is open but no known proxy process') }
if ([bool]$s.proxyEnabled -and -not [bool]$s.firstHopOpen) { $issues.Add('system proxy is on but first hop is closed') }
$verified = ($null -ne $s.uiEnabled -and (-not [bool]$s.proxyEnabled -or $null -ne $target))
$consistent = if ($issues.Count -gt 0) { $false } elseif ($verified) { $true } else { $null }
$out = [ordered]@{ consistent = $consistent; issues = @($issues); state = [string]$s.state }
if ($Json) { $out | ConvertTo-Json -Depth 4 } else { Write-Host ('CONSISTENT=' + $consistent); $issues | ForEach-Object { Write-Host ('  - ' + $_) } }
if ($null -eq $consistent) { exit 3 }
if (-not $consistent) { exit 2 }
exit 0
