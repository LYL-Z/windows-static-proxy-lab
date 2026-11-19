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
if ($null -ne $s.proxyEnabled -and $null -ne $s.uiEnabled -and [bool]$s.proxyEnabled -ne [bool]$s.uiEnabled) { $issues.Add('UI and HKCU system-proxy state differ') }
$target = if ($s.PSObject.Properties['proxyTargetsMixedPort']) { $s.proxyTargetsMixedPort }
    else { Test-ProxyDoctorTarget -Server $s.proxyServer -Port $s.mixedPort }
if ([bool]$s.proxyEnabled -and $target -eq $false) { $issues.Add('Windows manual HTTP(S) proxy points away from the expected mixed port') }
if ($s.proxyEnabled -eq $true -and $s.mixedPortOpen -eq $false) { $issues.Add('system proxy is on but mixed port is closed') }
if ($s.processRunning -eq $false) { $issues.Add('proxy client process is not running') }
if ($s.proxyEnabled -eq $true -and $s.mixedPortOpen -eq $true -and $s.mixedIPv4CoreOwned -eq $false) { $issues.Add('the expected core does not own an IPv4 listener on the mixed port') }
if ($s.proxyEnabled -eq $true -and $s.firstHopOpen -eq $false) { $issues.Add('system proxy is on but first hop is closed') }
$firstHopMeasured = $s.firstHopPort -eq 0 -or $null -ne $s.firstHopOpen
$coreMeasured = -not $s.PSObject.Properties['mixedIPv4CoreOwned'] -or $null -ne $s.mixedIPv4CoreOwned
$verified = ($null -ne $s.proxyEnabled -and $null -ne $s.uiEnabled -and -not $s.pacConfigured -and
    $null -ne $s.processRunning -and $null -ne $s.mixedPortOpen -and $coreMeasured -and
    ($s.proxyEnabled -eq $false -or ($null -ne $target -and $firstHopMeasured)))
$consistent = if ($issues.Count -gt 0) { $false } elseif ($verified) { $true } else { $null }
$out = [ordered]@{ consistent = $consistent; issues = @($issues); state = [string]$s.state }
if ($Json) { $out | ConvertTo-Json -Depth 4 } else { Write-Host ('CONSISTENT=' + $consistent); $issues | ForEach-Object { Write-Host ('  - ' + $_) } }
if ($null -eq $consistent) { exit 3 }
if (-not $consistent) { exit 2 }
exit 0
