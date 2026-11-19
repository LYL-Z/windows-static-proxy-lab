#Requires -Version 5.1
<#
Read-only Windows proxy snapshot. No writes.
-TestFixture reads a synthetic JSON object instead of HKCU/processes;
it exists for isolated tests and never touches the real machine.
#>
[CmdletBinding()]
param(
    [switch]$Json,
    [string]$TestFixture = '',
    [ValidateRange(1, 65535)][int]$MixedPort = 7897,
    [ValidateRange(1, 65535)][int]$FirstHopPort = 11119
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProxyTarget.ps1')

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

function Get-PortOpen([int]$port) {
    try {
        $c = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction Stop | Select-Object -First 1
        return [bool]$c
    } catch { return $false }
}

function Get-ProxyProcesses {
    try { return @(Get-Process -Name 'clash-verge','verge-mihomo','mihomo' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id) }
    catch { return @() }
}

if ($TestFixture) {
    $f = Get-Content -LiteralPath $TestFixture -Raw | ConvertFrom-Json
    $proxyEnabled = ConvertTo-Bool $f.proxyEnabled
    $proxyServer = [string]$f.proxyServer
    $uiEnabled = $f.uiEnabled
    if ($null -ne $uiEnabled) { $uiEnabled = [bool]$uiEnabled }
    $procRunning = ConvertTo-Bool $f.processRunning
    $mixedOpen = ConvertTo-Bool $f.mixedPortOpen
    $firstHopOpen = ConvertTo-Bool $f.firstHopOpen
    $exitMatches = if ($null -eq $f.exitMatches) { $null } else { [bool]$f.exitMatches }
} else {
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $p = Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue
    $proxyEnabled = ([int]$p.ProxyEnable -eq 1)
    $proxyServer = [string]$p.ProxyServer
    $uiEnabled = Get-UiEnabled
    $procRunning = (@(Get-ProxyProcesses).Count -gt 0)
    $mixedOpen = Get-PortOpen $MixedPort
    $firstHopOpen = Get-PortOpen $FirstHopPort
    $exitMatches = $null
}

$reasons = New-Object System.Collections.Generic.List[string]
$targetsMixed = if ($proxyEnabled) { Test-ProxyDoctorTarget -Server $proxyServer -Port $MixedPort } else { $false }
if ($proxyEnabled -and $targetsMixed -eq $false) {
    $reasons.Add(('Windows manual HTTP(S) proxy does not target the expected mixed port ' + $MixedPort))
}
if (-not $procRunning) { $reasons.Add('proxy client process not running') }
if (-not $mixedOpen) { $reasons.Add(('mixed port ' + $MixedPort + ' not listening')) }
if ($proxyEnabled -and -not $mixedOpen) { $reasons.Add('system proxy enabled but mixed port is down') }
if (-not $proxyEnabled -and $mixedOpen) { $reasons.Add('mixed port is up but system proxy is off') }
if ($null -ne $uiEnabled -and ([bool]$uiEnabled -ne [bool]$proxyEnabled)) {
    $reasons.Add(('UI enable_system_proxy=' + $uiEnabled + ' but HKCU ProxyEnable=' + $proxyEnabled))
}

$state = 'UNKNOWN'
if (-not $procRunning -or -not $mixedOpen) { $state = 'FAILED' }
elseif ($proxyEnabled -and $targetsMixed -eq $false) { $state = 'DEGRADED' }
elseif ($null -ne $uiEnabled -and ([bool]$uiEnabled -ne [bool]$proxyEnabled)) { $state = 'DEGRADED' }
elseif (-not $proxyEnabled) { $state = 'DEGRADED'; $reasons.Add('proxy client is running but Windows proxy is off') }
elseif (-not $firstHopOpen) { $state = 'DEGRADED'; $reasons.Add(('first hop port ' + $FirstHopPort + ' not listening')) }
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
    proxyEnabled = [bool]$proxyEnabled
    proxyServer = $displayServer
    proxyTargetsMixedPort = $targetsMixed
    uiEnabled = $uiEnabled
    processRunning = [bool]$procRunning
    mixedPort = $MixedPort
    mixedPortOpen = [bool]$mixedOpen
    firstHopPort = $FirstHopPort
    firstHopOpen = [bool]$firstHopOpen
    exitMatches = $exitMatches
    state = $state
    reasons = @($reasons)
}
if ($Json) { $out | ConvertTo-Json -Depth 6 }
else {
    Write-Host ('STATE ' + $out.state)
    $out.GetEnumerator() | ForEach-Object { if ($_.Key -ne 'reasons') { Write-Host (('{0} = {1}' -f $_.Key, $_.Value)) } }
    if ($out.reasons.Count) { $out.reasons | ForEach-Object { Write-Host ('  - ' + $_) } }
}
