#Requires -Version 5.1
<#
.SYNOPSIS
  Read-only WebRTC/UDP egress probe.  Compares the UDP egress a STUN binding
  request observes with the TCP egress this machine has, and states one verdict.

.DESCRIPTION
  What is measured (nothing else is contacted):
    1. UDP via STUN, DIRECT            - OS-routed UDP socket, 2 declared servers
    2. UDP via STUN, SOCKS5 ASSOCIATE  - same request carried by the Clash mixed
                                         port (127.0.0.1:7897 by default)
    3. TCP egress, DIRECT              - tools/diag-contract.ps1 -CaptureBody
                                         against the declared echo target
    4. TCP egress, via the same proxy  - same probe with -x

  The STUN work is done by tools/stun-egress-probe.py (standard library only,
  no third party packages); this script only orchestrates, compares and
  reports.  No second STUN implementation, no second curl wrapper.

  What this script deliberately does NOT do:
    * it does not claim "the Chinese public IP is leaked".  A mapped address
      that differs from the TCP egress proves a different egress, nothing more
    * it does not read, start or modify the user's browser profile
    * it does not touch TUN, DNS, firewall, routes or the proxy config

  Verdict vocabulary (exactly four values):
    CONSISTENT        UDP egress == DIRECT TCP egress (same public address)
    DIFFERENT_EGRESS  both measured, both public, and they differ
    PRIVATE_ONLY      every mapped address is private / CGNAT / link-local
    UNKNOWN           not enough evidence to compare

  `unknown` always lists what was NOT verified, so a missing measurement can
  never be read as a clean result.

  Exit: 0 verdict decided with both sides measured
        2 partial (one side missing, or only one UDP server answered)
        3 no UDP measurement at all

.EXAMPLE
  .\webrtc-probe.ps1
  .\webrtc-probe.ps1 -Json
  .\webrtc-probe.ps1 -Proxy http://127.0.0.1:7897 -TimeoutSec 4
#>
[CmdletBinding()]
param(
    [string]$Proxy = 'http://127.0.0.1:7897',
    [string]$TcpTarget = 'https://api.ipify.org',
    [string]$PythonExe = 'python',
    [string]$ProxyHost = '127.0.0.1',
    [int]$ProxyPort = 7897,
    [ValidateRange(1, 6)][int]$StunTimeoutSec = 3,
    [switch]$IncludeBrowser,
    [switch]$SkipStun,
    [switch]$Json
)
$ErrorActionPreference = 'Continue'

$contractFile = Join-Path $PSScriptRoot 'diag-contract.ps1'
if (-not (Test-Path -LiteralPath $contractFile)) {
    Write-Error ("diag-contract.ps1 not found next to this script: {0}" -f $contractFile)
    exit 3
}
. $contractFile

$stunScript = Join-Path $PSScriptRoot 'stun-egress-probe.py'
$evidenceTime = [datetimeoffset]::Now.ToString('o')
$unknown = New-Object System.Collections.Generic.List[string]

# ---------------------------------------------------------------- TCP egress

function Get-TcpEgress {
    # Two attempts maximum: the Clash chain here is a double hop and a single
    # slow TLS handshake must not be reported as "unmeasured".  A retry only
    # happens after a failure, so the steady-state rate stays 1 request.
    param([string]$ProxyArg)
    $probe = $null
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $probe = Invoke-DiagProbe -Url $TcpTarget -ProxyArg $ProxyArg -TimeoutSec 15 -ForceIPv4 -CaptureBody
        if ($probe.ok -and $probe.body -and ($probe.body -match '(\d{1,3}(?:\.\d{1,3}){3})')) { break }
        Start-Sleep -Milliseconds 400
    }
    $ip = $null
    if ($probe.body -and $probe.body -match '(\d{1,3}(?:\.\d{1,3}){3})') { $ip = $Matches[1] }
    return [pscustomobject][ordered]@{
        ip         = $ip
        via        = $probe.via
        proxy      = $probe.proxy
        transport  = $probe.transport
        httpStatus = $probe.httpStatus
        ok         = $probe.ok
        observedAt = [datetimeoffset]::Now.ToString('o')
        err        = $probe.err
    }
}

$tcpDirect = Get-TcpEgress -ProxyArg ''
if (-not $tcpDirect.ip) { $unknown.Add('TCP egress (direct) not measured: no IP in the echo body') }
Start-Sleep -Milliseconds 250
$tcpProxy = Get-TcpEgress -ProxyArg $Proxy
if (-not $tcpProxy.ip) { $unknown.Add('TCP egress via the proxy not measured') }

# ---------------------------------------------------------------- UDP egress

