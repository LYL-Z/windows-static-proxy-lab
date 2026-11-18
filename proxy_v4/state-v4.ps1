#Requires -Version 5.1
<#
.SYNOPSIS  Read-only state + integrity check for proxy_v4.
.DESCRIPTION
  Reports: five-state health, ownership, config integrity (marker + hash),
  first hop, real chain exit IP. Changes nothing.
  Exit: 0 HEALTHY/RECOVERING, 2 DEGRADED, 3 FAILED/UNKNOWN.
#>
[CmdletBinding()]
param([switch]$Json)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\V4.ps1')

$st = $null
$stateError = ''
try { $st = Get-V4State }
catch { $stateError = $_.Exception.Message }

if (-not $st) {
    $st = [ordered]@{
        state = 'FAILED'; mode = 'UNKNOWN'; reasons = @(('state probe failed: ' + $stateError))
        clashRunning = $false; mixedPort = $false; systemProxy = 'unknown'
        owner = 'unknown'; firstHopOk = $false; exitViaChain = $null
    }
}
$p = Get-V4Paths
$integrity = Get-V4Integrity -Paths $p

$result = [ordered]@{
    state = $st.state; mode = $st.mode; reasons = @($st.reasons)
    clashRunning = $st.clashRunning; mixedPort = $st.mixedPort
    systemProxy = $st.systemProxy; ownerRecorded = $st.owner
    firstHopOk = $st.firstHopOk; exitViaChain = $st.exitViaChain
    integrity = $integrity
}
if (-not $integrity.markerOk -and $integrity.profileExists) {
    $result.reasons += 'managed profile lost its marker (subscription/app overwrite?) - re-run apply-v4.ps1'
}
if (-not $integrity.markerOk -and $result.state -eq 'HEALTHY') { $result.state = 'DEGRADED' }

if ($Json) { $result | ConvertTo-Json -Depth 5 }
else {
    Write-Host ''
    Write-Host ('  STATE {0}   mode={1}' -f $result.state, $result.mode) -ForegroundColor $(
        switch ($result.state) { 'HEALTHY' {'Green'} 'DEGRADED' {'Yellow'} 'RECOVERING' {'Cyan'} default {'Red'} })
    Write-Host ('  ' + ('-'*60))
    'clashRunning   {0}' -f $result.clashRunning
    'mixedPort      {0}' -f $result.mixedPort
    'systemProxy    {0}   (owner record: {1})' -f $result.systemProxy, $result.ownerRecorded
    'firstHopOk     {0}' -f $result.firstHopOk
    'exitViaChain   {0}' -f $result.exitViaChain
    'profile marker {0}   runtime marker {1}' -f $integrity.markerOk, $integrity.runtimeMarkerOk
    if ($result.reasons.Count) { Write-Host 'reasons:'; $result.reasons | ForEach-Object { '  - ' + $_ } }
    Write-Host ''
}
switch ($result.state) {
    'HEALTHY' { exit 0 }
    'RECOVERING' { exit 0 }
    'DEGRADED' { exit 2 }
    default { exit 3 }
}
