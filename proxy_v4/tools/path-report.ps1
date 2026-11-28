#Requires -Version 5.1
<#
.SYNOPSIS
  Read-only IPv4 egress path report.  Answers one question:

    "For this machine, which hop decides the exit IP for a domestic target and
     for a foreign target, and is that split explained or unexplained?"

.DESCRIPTION
  Reuses the single probe core in tools/diag-contract.ps1 (Invoke-DiagProbe,
  v2, -CaptureBody).  No second curl wrapper exists here.

  Paths measured (every run contacts exactly the targets declared below):
    DIRECT  no explicit proxy.  Whatever the OS does -- on this machine the IPv4
            default route points at a TUN interface, so "direct" means
            "OS-routed into the TUN client", NOT "out of the physical NIC".
    7897    http://127.0.0.1:7897, the Clash Verge mixed port (rule mode).
    11119   http://127.0.0.1:11119, the local first hop Clash uses as
            dialer-proxy for its SOCKS5 server.

  curl does NOT read the Windows system proxy: a probe only uses a proxy when
  this script passes -x.  Every row records via=DIRECT|PROXY and the masked
  proxy endpoint, so "which hop produced this IP" is part of the evidence.
  The system proxy is read (read-only) and reported separately, because that
  setting -- not curl -- is what a browser follows.

  Read-only guarantees:
    * no registry write, no config write, no proxy/route/DNS/firewall change
    * never disables certificate validation
    * the running Clash config is opened read-only; only whitelisted scalar
      fields (mode, ports, ipv6, tun.enable, rules, proxy names/types/servers)
      are read.  Credential lines (username/password/secret) are never parsed
      into the report
    * low request rate: 3 paths x declared targets x -Samples, sequential

  Conclusion values:
    CONSISTENT          every measured (path,target-class) row reports the same
                        egress IP
    SPLIT_BY_DESIGN     at least one path shows domestic != foreign, and the
                        split is accounted for by an observed decision point
                        (Clash GEOIP,CN,DIRECT + MATCH,PROXY rule, or the TUN
                        default route with a rule-based TUN client)
    INCONSISTENT_UNKNOWN anything else, including insufficient measurement

.EXAMPLE
  .\path-report.ps1
  .\path-report.ps1 -Json
  .\path-report.ps1 -Paths DIRECT,7897 -Samples 1
#>
[CmdletBinding()]
param(
    [string[]]$Paths = @('DIRECT', '7897', '11119'),
    [string[]]$ForeignTargets = @('https://api.ipify.org', 'https://www.cloudflare.com/cdn-cgi/trace'),
    [string[]]$DomesticTargets = @('http://ip.3322.net'),
    [ValidateRange(1, 3)][int]$Samples = 1,
    [int]$TimeoutSec = 15,
    [switch]$SkipConfigRead,
    [switch]$Json
)
$ErrorActionPreference = 'Continue'

$contractFile = Join-Path $PSScriptRoot 'diag-contract.ps1'
if (-not (Test-Path -LiteralPath $contractFile)) {
    Write-Error ("diag-contract.ps1 not found next to this script: {0}" -f $contractFile)
    exit 3
}
. $contractFile

$pathMap = @{
    'DIRECT' = @{ label = 'DIRECT (OS routing)'; proxy = '' }
    '7897'   = @{ label = 'CLASH-7897 (mixed port)'; proxy = 'http://127.0.0.1:7897' }
    '11119'  = @{ label = 'FIRSTHOP-11119'; proxy = 'http://127.0.0.1:11119' }
}

# ---------------------------------------------------------------- read-only facts

function Get-SystemProxyFacts {
    # Read-only.  The value is masked: only scheme/host/port may be reported.
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    try {
        $p = Get-ItemProperty -Path $k -ErrorAction Stop
        $server = [string]$p.ProxyServer
        return [ordered]@{
            enabled  = ([int]$p.ProxyEnable -eq 1)
            server   = if ($server) { Get-DiagMaskedEndpoint $server } else { '' }
            override = [bool]$p.ProxyOverride
        }
    }
    catch {
        return [ordered]@{ enabled = $null; server = ''; override = $false; error = 'registry_read_failed' }
    }
}