$stun = $null
$udpDirect = @()
$udpProxy = @()
$stunDirectPrivate = @()
$stunProxyPrivate = @()
if (-not $SkipStun) {
    if (-not (Test-Path -LiteralPath $stunScript)) {
        $unknown.Add('stun-egress-probe.py missing: UDP not measured')
    }
    else {
        $pyArgs = @($stunScript, '--mode', 'both', '--proxy-host', $ProxyHost,
            '--proxy-port', "$ProxyPort", '--timeout', "$StunTimeoutSec")
        $raw = ''
        try {
            $raw = (& $PythonExe @pyArgs 2>&1 | Out-String)
            $rc = $LASTEXITCODE
        }
        catch {
            $rc = 127
            $raw = 'python launch failed'
        }
        if ($rc -ne 0) {
            $unknown.Add(('STUN probe exited {0}: UDP not measured' -f $rc))
        }
        try { $stun = $raw | ConvertFrom-Json -ErrorAction Stop } catch { $stun = $null; $unknown.Add('STUN probe output was not JSON') }
        if ($stun) {
            $dRows = @($stun.modes.direct)
            $pRows = @($stun.modes.socks5)
            $udpDirect = @($dRows | Where-Object { $_.mapped } | ForEach-Object { $_.mapped } | Sort-Object -Unique)
            $udpProxy = @($pRows | Where-Object { $_.mapped } | ForEach-Object { $_.mapped } | Sort-Object -Unique)
            $stunDirectPrivate = @($dRows | Where-Object { $_.mapped } | ForEach-Object { [bool]$_.private })
            $stunProxyPrivate = @($pRows | Where-Object { $_.mapped } | ForEach-Object { [bool]$_.private })
            foreach ($row in $dRows) {
                if (-not $row.mapped) { $unknown.Add(('STUN direct {0}: {1}' -f $row.server, $row.error)) }
            }
            foreach ($row in $pRows) {
                if (-not $row.mapped) { $unknown.Add(('STUN via proxy {0}: {1}' -f $row.server, $row.error)) }
            }
        }
    }
}
else { $unknown.Add('STUN skipped by request (-SkipStun): UDP not measured') }

# ---------------------------------------------------------------- browser level

$browserProbe = $null
if ($IncludeBrowser) {
    $browserScript = Join-Path $PSScriptRoot 'webrtc-browser-probe.ps1'
    if (-not (Test-Path -LiteralPath $browserScript)) {
        $unknown.Add('webrtc-browser-probe.ps1 missing: browser-level WebRTC not measured')
    }
    else {
        $braw = ''
        try {
            $braw = (& powershell -NoProfile -ExecutionPolicy Bypass -File $browserScript -Consent -Json 2>&1 | Out-String)
        }
        catch { $braw = '' }
        try { $browserProbe = $braw | ConvertFrom-Json -ErrorAction Stop } catch { $browserProbe = $null; $unknown.Add('browser probe output was not JSON') }
        if ($browserProbe -and $browserProbe.error) {
            $unknown.Add(('browser-level WebRTC: {0}' -f $browserProbe.error))
        }
    }
}

# ---------------------------------------------------------------- verdict

$verdict = 'UNKNOWN'
$consistent = $null
$basis = ''
$udpD = @($udpDirect)
$tcpD = if ($tcpDirect.ip) { $tcpDirect.ip } else { $null }

if ($SkipStun -or -not $stun) {
    $verdict = 'UNKNOWN'
    $basis = 'UDP was not measured, so no UDP/TCP comparison exists'
}
elseif ($udpD.Count -eq 0) {
    $verdict = 'UNKNOWN'
    $basis = 'no STUN server returned a mapped address; UDP egress is unknown (not "safe")'
}
elseif ($udpD.Count -gt 0 -and $stunDirectPrivate.Count -gt 0 -and ($stunDirectPrivate | Where-Object { $_ -eq $false }).Count -eq 0) {
    $verdict = 'PRIVATE_ONLY'
    $consistent = $false
    $basis = ('every mapped UDP address is private/CGNAT: {0} - a STUN-only view, no public UDP egress observed' -f ($udpD -join ', '))
}
elseif ($tcpD) {
    $consistent = [bool](($udpD.Count -eq 1) -and ($udpD[0] -eq $tcpD))
    $verdict = if ($consistent) { 'CONSISTENT' } else { 'DIFFERENT_EGRESS' }
    $basis = if ($consistent) {
        ('UDP and DIRECT TCP both leave as {0}' -f $tcpD)
    }
    else {
        ('UDP leaves as {0} while DIRECT TCP leaves as {1}: a different egress, not proof of a leaked domestic IP' -f ($udpD -join ', '), $tcpD)
    }
}
else {
    $verdict = 'UNKNOWN'
    $basis = 'UDP was measured but there is no TCP egress to compare it with'
}

# Secondary (informational, never part of the verdict): proxy-path pair.
$proxyPairNote = $null
if (@($udpProxy).Count -gt 0 -and $tcpProxy.ip) {
    $proxyPairNote = [ordered]@{
        udpViaProxy = @($udpProxy)
        tcpViaProxy = $tcpProxy.ip
        equal       = [bool]((@($udpProxy).Count -eq 1) -and (@($udpProxy)[0] -eq $tcpProxy.ip))
        note        = 'the system proxy carries TCP; a browser WebRTC path that bypasses it can legitimately differ'
    }
}

