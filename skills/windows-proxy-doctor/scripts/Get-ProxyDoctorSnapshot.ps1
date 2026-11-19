#Requires -Version 5.1
<#
Read-only Windows proxy snapshot. No writes.
-TestFixture reads a synthetic JSON object instead of HKCU/processes;
it exists for isolated tests and never touches the real machine.
#>
[CmdletBinding()]
param(
    [switch]$Json,
    [switch]$AsObject,
    [switch]$IncludeWriterEvidence,
    [string]$TestFixture = '',
    [ValidateRange(1, 65535)][int]$MixedPort = 7897,
    [ValidateRange(0, 65535)][int]$FirstHopPort = 11119
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProxyTarget.ps1')
. (Join-Path $PSScriptRoot 'ProxyListeners.ps1')

function ConvertTo-Bool($v) { if ($null -eq $v) { return $false }; return [bool]$v }

function Get-UiEnabled {
    try {
        $p = Join-Path (Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev') 'verge.yaml'
        if (-not (Test-Path -LiteralPath $p)) { return $null }
        $t = Get-Content -LiteralPath $p -Raw
        if ($t -match '(?m)^enable_system_proxy:\s*(true|false)') { return ($Matches[1] -eq 'true') }
    } catch { }
    return $null
}

function Get-ListenerProcessNames($listeners) {
    foreach ($ownerId in @($listeners | Select-Object -ExpandProperty OwningProcess -Unique)) {
        $process = Get-Process -Id $ownerId -ErrorAction SilentlyContinue
        if ($process) { $process.ProcessName }
    }
}

if ($TestFixture) {
    $f = Get-Content -LiteralPath $TestFixture -Raw | ConvertFrom-Json
    $proxyEnabled = ConvertTo-Bool $f.proxyEnabled
    $proxyServer = [string]$f.proxyServer
    $pacConfigured = [bool]$f.pacConfigured
    $uiEnabled = $f.uiEnabled
    if ($null -ne $uiEnabled) { $uiEnabled = [bool]$uiEnabled }
    $procRunning = ConvertTo-Bool $f.processRunning
    $mixedOpen = ConvertTo-Bool $f.mixedPortOpen
    $firstHopOpen = if ($FirstHopPort) { ConvertTo-Bool $f.firstHopOpen }
    $listenerQueryOk = $true
    $exitMatches = if ($null -eq $f.exitMatches) { $null } else { [bool]$f.exitMatches }
} else {
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    try {
        $p = Get-ItemProperty -LiteralPath $k -ErrorAction Stop
        $proxyEnabled = ([int]$p.ProxyEnable -eq 1)
        $proxyServer = [string]$p.ProxyServer
        $pacConfigured = -not [string]::IsNullOrWhiteSpace($p.AutoConfigURL)
    } catch {
        $proxyEnabled = $null
        $proxyServer = ''
        $pacConfigured = $null
    }
    $uiEnabled = Get-UiEnabled
    $coreNames = @('verge-mihomo', 'mihomo')
    $procRunning = $null
    $coreRunning = $null
    $mixedIPv4CoreOwned = $null
    try {
        $running = @(Get-Process -ErrorAction Stop | Where-Object { $_.ProcessName -in ($coreNames + 'clash-verge') })
        $procRunning = $running.Count -gt 0
        $coreIds = @($running | Where-Object ProcessName -in $coreNames | Select-Object -ExpandProperty Id)
        $coreRunning = $coreIds.Count -gt 0
    } catch { }
    $listeners = Get-ProxyDoctorListeners @($MixedPort, $FirstHopPort)
    $listenerQueryOk = $listeners.queryOk
    $mixedListeners = @($listeners.rows | Where-Object LocalPort -eq $MixedPort)
    $firstHopListeners = @($listeners.rows | Where-Object LocalPort -eq $FirstHopPort)
    $mixedOpen = if ($listenerQueryOk) { $mixedListeners.Count -gt 0 }
    $firstHopOpen = if ($FirstHopPort -and $listenerQueryOk) { $firstHopListeners.Count -gt 0 }
    if ($listenerQueryOk -and $null -ne $coreRunning) {
        $mixedIPv4CoreOwned = @($mixedListeners | Where-Object {
            $_.OwningProcess -in $coreIds -and $_.LocalAddress -in @('127.0.0.1', '0.0.0.0')
        }).Count -gt 0
    }
    $exitMatches = $null
}

$reasons = New-Object System.Collections.Generic.List[string]
$targetsMixed = if ($proxyEnabled) { Test-ProxyDoctorTarget -Server $proxyServer -Port $MixedPort } else { $proxyEnabled }
if ($proxyEnabled -and $targetsMixed -eq $false) {
    $reasons.Add(('Windows manual HTTP(S) proxy does not target the expected mixed port ' + $MixedPort))
}
if ($procRunning -eq $false) { $reasons.Add('proxy client process not running') }
if ($mixedOpen -eq $false) { $reasons.Add(('mixed port ' + $MixedPort + ' not listening')) }
if ($proxyEnabled -and $mixedOpen -eq $false) { $reasons.Add('system proxy enabled but mixed port is down') }
if ($proxyEnabled -eq $false -and $mixedOpen) { $reasons.Add('mixed port is up but system proxy is off') }
if ($null -ne $proxyEnabled -and $null -ne $uiEnabled -and $uiEnabled -ne $proxyEnabled) {
    $reasons.Add(('UI enable_system_proxy=' + $uiEnabled + ' but HKCU ProxyEnable=' + $proxyEnabled))
}

$state = 'UNKNOWN'
if ($procRunning -eq $false -or $mixedOpen -eq $false) { $state = 'FAILED' }
elseif (-not $listenerQueryOk -or $null -eq $procRunning) { $reasons.Add('listener or process state could not be read') }
elseif ($null -eq $proxyEnabled) { $reasons.Add('HKCU Internet Settings could not be read') }
elseif ($proxyEnabled -and $targetsMixed -eq $false) { $state = 'DEGRADED' }
elseif ($proxyEnabled -and $mixedIPv4CoreOwned -eq $false) { $state = 'DEGRADED'; $reasons.Add('expected core does not own an IPv4 listener on the mixed port') }
elseif ($null -ne $uiEnabled -and ([bool]$uiEnabled -ne [bool]$proxyEnabled)) { $state = 'DEGRADED' }
elseif ($pacConfigured) { $reasons.Add('PAC configured, application proxy selection was not measured') }
elseif (-not $proxyEnabled) { $state = 'DEGRADED'; $reasons.Add('proxy client is running but Windows proxy is off') }
elseif ($FirstHopPort -and $firstHopOpen -eq $false) { $state = 'DEGRADED'; $reasons.Add(('first hop port ' + $FirstHopPort + ' not listening')) }
elseif ($null -ne $exitMatches -and -not $exitMatches) { $state = 'DEGRADED'; $reasons.Add('exit path does not match expected proxy') }
elseif ($null -eq $targetsMixed -or $null -eq $uiEnabled) { $reasons.Add('manual proxy target or saved UI state could not be verified') }
elseif ($null -eq $exitMatches) { $reasons.Add('HTTPS exit was not measured by this snapshot') }
else { $state = 'HEALTHY' }

$displayServer = if ($proxyServer -match '^(?:(?:http|https)://)?(?:127\.0\.0\.1|localhost|\[::1\]):\d{1,5}$') {
    $proxyServer
} elseif ($proxyServer) { '[redacted]' } else { '' }

$out = [ordered]@{
    schema = 1
    ts = (Get-Date).ToString('o')
    source = $(if ($TestFixture) { 'test-fixture' } else { 'live-read-only' })
    proxyEnabled = $proxyEnabled
    proxyServer = $displayServer
    pacConfigured = $pacConfigured
    proxyTargetsMixedPort = $targetsMixed
    uiEnabled = $uiEnabled
    processRunning = $procRunning
    listenerQueryOk = $listenerQueryOk
    mixedPort = $MixedPort
    mixedPortOpen = $mixedOpen
    firstHopPort = $FirstHopPort
    firstHopOpen = $firstHopOpen
    exitMatches = $exitMatches
    state = $state
    reasons = @($reasons)
}
if (-not $TestFixture) {
    $out.coreRunning = $coreRunning
    $out.mixedIPv4CoreOwned = $mixedIPv4CoreOwned
    $out.mixedPortProcesses = @(Get-ListenerProcessNames $mixedListeners)
    $out.firstHopPortProcesses = @(Get-ListenerProcessNames $firstHopListeners)
    $out.firstHopListenerProcessIds = @($firstHopListeners | Select-Object -ExpandProperty OwningProcess | Sort-Object -Unique)
}
if ($IncludeWriterEvidence) {
    $out.writerEvidence = if ($TestFixture) { @{ status = 'not_queried_in_fixture' } } else {
        . (Join-Path $PSScriptRoot 'ProxyRegistryEvents.ps1')
        @{ lookbackMinutes = 15; sources = @(Get-ProxyDoctorWriterEvidence) }
    }
}
if ($AsObject) { [pscustomobject]$out }
elseif ($Json) { $out | ConvertTo-Json -Depth 6 }
else {
    Write-Host ('STATE ' + $out.state)
    $out.GetEnumerator() | Where-Object { $_.Key -notin @('reasons', 'writerEvidence') } | ForEach-Object { Write-Host (('{0} = {1}' -f $_.Key, ($_.Value -join ', '))) }
    if ($out.reasons.Count) { $out.reasons | ForEach-Object { Write-Host ('  - ' + $_) } }
    if ($IncludeWriterEvidence) { $out.writerEvidence | ConvertTo-Json -Depth 5 }
}
