#Requires -Version 5.1
<#
.SYNOPSIS  Read-only state + integrity check for proxy_v4.
.DESCRIPTION
  Reports: sampled chain, fault evidence, ownership, config integrity,
  first hop, real chain exit IP. Changes nothing.
  With -Samples, emits one result per sample. JSON is compact per sample.
  -ConfigDirectory can point this read-only candidate at an existing config directory.
  Exit 2 means partial (including CHAIN_VERIFIED). Exit 3 means failed or unknown.
  This command does not verify an application's complete network path.
#>
[CmdletBinding()]
param(
    [switch]$Json,
    [ValidateRange(1, 12)][int]$Samples = 1,
    [ValidateRange(5, 60)][int]$IntervalSeconds = 5,
    [string]$ConfigDirectory
)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\V4.ps1')
if ($ConfigDirectory) {
    $directory = Get-Item -LiteralPath $ConfigDirectory -ErrorAction Stop
    if ($directory -isnot [IO.DirectoryInfo]) { throw 'ConfigDirectory must be an existing filesystem directory.' }
    $script:ConfigDir = $directory.FullName
    $script:SettingsPath = Join-Path $script:ConfigDir 'settings.json'
    $script:OwnerPath = Join-Path $script:ConfigDir 'owner.json'
}

function Get-StateResult {
    $st = $null
    $stateError = ''
    try { $st = Get-V4State }
    catch { $stateError = $_.Exception.Message }

    if (-not $st) {
        $st = [ordered]@{
            state = 'FAILED'; mode = 'UNKNOWN'; reasons = @(('state probe failed: ' + $stateError))
            faults = @('OBSERVATION_FAILED'); automaticProxy = 'UNKNOWN'; applicationPath = 'NOT_TESTED'
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
        faults = @($st.faults); automaticProxy = $st.automaticProxy
        clashRunning = $st.clashRunning; mixedPort = $st.mixedPort
        systemProxy = $st.systemProxy; ownerRecorded = $st.owner
        uiSystemProxy = $st.uiSystemProxy
        udpProxied = $st.udpProxied; udpDataPlane = $st.udpDataPlane; pathScope = $st.pathScope
        warnings = @($st.warnings)
        firstHopOk = $st.firstHopOk; firstHopStatus = $st.firstHopStatus; exitViaChain = $st.exitViaChain
        chainStatus = $st.chainStatus; windowsTargetsClash = $st.windowsTargetsClash
        coverage = [ordered]@{
            ipv4TcpHttpsExit = $st.chainStatus
            ipv6Tcp = 'NOT_TESTED'
            udp = 'NOT_TESTED'
            applicationPath = $st.applicationPath
        }
        integrity = $integrity
    }
    $markersOk = $integrity.markerOk -and $integrity.runtimeMarkerOk
    if (-not $markersOk -and $st.mode -eq 'NEXIP') {
        $result.faults += 'MANAGED_PROFILE_UNVERIFIED'
        $result.reasons += 'managed profile or runtime marker could not be verified'
    }
    if (-not $markersOk -and $result.state -eq 'CHAIN_VERIFIED') { $result.state = 'DEGRADED' }
    $transaction = Get-V4Journal
    $result.recoveryAction = switch ($true) {
        { [bool](Get-V4RepairReceipt) } { 'REVIEW_INTERRUPTED_REPAIR'; break }
        { $transaction -and $transaction.preparation } { 'REVIEW_INTERRUPTED_PREPARATION'; break }
        { [bool]$transaction } { 'REVIEW_PENDING_TRANSACTION'; break }
        { $st.mode -eq 'UNKNOWN' } { 'REVIEW_SETTINGS_OR_PROBE'; break }
        { -not $st.clashRunning -or -not $st.mixedPort } { 'CHECK_CLASH_STARTUP'; break }
        { -not $result.firstHopOk } { 'CHECK_FIRST_HOP'; break }
        { -not $markersOk } { 'REVIEW_MANAGED_PROFILE'; break }
        { $result.chainStatus -ne 'EXPECTED_EXIT' } { 'CHECK_HTTPS_CHAIN'; break }
        { $result.systemProxy -eq 'unknown' -or $result.uiSystemProxy -ne 'enabled' -or
          $result.automaticProxy -ne 'NOT_OBSERVED' } { 'REVIEW_PROXY_MODE'; break }
        { $st.windowsTargetsFirstHop -and -not $result.windowsTargetsClash } { 'CONSIDER_MANUAL_REPAIR'; break }
        { -not $result.windowsTargetsClash } { 'REVIEW_PROXY_MODE'; break }
        default { 'VERIFY_APPLICATION_PATH' }
    }
    if ($result.recoveryAction -eq 'CONSIDER_MANUAL_REPAIR') {
        $result.reasons += 'Clash HTTPS is usable while the Windows proxy differs. Review proxy ownership and obtain authorization before running apply-v4.ps1 -Repair.'
    }
    if ($result.recoveryAction -eq 'REVIEW_PENDING_TRANSACTION') {
        $result.faults += 'PENDING_TRANSACTION'
        if ($result.state -eq 'CHAIN_VERIFIED') { $result.state = 'DEGRADED' }
    }
    if ($result.recoveryAction -eq 'REVIEW_INTERRUPTED_PREPARATION') {
        $result.faults += 'PENDING_PREPARATION'
        $result.reasons += 'Snapshot preparation may have stopped the client. Review current proxy intent before authorizing client resume.'
        if ($result.state -eq 'CHAIN_VERIFIED') { $result.state = 'DEGRADED' }
    }
    if ($result.recoveryAction -eq 'REVIEW_INTERRUPTED_REPAIR') {
        $result.faults += 'PENDING_REPAIR'
        if ($result.state -eq 'CHAIN_VERIFIED') { $result.state = 'DEGRADED' }
    }
    $result.advice = if ($result.state -eq 'CHAIN_VERIFIED') {
        'Sampled IPv4 HTTPS exit matched. Recheck the actual application before resuming tasks that require a fixed path.'
    } else {
        'Pause applications that require a fixed path. Review the fault and reverify the application before resuming. This monitor does not block traffic.'
    }
    return $result
}

function Write-StateResult($result) {
    Write-Host ''
    Write-Host ('  STATE {0}   mode={1}' -f $result.state, $result.mode) -ForegroundColor $(
        switch ($result.state) { 'CHAIN_VERIFIED' {'Cyan'} 'DEGRADED' {'Yellow'} default {'Red'} })
    Write-Host ('  ' + ('-'*60))
    'clashRunning   {0}' -f $result.clashRunning
    'mixedPort      {0}' -f $result.mixedPort
    'systemProxy    {0}   (owner record: {1})' -f $result.systemProxy, $result.ownerRecorded
    'uiSystemProxy  {0}   pathScope {1}   UDP configured {2}   UDP data plane {3}' -f $result.uiSystemProxy, $result.pathScope, $result.udpProxied, $result.udpDataPlane
    if ($result.warnings.Count) { Write-Host 'warnings:'; $result.warnings | ForEach-Object { '  - ' + $_ } }
    'firstHopOk     {0}   firstHopStatus {1}' -f $result.firstHopOk, $result.firstHopStatus
    'chainStatus    {0}   windowsTargetsClash {1}' -f $result.chainStatus, $result.windowsTargetsClash
    'automaticProxy {0}   applicationPath {1}' -f $result.automaticProxy, $result.coverage.applicationPath
    'recoveryAction {0}' -f $result.recoveryAction
    if ($result.faults.Count) { 'faults         {0}' -f ($result.faults -join ', ') }
    'profile marker {0}   runtime marker {1}' -f $result.integrity.markerOk, $result.integrity.runtimeMarkerOk
    if ($result.reasons.Count) { Write-Host 'reasons:'; $result.reasons | ForEach-Object { '  - ' + $_ } }
    Write-Host ''
}

$previousFaults = $null
for ($sample = 1; $sample -le $Samples; $sample++) {
    if ($sample -gt 1) { Start-Sleep -Seconds $IntervalSeconds }
    $result = Get-StateResult
    $faultKey = $result.faults -join ','
    $result.alert = if ($faultKey -and $faultKey -ne $previousFaults) { 'PAUSE_APPLICATIONS' }
        elseif (-not $faultKey -and $previousFaults -and $result.state -eq 'CHAIN_VERIFIED') { 'CHAIN_REVERIFIED_APPLICATION_PENDING' }
        else { 'NONE' }
    $previousFaults = $faultKey
    if ($Json) { $result | ConvertTo-Json -Depth 5 -Compress:($Samples -gt 1) }
    else {
        Write-StateResult $result
        if ($result.alert -eq 'PAUSE_APPLICATIONS') { Write-Warning $result.advice }
        elseif ($result.alert -ne 'NONE' -or $sample -eq 1) { $result.advice }
    }
}
switch ($result.state) {
    'CHAIN_VERIFIED' { exit 2 }
    'DEGRADED' { exit 2 }
    default { exit 3 }
}
