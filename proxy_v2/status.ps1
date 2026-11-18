#Requires -Version 5.1
<#
.SYNOPSIS
  Show the live network mode, the real egress IP and the active failure reason.

.DESCRIPTION
  Answers, at any moment:
    * which of the three modes is actually in effect (not what was configured)
    * what the real egress IP is right now
    * whether the first hop and the static proxy are healthy
    * if the effective mode differs from the intended one, why

  Never changes anything. Exit codes:
    0 = mode consistent and healthy
    2 = mismatch / degraded (details printed)
    3 = nothing could be determined

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File status.ps1
  powershell -ExecutionPolicy Bypass -File status.ps1 -Quick -Json
#>
[CmdletBinding()]
param(
    [switch]$Quick,
    [switch]$Json,
    [int]$StaticPort = 7897
)

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'lib\Common.ps1')

$p = Get-ClashPaths
$s = [ordered]@{
    timestamp        = (Get-Date).ToString('s')
    expectedMode     = $null
    effectiveMode    = 'UNKNOWN'
    clashRunning     = $false
    clashPipeOk      = $false
    mixedPort7897    = $false
    systemProxy      = $null
    firstHopPort     = $null
    firstHopOk       = $false
    firstHopDetail   = ''
    staticTarget     = $null
    mihomoMode       = $null
    mihomoSelected   = $null
    exitViaSystem    = $null
    exitDirect       = $null
    verdict          = 'UNKNOWN'
    reasons          = @()
}

# ---- static facts from config ------------------------------------------------
if ($p.ProfileFile -and (Test-Path $p.ProfileFile)) {
    $hop = Get-FirstHopConfig -ProfilePath $p.ProfileFile
    if ($hop) { $s.firstHopPort = $hop.Port }
    $st = Get-StaticTarget -ProfilePath $p.ProfileFile
    if ($st) { $s.staticTarget = ('{0}:{1}' -f $st.Host, $st.Port) }
}

# ---- live processes / ports --------------------------------------------------
$clash = Get-Process -Name 'clash-verge' -ErrorAction SilentlyContinue
$s.clashRunning = [bool]$clash
$s.mixedPort7897 = [bool](Test-TcpPort -Port $StaticPort)
if ($s.clashRunning) {
    try { $cfg = Invoke-MihomoApi -Path '/configs' -TimeoutMs 4000; $s.clashPipeOk = ($cfg.StatusCode -eq 200) } catch { }
    if ($s.clashPipeOk) {
        try {
            $j = $cfg.Body | ConvertFrom-Json
            $s.mihomoMode = $j.mode
        } catch { }
        try {
            $pr = Invoke-MihomoApi -Path '/proxies' -TimeoutMs 5000
            $pj = $pr.Body | ConvertFrom-Json
            if ($pj.proxies.PROXY) { $s.mihomoSelected = $pj.proxies.PROXY.now }
        } catch { }
    }
}

# ---- system proxy ------------------------------------------------------------
$px = Get-SystemProxy
$s.systemProxy = if ($px.Enabled) { $px.Server } else { 'off' }

# ---- first hop health --------------------------------------------------------
if ($s.firstHopPort) {
    $probe = Test-FirstHop -Port $s.firstHopPort -TimeoutMs 5000
    $s.firstHopOk = $probe.Ok
    $s.firstHopDetail = $probe.Detail
}

# ---- egress probes -----------------------------------------------------------
if ($s.firstHopOk -and -not $Quick) {
    if ($px.Enabled -and $px.Server) {
        $s.exitViaSystem = Get-NeutralIp -Proxy ("http://{0}" -f $px.Server) -TimeoutSec 20
    }
    $s.exitDirect = Get-NeutralIp -Proxy '' -TimeoutSec 20
}

# ---- classify ----------------------------------------------------------------
$sysIsClash = $px.Enabled -and ($px.Server -eq ("127.0.0.1:{0}" -f $StaticPort))
$sysIsHop = $px.Enabled -and $s.firstHopPort -and ($px.Server -eq ("127.0.0.1:{0}" -f $s.firstHopPort))
$staticIp = if ($s.staticTarget) { ($s.staticTarget -split ':')[0] } else { $null }

