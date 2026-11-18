#Requires -Version 5.1
<#
.SYNOPSIS
  Five-state network state machine for the proxy stack.

.DESCRIPTION
  States:
    HEALTHY    : intended mode active, egress matches, first hop up, core up
    DEGRADED   : reachable but not as intended (fallback to DIRECT, hop unstable, mismatch)
    FAILED     : no working egress through the intended path (core down / proxy dead)
    RECOVERING : a change was applied very recently and verification has not settled
    UNKNOWN    : cannot determine (missing config, no process, probes all failed)

  This script is read-only. It never changes the system.
  Exit: 0 HEALTHY, 2 DEGRADED, 3 FAILED/UNKNOWN.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File state.ps1
  powershell -ExecutionPolicy Bypass -File state.ps1 -Json
#>
[CmdletBinding()]
param([switch]$Json, [int]$RecoverWindowSec = 25)

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'lib\Common.ps1')

$out = [ordered]@{
    ts          = (Get-Date).ToString('s')
    state       = 'UNKNOWN'
    mode        = 'UNKNOWN'
    reasons     = @()
    signals     = [ordered]@{}
}

function Add-Reason($t) { $script:out.reasons += $t }

try {
    $p = Get-ClashPaths
    $sig = $out.signals
    $sig.clashRunning = [bool](Get-Process -Name 'clash-verge' -ErrorAction SilentlyContinue)
    $sig.coreRunning  = [bool](Get-Process -Name 'verge-mihomo', 'mihomo' -ErrorAction SilentlyContinue)
    $sig.mixedPort    = Test-TcpPort -Port 7897
    $sig.systemProxy  = (Get-SystemProxy).Server
    $sig.sysProxyOn   = (Get-SystemProxy).Enabled

    $hopPort = $null
    $staticIp = $null
    if ($p.ProfileFile -and (Test-Path $p.ProfileFile)) {
        $hop = Get-FirstHopConfig -ProfilePath $p.ProfileFile
        if ($hop) { $hopPort = $hop.Port }
        $st = Get-StaticTarget -ProfilePath $p.ProfileFile
        if ($st) { $staticIp = $st.Host }
    }
    $sig.firstHopPort = $hopPort
    $sig.staticIp     = $staticIp
    $sig.firstHopOk   = if ($hopPort) { (Test-FirstHop -Port $hopPort -TimeoutMs 5000).Ok } else { $false }
    $sig.uptimeSec    = $null
    $cp = Get-Process -Name 'clash-verge' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cp) { $sig.uptimeSec = [int]((Get-Date) - $cp.StartTime).TotalSeconds }

    # ---- classify ----
    if (-not $p.AppDataDir) { $out.state = 'UNKNOWN'; Add-Reason 'Clash Verge config directory not found' }
    elseif (-not $sig.clashRunning -and $sig.sysProxyOn -and $sig.systemProxy -match ':11119$') {
        $out.mode = 'STARSKY'
        if ($sig.firstHopOk) { $out.state = 'HEALTHY' } else { $out.state = 'DEGRADED'; Add-Reason 'StarSky proxy not usable' }
    }
    elseif (-not $sig.clashRunning -and -not $sig.sysProxyOn) {
        $out.mode = 'RAW'
        $out.state = 'HEALTHY'
    }
    elseif ($sig.clashRunning -and -not $sig.mixedPort) {
        $out.mode = 'NEXIP'
        $out.state = 'FAILED'
        Add-Reason 'Clash Verge is running but 7897 is not listening'
    }
    elseif ($sig.clashRunning -and $sig.mixedPort) {
        $out.mode = 'NEXIP'
        if ($sig.systemProxy -ne '127.0.0.1:7897') {
            $out.state = 'DEGRADED'
            Add-Reason ("system proxy is {0}, expected 127.0.0.1:7897 (another program owns it)" -f $sig.systemProxy)
        }
        elseif (-not $sig.firstHopOk) {
            $out.state = 'DEGRADED'
            Add-Reason 'first hop is down; resilient fallback may be sending traffic DIRECT'
        }
        else {
            $eg = Get-NeutralIp -Proxy 'socks5h://127.0.0.1:7897' -TimeoutSec 20
            $sig.exitViaChain = $eg
            if ($eg -eq $staticIp) {
                if ($sig.uptimeSec -lt $RecoverWindowSec) { $out.state = 'RECOVERING'; Add-Reason 'recently restarted; verification settling' }
                else { $out.state = 'HEALTHY' }
            }
            elseif ($eg) {
                $out.state = 'DEGRADED'
                Add-Reason ("chain exits at {0}, expected {1}" -f $eg, $staticIp)
            }
            else {
                $out.state = 'FAILED'
                Add-Reason 'no exit IP could be obtained through the chain'
            }
        }
    }
    else {
        $out.state = 'UNKNOWN'
        Add-Reason 'state combination not matched'
    }
}
catch {
    $out.state = 'UNKNOWN'
    Add-Reason ('probe failed: ' + (Get-Redacted $_.Exception.Message))
}

if ($Json) { $out | ConvertTo-Json -Depth 5 }
else {
    Write-Host ''
    Write-Host ("  STATE: {0}   mode={1}" -f $out.state, $out.mode) -ForegroundColor $(
        switch ($out.state) { 'HEALTHY' { 'Green' } 'DEGRADED' { 'Yellow' } 'RECOVERING' { 'Cyan' } default { 'Red' } })
    Write-Host ('  ' + ('-' * 58))
    $out.signals.GetEnumerator() | ForEach-Object { '  {0,-16} {1}' -f $_.Key, $_.Value }
    if ($out.reasons.Count) { Write-Host '  reasons:'; $out.reasons | ForEach-Object { Write-Host ('   - ' + $_) -ForegroundColor Yellow } }
    Write-Host ''
}

switch ($out.state) {
    'HEALTHY' { exit 0 }
    'RECOVERING' { exit 0 }
    'DEGRADED' { exit 2 }
    default { exit 3 }
}