function Get-RouteFacts {
    # Which interface actually wins for an external destination?  Windows picks
    # the lowest (RouteMetric + InterfaceMetric), so both numbers are recorded.
    $rows = @()
    try {
        $routes = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop)
    }
    catch { $routes = @() }
    foreach ($r in $routes) {
        $adapter = $null
        try { $adapter = Get-NetAdapter -InterfaceIndex $r.InterfaceIndex -ErrorAction Stop } catch { }
        $desc = if ($adapter) { [string]$adapter.InterfaceDescription } else { '' }
        $isTun = [bool]($desc -match '(?i)\btun\b|sing-tun|utun|wintun|wireguard|tap-')
        $rows += [pscustomobject][ordered]@{
            interfaceIndex  = $r.InterfaceIndex
            interfaceAlias  = [string]$r.InterfaceAlias
            description     = $desc
            nextHop         = [string]$r.NextHop
            routeMetric     = [int]$r.RouteMetric
            interfaceMetric = [int]$r.InterfaceMetric
            totalMetric     = [int]$r.RouteMetric + [int]$r.InterfaceMetric
            tunnelLike      = $isTun
        }
    }
    $winner = $rows | Sort-Object totalMetric | Select-Object -First 1
    $fact = [ordered]@{
        defaultRoutes = @($rows)
        winner        = $winner
        winnerIsTunnel = if ($winner) { [bool]$winner.tunnelLike } else { $null }
        explanation   = $null
    }
    if ($winner -and $winner.tunnelLike) {
        $fact.explanation = ('every external IPv4 destination is routed into {0} (metric {1}); the domestic/foreign split therefore cannot happen at the Windows routing layer' -f $winner.interfaceAlias, $winner.totalMetric)
    }
    elseif ($winner) {
        $fact.explanation = ('external IPv4 traffic leaves through {0} (metric {1}), i.e. the physical path' -f $winner.interfaceAlias, $winner.totalMetric)
    }
    return $fact
}

function Get-ClashConfigFacts {
    # Read-only, whitelist-only YAML-lite parse.  Credential names and values
    # (secret/username/password/uuid) are never read into the result.
    $p = Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev\clash-verge.yaml'
    $fact = [ordered]@{
        path       = $p
        readable   = $false
        mode       = $null
        mixedPort  = $null
        ipv6       = $null
        tunEnable  = $null
        rules      = @()
        proxies    = @()
        proxyGroups = @()
        hasDnsBlock = $false
        note       = 'parsed with a whitelist; credential lines are skipped, never stored'
    }
    if (-not (Test-Path -LiteralPath $p)) {
        $fact.error = 'config_not_found'
        return $fact
    }
    try {
        $lines = @(Get-Content -LiteralPath $p -ErrorAction Stop)
    }
    catch {
        $fact.error = 'config_read_failed'
        return $fact
    }
    $fact.readable = $true
    $section = ''
    $curProxy = $null
    $curGroup = $null
    foreach ($line in $lines) {
        if ($line -match '^\s*#') { continue }
        if ($line -match '^\s*$') { continue }
        if ($line -match '^([A-Za-z0-9_-]+):\s*(.*)$') {
            $section = $Matches[1]
            $value = $Matches[2].Trim()
            switch ($section) {
                'mode' { $fact.mode = $value }
                'mixed-port' { $fact.mixedPort = $value }
                'ipv6' { $fact.ipv6 = $value }
                'dns' { $fact.hasDnsBlock = $true }
            }
            continue
        }
        switch ($section) {
            'tun' {
                if ($line -match '^\s+enable:\s*(\S+)') { $fact.tunEnable = $Matches[1] }
            }
            'rules' {
                if ($line -match '^\s*-\s*(.+?)\s*$') { $fact.rules += $Matches[1] }
            }
            'proxies' {
                if ($line -match '^\s*-\s*name:\s*(.+?)\s*$') {
                    $curProxy = [ordered]@{ name = ($Matches[1] -replace '^["'']|["'']$', ''); type = $null; server = $null; port = $null; dialerProxy = $null; udp = $null }
                    $fact.proxies += $curProxy
                }
                elseif ($curProxy -and $line -match '^\s+(type|server|port|dialer-proxy|udp):\s*(.+?)\s*$') {
                    switch ($Matches[1]) {
                        'type' { $curProxy.type = $Matches[2] }
                        'server' { $curProxy.server = $Matches[2] }
                        'port' { $curProxy.port = $Matches[2] }
                        'dialer-proxy' { $curProxy.dialerProxy = $Matches[2] }
                        'udp' { $curProxy.udp = $Matches[2] }
                    }
                }
            }
            'proxy-groups' {
                if ($line -match '^\s*-\s*name:\s*(.+?)\s*$') {
                    $curGroup = [ordered]@{ name = $Matches[1]; type = $null; members = @() }
                    $fact.proxyGroups += $curGroup
                }
                elseif ($curGroup -and $line -match '^\s+type:\s*(.+?)\s*$') { $curGroup.type = $Matches[1] }
                elseif ($curGroup -and $line -match '^\s+-\s*([^\s:]+)\s*$') { $curGroup.members += $Matches[1] }
            }
        }
    }
    return $fact
}

