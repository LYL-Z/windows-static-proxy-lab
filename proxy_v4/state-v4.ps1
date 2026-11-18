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

$st = Get-V4State
$integrity = [ordered]@{ profileExists = $false; markerOk = $false; runtimeMarkerOk = $false; profileHash = $null; ownerRecord = 'none' }
try {
    $p = Get-V4Paths
    $prof = Join-Path $p.ProfilesDir 'v4-managed.yaml'
    if (Test-Path $prof) {
        $integrity.profileExists = $true
        $integrity.profileHash = (Get-FileHash $prof -Algorithm SHA256).Hash.Substring(0,16)
        $t = Read-V4File $prof
        if ($t -and $t.StartsWith($script:Marker)) { $integrity.markerOk = $true }
    }
    if ($p.RuntimeFile -and (Test-Path $p.RuntimeFile)) {
        $t = Read-V4File $p.RuntimeFile
        # the app regenerates the runtime file, so its marker is not preserved;
        # verify the chain signature instead of the comment
        if ($t -and $t -match 'dialer-proxy:\s*"?STAR-FIRSTHOP"?') { $integrity.runtimeMarkerOk = $true }
    }
    $o = Get-V4Owner
    if ($o) { $integrity.ownerRecord = ('{0} @ {1}' -f $o.owner, $o.updatedAt) }
}
catch { }

$result = [ordered]@{
    state = $st.state; mode = $st.mode; reasons = $st.reasons
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
    Write-Host ("  STATE {0}   mode={1}" -f $result.state, $result.mode) -ForegroundColor $(
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