if ($s.clashRunning -and $s.mixedPort7897) {
    if ($sysIsClash) {
        if ($Quick) { $s.effectiveMode = 'NEXIP'; $s.verdict = 'OK' }
        elseif ($s.exitViaSystem -eq $staticIp) { $s.effectiveMode = 'NEXIP'; $s.verdict = 'OK' }
        else {
            $s.effectiveMode = 'NEXIP-DEGRADED'
            $s.verdict = 'DEGRADED'
            $s.reasons += ("system proxy points at Clash but the exit is {0}, expected {1}" -f $s.exitViaSystem, $staticIp)
        }
    }
    elseif ($sysIsHop) {
        $s.effectiveMode = 'STARSKY'
        $s.verdict = 'MISMATCH'
        $s.reasons += 'Clash is running but the system proxy belongs to StarSky; browsers bypass the static IP'
    }
    else {
        $s.effectiveMode = 'NEXIP-PARTIAL'
        $s.verdict = 'MISMATCH'
        $s.reasons += ("Clash is running but the system proxy is {0}" -f $s.systemProxy)
    }
}
elseif ($s.clashRunning -and -not $s.mixedPort7897) {
    $s.effectiveMode = 'NEXIP-CORE-DOWN'
    $s.verdict = 'DEGRADED'
    $s.reasons += ("Clash Verge is running but nothing listens on {0} (core down or still starting)" -f $StaticPort)
}
elseif (-not $s.clashRunning) {
    if ($sysIsHop) {
        $s.effectiveMode = 'STARSKY'
        $s.verdict = 'OK'
        $s.reasons += 'Clash is not running, which is expected in STARSKY mode'
    }
    elseif (-not $px.Enabled) {
        $s.effectiveMode = 'RAW'
        $s.verdict = 'OK'
    }
    else {
        $s.effectiveMode = 'UNKNOWN'
        $s.verdict = 'MISMATCH'
        $s.reasons += ("system proxy is {0} but neither Clash nor StarSky explains it" -f $s.systemProxy)
    }
}

if (-not $s.firstHopOk -and $s.effectiveMode -eq 'NEXIP') {
    $s.verdict = 'DEGRADED'
    $s.reasons += ("first hop 127.0.0.1:{0} is down: {1}" -f $s.firstHopPort, $s.firstHopDetail)
}

# ---- output ------------------------------------------------------------------
if ($Json) {
    $s | ConvertTo-Json -Depth 5
}
else {
    Write-Host ''
    Write-Host '  NETWORK STATUS' -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * 62))
    $rows = @(
        [pscustomobject]@{ Item = 'effective mode'; Value = $s.effectiveMode }
        [pscustomobject]@{ Item = 'verdict';        Value = $s.verdict }
        [pscustomobject]@{ Item = 'clash running';  Value = $s.clashRunning }
        [pscustomobject]@{ Item = 'mihomo mode';    Value = $s.mihomoMode }
        [pscustomobject]@{ Item = 'proxy group';    Value = $s.mihomoSelected }
        [pscustomobject]@{ Item = 'system proxy';   Value = $s.systemProxy }
        [pscustomobject]@{ Item = 'first hop';      Value = ("127.0.0.1:{0} -> {1}" -f $s.firstHopPort, $(if ($s.firstHopOk) { 'OK' } else { 'DOWN' })) }
        [pscustomobject]@{ Item = 'static target';  Value = $s.staticTarget }
        [pscustomobject]@{ Item = 'exit (system)';  Value = $(if ($s.exitViaSystem) { $s.exitViaSystem } else { '(not probed)' }) }
        [pscustomobject]@{ Item = 'exit (direct)';  Value = $(if ($s.exitDirect) { $s.exitDirect } else { '(not probed)' }) }
    )
    $rows | Format-Table -AutoSize | Out-String -Width 120 | Write-Host
    if ($s.reasons.Count) {
        Write-Host '  reasons:' -ForegroundColor Yellow
        $s.reasons | ForEach-Object { Write-Host ("   - " + $_) -ForegroundColor Yellow }
    }
    Write-Host ''
}

switch ($s.verdict) {
    'OK'       { exit 0 }
    'MISMATCH' { exit 2 }
    'DEGRADED' { exit 2 }
    default    { exit 3 }
}