# ---------------------------------------------------------------- measurement

function Get-EgressFromBody {
    # One parser for the declared echo targets.  Returns the address the remote
    # service saw plus the Cloudflare trace fields when they exist.
    param([AllowNull()][string]$Body)
    $o = [ordered]@{ ip = $null; loc = $null; colo = $null; warp = $null }
    if (-not $Body) { return $o }
    if ($Body -match '(?i)\bip=(\d{1,3}(?:\.\d{1,3}){3})\b') { $o.ip = $Matches[1] }
    elseif ($Body -match '(\d{1,3}(?:\.\d{1,3}){3})') { $o.ip = $Matches[1] }
    if ($Body -match '(?i)\bloc=([A-Z]{2})\b') { $o.loc = $Matches[1] }
    if ($Body -match '(?i)\bcolo=([A-Z0-9]{3})\b') { $o.colo = $Matches[1] }
    if ($Body -match '(?i)\bwarp=(\w+)') { $o.warp = $Matches[1] }
    return $o
}

$planned = @()
foreach ($pathKey in $Paths) {
    if (-not $pathMap.ContainsKey($pathKey)) {
        Write-Warning ("unknown path '{0}' ignored (allowed: {1})" -f $pathKey, (($pathMap.Keys | Sort-Object) -join ','))
        continue
    }
    foreach ($t in $ForeignTargets) { $planned += [pscustomobject]@{ path = $pathKey; target = $t; class = 'FOREIGN' } }
    foreach ($t in $DomesticTargets) { $planned += [pscustomobject]@{ path = $pathKey; target = $t; class = 'DOMESTIC' } }
}

$measurements = @()
$evidenceTime = [datetimeoffset]::Now.ToString('o')
foreach ($p in $planned) {
    $def = $pathMap[$p.path]
    $runs = @()
    for ($i = 0; $i -lt $Samples; $i++) {
        $runs += Invoke-DiagProbe -Url $p.target -ProxyArg $def.proxy -TimeoutSec $TimeoutSec -ForceIPv4 -CaptureBody
    }
    $okRun = $runs | Where-Object { $_.ok } | Select-Object -First 1
    $ref = if ($okRun) { $okRun } else { $runs | Select-Object -First 1 }
    $eg = Get-EgressFromBody $ref.body
    $measurements += [pscustomobject][ordered]@{
        path        = $p.path
        pathLabel   = $def.label
        via         = $ref.via
        proxy       = $ref.proxy
        target      = $p.target
        targetClass = $p.class
        transport   = $ref.transport
        httpStatus  = $ref.httpStatus
        ok          = [bool]$okRun
        egressIp    = $eg.ip
        cfLoc       = $eg.loc
        cfColo      = $eg.colo
        totalMs     = if ($okRun) { [Math]::Round([double]$okRun.metrics.total * 1000, 0) } else { $null }
        observedAt  = [datetimeoffset]::Now.ToString('o')
        err         = if ($okRun) { '' } else { $ref.err }
    }
    Start-Sleep -Milliseconds 250   # deliberate pacing: no burst against the echo services
}