# Always-declared gaps: these are not measured by this tool on this run.
if (-not $browserProbe -or $browserProbe.error) {
    $unknown.Add('browser-level WebRTC (ICE candidate output of a real browser) is NOT measured by this run')
}
$unknown.Add('IPv6 UDP egress is NOT measured')
if ($stun) {
    $unknown.Add('UDP handling inside the SOCKS5 chain is observed, not explained: a proxy entry with udp=false means the client must decide whether to fall back to DIRECT (config-derived, not proven by this run)')
}

$exitCode = switch ($verdict) {
    'CONSISTENT' { if ($unknown.Count -gt 0 -and -not $tcpD) { 2 } else { 0 } }
    'DIFFERENT_EGRESS' { 0 }
    'PRIVATE_ONLY' { 2 }
    default { 2 }
}
if (-not $stun) { $exitCode = 3 }

$result = [ordered]@{
    observedAt    = [datetimeoffset]::Now.ToString('o')
    tool          = 'webrtc-probe.ps1'
    readOnly      = $true
    contract      = Get-DiagContractInfo
    declaredTargets = [ordered]@{
        stunServers = @('stun.cloudflare.com:3478', 'stun.l.google.com:19302')
        tcpEcho     = $TcpTarget
        proxy       = (Get-DiagMaskedEndpoint $Proxy)
    }
    udpEgress     = [ordered]@{
        direct   = @($udpDirect)
        viaProxy = @($udpProxy)
    }
    tcpEgress     = [ordered]@{
        direct   = $tcpDirect
        viaProxy = $tcpProxy
    }
    consistent    = $consistent
    evidenceTime  = $evidenceTime
    unknown       = @($unknown)
    verdict       = $verdict
    verdictBasis  = $basis
    proxyPath     = $proxyPairNote
    browserProbe  = $browserProbe
    rawStun       = $stun
    caveats       = @(
        'A mapped address is what the STUN server saw; it identifies the egress, not the operator of the account',
        'curl does not read the Windows system proxy, so the DIRECT rows are OS-routed, not browser-routed',
        'This probe is not a browser: it cannot see which candidates a browser would advertise'
    )
}

if ($Json) { $result | ConvertTo-Json -Depth 10 }
else {
    Write-Host ''
    Write-Host ('  WEBRTC / UDP EGRESS PROBE   read-only   contract={0}/v{1}' -f $script:DiagContractName, $script:DiagContractVersion) -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * 96))
    Write-Host ('  UDP direct   : {0}' -f $(if ($udpDirect.Count) { $udpDirect -join ', ' } else { '(not measured)' }))
    Write-Host ('  UDP via proxy: {0}' -f $(if ($udpProxy.Count) { $udpProxy -join ', ' } else { '(not measured)' }))
    Write-Host ('  TCP direct   : {0}  (via {1}, transport={2})' -f $(if ($tcpDirect.ip) { $tcpDirect.ip } else { '(not measured)' }), $tcpDirect.via, $tcpDirect.transport)
    Write-Host ('  TCP via proxy: {0}  (via {1})' -f $(if ($tcpProxy.ip) { $tcpProxy.ip } else { '(not measured)' }), $tcpProxy.via) -ForegroundColor DarkGray
    $c = switch ($verdict) { 'CONSISTENT' { 'Green' } 'DIFFERENT_EGRESS' { 'Yellow' } 'PRIVATE_ONLY' { 'Yellow' } default { 'Red' } }
    Write-Host ('  verdict = {0}   consistent={1}' -f $verdict, $consistent) -ForegroundColor $c
    Write-Host ('  basis   : {0}' -f $basis)
    Write-Host ('  evidence: {0}' -f $evidenceTime) -ForegroundColor DarkGray
    if ($proxyPairNote) {
        Write-Host ('  proxy pair: udp={0} tcp={1} equal={2}' -f (($proxyPairNote.udpViaProxy) -join ','), $proxyPairNote.tcpViaProxy, $proxyPairNote.equal) -ForegroundColor DarkGray
    }
    if ($browserProbe -and -not $browserProbe.error) {
        Write-Host ('  browser ICE: verdict={0} mDNS={1} literalHost={2} srflx={3}' -f $browserProbe.verdict,
            $(if (@($browserProbe.hostMdns).Count) { @($browserProbe.hostMdns) -join ',' } else { '-' }),
            $(if (@($browserProbe.hostIpLiteral).Count) { @($browserProbe.hostIpLiteral) -join ',' } else { '-' }),
            $(if (@($browserProbe.srflx).Count) { @($browserProbe.srflx) -join ',' } else { '-' })) -ForegroundColor DarkGray
    }
    Write-Host '  not verified:'
    foreach ($u in $unknown) { Write-Host ('    - {0}' -f $u) -ForegroundColor DarkGray }
    Write-Host ''
}

exit $exitCode
