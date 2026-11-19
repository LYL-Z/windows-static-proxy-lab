#Requires -Version 5.1
<#
.SYNOPSIS  Read-only state + integrity check for proxy_v4.
.DESCRIPTION
  Reports: five-state health, ownership, config integrity (marker + hash),
  first hop, real chain exit IP. Changes nothing.
  With -Samples, emits one result per sample. JSON is compact per sample.
  Exit describes the final sample: 0 HEALTHY/RECOVERING, 2 DEGRADED, 3 FAILED/UNKNOWN.
#>
[CmdletBinding()]
param(
    [switch]$Json,
    [ValidateRange(1, 12)][int]$Samples = 1,
    [ValidateRange(5, 60)][int]$IntervalSeconds = 5
)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\V4.ps1')

function Get-StateResult {
    $st = $null
    $stateError = ''
    try { $st = Get-V4State }
    catch { $stateError = $_.Exception.Message }

    if (-not $st) {
        $st = [ordered]@{
            state = 'FAILED'; mode = 'UNKNOWN'; reasons = @(('state probe failed: ' + $stateError))
            clashRunning = $false; mixedPort = $false; systemProxy = 'unknown'
            owner = 'unknown'; firstHopOk = $false; exitViaChain = $null; uiSystemProxy = 'unknown'
            firstHopStatus = 'NOT_PROBED'; recoveryAction = 'REVIEW_SETTINGS_OR_PROBE'
            udpProxied = 'unknown'; udpDataPlane = 'not_probed'; pathScope = 'UNKNOWN'; warnings = @()
            chainStatus = 'NOT_PROBED'; windowsTargetsClash = $false
        }
    }
    $p = Get-V4Paths
    $integrity = Get-V4Integrity -Paths $p

    $result = [ordered]@{
        observedAt = [datetimeoffset]::Now.ToString('o')
        state = $st.state; mode = $st.mode; reasons = @($st.reasons)
        clashRunning = $st.clashRunning; mixedPort = $st.mixedPort
        systemProxy = $st.systemProxy; ownerRecorded = $st.owner
        uiSystemProxy = $st.uiSystemProxy
        udpProxied = $st.udpProxied; udpDataPlane = $st.udpDataPlane; pathScope = $st.pathScope
        warnings = @($st.warnings)
        firstHopOk = $st.firstHopOk; firstHopStatus = $st.firstHopStatus; exitViaChain = $st.exitViaChain
        chainStatus = $st.chainStatus; windowsTargetsClash = $st.windowsTargetsClash
        integrity = $integrity
    }
    $markersOk = $integrity.markerOk -and $integrity.runtimeMarkerOk
    if (-not $markersOk -and $st.mode -eq 'NEXIP') {
        $result.reasons += 'managed profile or runtime marker could not be verified'
    }
    if (-not $markersOk -and $result.state -eq 'HEALTHY') { $result.state = 'DEGRADED' }
    $result.recoveryAction = switch ($true) {
        { [bool](Get-V4Journal) } { 'REVIEW_PENDING_TRANSACTION'; break }
        { $st.mode -eq 'UNKNOWN' } { 'REVIEW_SETTINGS_OR_PROBE'; break }
        { -not $st.clashRunning -or -not $st.mixedPort } { 'CHECK_CLASH_STARTUP'; break }
        { -not $result.firstHopOk } { 'CHECK_FIRST_HOP'; break }
        { -not $markersOk } { 'REVIEW_MANAGED_PROFILE'; break }
        { $result.chainStatus -ne 'EXPECTED_EXIT' } { 'CHECK_HTTPS_CHAIN'; break }
        { $result.systemProxy -eq 'unknown' -or $result.uiSystemProxy -ne 'enabled' } { 'REVIEW_PROXY_MODE'; break }
        { -not $result.windowsTargetsClash } { 'CONSIDER_MANUAL_REPAIR'; break }
        default { 'NO_PROXY_CHANGE_INDICATED' }
    }
    if ($result.recoveryAction -eq 'CONSIDER_MANUAL_REPAIR') {
        $result.reasons += 'Clash HTTPS is usable while the Windows proxy differs. Review proxy ownership and obtain authorization before running apply-v4.ps1 -Repair.'
    }
    return $result
}

function Write-StateResult($result) {
    Write-Host ''
    Write-Host ('  STATE {0}   mode={1}' -f $result.state, $result.mode) -ForegroundColor $(
        switch ($result.state) { 'HEALTHY' {'Green'} 'DEGRADED' {'Yellow'} 'RECOVERING' {'Cyan'} default {'Red'} })
    Write-Host ('  ' + ('-'*60))
    'clashRunning   {0}' -f $result.clashRunning
    'mixedPort      {0}' -f $result.mixedPort
    'systemProxy    {0}   (owner record: {1})' -f $result.systemProxy, $result.ownerRecorded
    'uiSystemProxy  {0}   pathScope {1}   UDP configured {2}   UDP data plane {3}' -f $result.uiSystemProxy, $result.pathScope, $result.udpProxied, $result.udpDataPlane
    if ($result.warnings.Count) { Write-Host 'warnings:'; $result.warnings | ForEach-Object { '  - ' + $_ } }
    'firstHopOk     {0}   firstHopStatus {1}' -f $result.firstHopOk, $result.firstHopStatus
    'chainStatus    {0}   windowsTargetsClash {1}' -f $result.chainStatus, $result.windowsTargetsClash
    'recoveryAction {0}' -f $result.recoveryAction
    'exitViaChain   {0}' -f $result.exitViaChain
    'profile marker {0}   runtime marker {1}' -f $integrity.markerOk, $integrity.runtimeMarkerOk
    if ($result.reasons.Count) { Write-Host 'reasons:'; $result.reasons | ForEach-Object { '  - ' + $_ } }
    Write-Host ''
}

for ($sample = 1; $sample -le $Samples; $sample++) {
    if ($sample -gt 1) { Start-Sleep -Seconds $IntervalSeconds }
    $result = Get-StateResult
    if ($Json) { $result | ConvertTo-Json -Depth 5 -Compress:($Samples -gt 1) }
    else { Write-StateResult $result }
}
switch ($result.state) {
    'HEALTHY' { exit 0 }
    'RECOVERING' { exit 0 }
    'DEGRADED' { exit 2 }
    default { exit 3 }
}