# ---------------------------------------------------------------- conclusion

$systemProxy = Get-SystemProxyFacts
$routeFacts = Get-RouteFacts
$clashFacts = if ($SkipConfigRead) { [ordered]@{ skipped = $true } } else { Get-ClashConfigFacts }

$measured = @($measurements | Where-Object { $_.ok -and $_.egressIp })
$distinct = @($measured | ForEach-Object { $_.egressIp } | Sort-Object -Unique)

$egressByPath = [ordered]@{}
foreach ($pathKey in $Paths) {
    if (-not $pathMap.ContainsKey($pathKey)) { continue }
    $rows = @($measurements | Where-Object { $_.path -eq $pathKey -and $_.egressIp })
    $egressByPath[$pathKey] = [ordered]@{
        domestic = @($rows | Where-Object { $_.targetClass -eq 'DOMESTIC' } | ForEach-Object { $_.egressIp } | Sort-Object -Unique)
        foreign  = @($rows | Where-Object { $_.targetClass -eq 'FOREIGN' } | ForEach-Object { $_.egressIp } | Sort-Object -Unique)
    }
}

# Decision points that can legitimately explain a domestic/foreign split.
$ruleEvidence = @()
if ($clashFacts.rules) {
    foreach ($r in @($clashFacts.rules)) {
        if ($r -match '(?i)GEOIP\s*,\s*CN\s*,\s*DIRECT') { $ruleEvidence += ('clash rule: {0}' -f $r) }
        elseif ($r -match '(?i)^MATCH\s*,\s*(\S+)') { $ruleEvidence += ('clash catch-all: {0}' -f $r) }
    }
}
if ($clashFacts.mode -and $clashFacts.mode -ne 'rule') {
    $ruleEvidence = @($ruleEvidence | Where-Object { $false })
}
if ($clashFacts.tunEnable -and $clashFacts.tunEnable -match '(?i)true') {
    $ruleEvidence += 'clash tun.enable=true (kernel-route interception)'
}
if ($routeFacts.winnerIsTunnel) {
    $ruleEvidence += ('ipv4 default route points at tunnel {0} (metric {1})' -f $routeFacts.winner.interfaceAlias, $routeFacts.winner.totalMetric)
}

$consistency = 'INCONSISTENT_UNKNOWN'
$reason = ''
if ($measured.Count -eq 0) {
    $reason = 'no egress IP was measured: every declared target failed on every path'
}
elseif ($distinct.Count -eq 1) {
    $consistency = 'CONSISTENT'
    $reason = ('every measured row reports the same egress IP {0}; there is no domestic/foreign split to explain' -f $distinct[0])
}
else {
    # A split is "by design" only when it is both observed and explained.
    $splitPaths = @()
    foreach ($pathKey in $egressByPath.Keys) {
        $d = @($egressByPath[$pathKey].domestic)
        $f = @($egressByPath[$pathKey].foreign)
        if ($d.Count -ge 1 -and $f.Count -ge 1 -and (($d -join ',') -ne ($f -join ','))) {
            $splitPaths += $pathKey
        }
    }
    if ($splitPaths.Count -gt 0 -and $ruleEvidence.Count -gt 0) {
        $consistency = 'SPLIT_BY_DESIGN'
        $reason = ('split observed on path(s) {0} and explained by: {1}' -f ($splitPaths -join ','), ($ruleEvidence -join ' | '))
    }
    elseif ($splitPaths.Count -gt 0) {
        $consistency = 'INCONSISTENT_UNKNOWN'
        $reason = ('egress differs on path(s) {0} but no decision point (rule / tun route) was found to explain it' -f ($splitPaths -join ','))
    }
    else {
        $consistency = 'INCONSISTENT_UNKNOWN'
        $reason = ('paths disagree with each other ({0}) without a domestic/foreign split inside any single path' -f ($distinct -join ', '))
    }
}

$result = [ordered]@{
    observedAt        = [datetimeoffset]::Now.ToString('o')
    tool              = 'path-report.ps1'
    readOnly          = $true
    contract          = Get-DiagContractInfo
    pathsPlanned      = @($Paths)
    targets           = [ordered]@{
        foreign  = @($ForeignTargets)
        domestic = @($DomesticTargets)
        note     = 'declared per run; nothing else is contacted, minimum 250 ms between requests'
    }
    systemProxy        = $systemProxy
    systemProxyNote    = 'curl does not read this setting; only the PROXY rows reflect an explicit -x hop. A browser does follow it.'
    routes            = $routeFacts
    clashConfig       = $clashFacts
    egressByPath      = $egressByPath
    measurements      = @($measurements)
    ruleEvidence      = @($ruleEvidence)
    conclusion        = [ordered]@{
        egressConsistency = $consistency
        reason            = $reason
        evidenceTime      = $evidenceTime
        perTarget         = @($measured | ForEach-Object {
                [ordered]@{
                    target     = $_.target
                    targetClass = $_.targetClass
                    path       = $_.pathLabel
                    egressIp   = $_.egressIp
                    observedAt = $_.observedAt
                }
            })
    }
}

$exitCode = if ($measured.Count -eq 0) { 3 } elseif ($measured.Count -eq $planned.Count * $Samples) { 0 } else { 2 }

if ($Json) { $result | ConvertTo-Json -Depth 10 }
else {
    Write-Host ''
    Write-Host ('  IPV4 EGRESS PATH REPORT   read-only   contract={0}/v{1}' -f $script:DiagContractName, $script:DiagContractVersion) -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * 100))
    Write-Host ('  system proxy : enabled={0} server={1}   (curl ignores this; browsers follow it)' -f $systemProxy.enabled, $systemProxy.server) -ForegroundColor DarkGray
    if ($routeFacts.winner) {
        Write-Host ('  ipv4 default : {0} -> {1} (metric {2})  tunnel={3}' -f $routeFacts.winner.interfaceAlias, $routeFacts.winner.nextHop, $routeFacts.winner.totalMetric, $routeFacts.winnerIsTunnel) -ForegroundColor DarkGray
    }
    if ($clashFacts.readable) {
        Write-Host ('  clash config : mode={0} mixed-port={1} tun.enable={2} ipv6={3}' -f $clashFacts.mode, $clashFacts.mixedPort, $clashFacts.tunEnable, $clashFacts.ipv6) -ForegroundColor DarkGray
    }
    Write-Host ''
    $measurements | Format-Table @{n = 'path'; e = { $_.path } },
        @{n = 'class'; e = { $_.targetClass } }, @{n = 'target'; e = { $_.target -replace '^https?://', '' } },
        @{n = 'via'; e = { $_.via } }, @{n = 'transport'; e = { $_.transport } },
        @{n = 'http'; e = { $_.httpStatus } }, @{n = 'egressIp'; e = { $_.egressIp } },
        @{n = 'loc'; e = { $_.cfLoc } }, @{n = 'ms'; e = { $_.totalMs } } -AutoSize |
        Out-String -Width 160 | Write-Host
    $c = switch ($consistency) { 'CONSISTENT' { 'Green' } 'SPLIT_BY_DESIGN' { 'Yellow' } default { 'Red' } }
    Write-Host ('  egressConsistency = {0}' -f $consistency) -ForegroundColor $c
    Write-Host ('  reason            : {0}' -f $reason)
    Write-Host ('  evidence time     : {0}' -f $evidenceTime) -ForegroundColor DarkGray
    Write-Host ''
}

# 0 every planned probe produced an egress IP, 2 partial, 3 nothing measured.
exit $exitCode
