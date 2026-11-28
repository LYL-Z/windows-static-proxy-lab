#Requires -Version 5.1
<#
.SYNOPSIS  Layered application-path probe (read-only, no credentials, no cert bypass).
.DESCRIPTION
  Stages measured per target per sample:
      DNS -> TCP(CONNECT) -> TLS -> first byte -> body -> download bytes
  plus an optional synthetic upload (random buffer, never user data).

  Guarantees:
    * never disables certificate validation (-k / --insecure are never used)
    * never sends real files, credentials, cookies or account data
    * curl exit code, stderr text and the -w metrics are captured SEPARATELY, so a
      failure never loses its evidence (a 502 with timings still shows the 502)
    * the optional upload is part of the final verdict, not a side note
    * proxy environment variables are reported by NAME and PRESENCE only; their
      values are masked (scheme://***:***@host:port), never printed verbatim

  Proxy environment handling is measured, not assumed.  curl honours NO_PROXY /
  no_proxy even when -x is given: -x is NOT an override.  Locally measured with a
  loopback 502 proxy and a loopback origin (curl 8.x):
      -x proxy, NO_PROXY=127.0.0.1   -> HTTP 200 from the origin (proxy bypassed)
      -x proxy, NO_PROXY cleared     -> HTTP 502 from the proxy (proxy used)
      -x proxy, --noproxy=           -> HTTP 502 from the proxy (list disabled)
  Therefore a proxied run removes NO_PROXY / no_proxy from this process before any
  curl child is started AND passes --noproxy= explicitly.  -Direct uses --noproxy "*".

  Scope is stated, not implied: IPv4 unless -ForceIPv4 is off, DNS resolved by the
  proxy itself (not tested locally) when a proxy is used.

  Exit: 0 all GET stages passed and the upload passed (when requested)
        2 partial: some GET passed, or the upload (only) failed
        3 unusable: no GET succeeded at all, regardless of the upload

.EXAMPLE
  .\connectivity-matrix.ps1 -Proxy http://127.0.0.1:11119
  .\connectivity-matrix.ps1 -Proxy http://127.0.0.1:7897 -Samples 5 -Json
  .\connectivity-matrix.ps1 -Direct -Targets http://127.0.0.1:18804/ok -PostUrl http://127.0.0.1:18804/upload
#>
[CmdletBinding()]
param(
    [string]$Proxy = 'http://127.0.0.1:7897',
    [switch]$Direct,
    [string[]]$Targets = @('https://www.google.com', 'https://www.baidu.com', 'https://chatgpt.com'),
    [ValidateRange(1, 20)][int]$Samples = 3,
    [string]$PostUrl = '',
    [int]$TimeoutSec = 20,
    [switch]$ForceIPv4,
    [switch]$Json
)
$ErrorActionPreference = 'Continue'

function Hide-UserInfo {
    # F64: strip userinfo from anything that ends up in the report.
    param([string]$Text)
    if (-not $Text) { return $Text }
    return ($Text -replace '(?i)([a-z][a-z0-9+.-]*://)[^/\s@]*@', '$1***:***@')
}

function Get-MaskedProxyEndpoint {
    # F64: never print a proxy value verbatim; keep only scheme, a masked userinfo
    # marker and host:port.
    param([string]$Value)
    if (-not $Value) { return '' }
    $u = $null
    if ([Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$u)) {
        $auth = if ($u.UserInfo) { '***:***@' } else { '' }
        $port = if ($u.IsDefaultPort) { '' } else { ':' + $u.Port }
        return ('{0}://{1}{2}{3}' -f $u.Scheme, $auth, $u.Host, $port)
    }
    return '***'
}

function Get-ProxyEnvFacts {
    # F50/F64: these variables change what curl does unless explicitly overridden.
    # Report name + presence only; the value is masked, and NO_PROXY is never echoed.
    $o = [ordered]@{}
    foreach ($n in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY', 'http_proxy', 'https_proxy', 'no_proxy')) {
        $v = [Environment]::GetEnvironmentVariable($n)
        if (-not $v) {
            $o[$n] = [ordered]@{ present = $false }
            continue
        }
        if ($n -match '^no_proxy$') {
            $o[$n] = [ordered]@{
                present = $true
                valueMasked = '***'
                entries = @($v -split ',' | Where-Object { $_ -ne '' }).Count
            }
        }
        else {
            $o[$n] = [ordered]@{
                present = $true
                valueMasked = (Get-MaskedProxyEndpoint $v)
                hasCredentials = [bool]($v -match '://[^/\s@]*@')
            }
        }
    }
    return $o
}

function Get-ErrorKind {
    param([int]$Rc, [string]$ErrText)
    # deterministic classification from curl's own exit code first
    switch ($Rc) {
        0 { return 'OK' }
        6 { return 'DNS_FAIL' }
        7 { return 'CONNECT_REFUSED' }
        28 { return 'TIMEOUT' }
        35 { return 'TLS_FAIL' }
        52 { return 'EMPTY_REPLY' }
        56 { return 'RECV_FAIL' }
        60 { return 'CERT_FAIL' }
    }
    if ($ErrText -match 'schannel|SSL|TLS') { return 'TLS_FAIL' }
    if ($ErrText -match 'Empty reply') { return 'EMPTY_REPLY' }
    if ($ErrText -match 'refused') { return 'CONNECT_REFUSED' }
    if ($ErrText -match 'timed out') { return 'TIMEOUT' }
    return 'OTHER'
}

function Invoke-CurlStage {
    param([string]$Url, [string]$Method = 'GET', [string]$Body = $null, [string]$ProxyArg)
    $fmt = 'code=%{http_code};dns=%{time_namelookup};conn=%{time_connect};tls=%{time_appconnect};ttfb=%{time_starttransfer};total=%{time_total};dl=%{size_download}'
    $cargs = @('-sS', '-m', "$TimeoutSec", '-o', 'NUL', '-w', $fmt)
    if ($ForceIPv4) { $cargs += '-4' }
    if ($ProxyArg) {
        # F63: -x does not override NO_PROXY.  --noproxy= disables the no-proxy list
        # explicitly (measured); the matrix process also clears NO_PROXY/no_proxy.
        $cargs += @('-x', $ProxyArg, '--noproxy=')
    }
    else {
        $cargs += @('--noproxy', '*')
    }
    if ($Method -eq 'POST') { $cargs += @('-X', 'POST', '--data-binary', $Body) }
    $cargs += $Url

    $errFile = [IO.Path]::GetTempFileName()
    try {
        $raw = & curl.exe @cargs 2> $errFile
        $rc = $LASTEXITCODE
        $errText = ''
        try { $errText = (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue) } catch { }
        if ($null -eq $errText) { $errText = '' }
        $errText = (([string]::Join(' ', @($errText))) -replace '\s+', ' ').Trim()
        $errText = Hide-UserInfo $errText
    }
    finally { Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue }

    $metrics = ($raw -join ' ')
    $o = [ordered]@{
        ok = $false; rc = $rc; kind = (Get-ErrorKind -Rc $rc -ErrText $errText)
        code = $null; dns = $null; conn = $null; tls = $null; ttfb = $null; total = $null; dl = $null
        err = $errText
    }
    if ($metrics -match 'code=(\d+);dns=([\d\.]+);conn=([\d\.]+);tls=([\d\.]+);ttfb=([\d\.]+);total=([\d\.]+);dl=(\d+)') {
        $o.code = [int]$Matches[1]; $o.dns = [double]$Matches[2]; $o.conn = [double]$Matches[3]
        $o.tls = [double]$Matches[4]; $o.ttfb = [double]$Matches[5]; $o.total = [double]$Matches[6]; $o.dl = [int]$Matches[7]
    }
    # an HTTP status is only a pass when curl itself succeeded
    $o.ok = ($rc -eq 0 -and $o.code -ge 200 -and $o.code -lt 400)
    if ($rc -eq 0 -and -not $o.ok) {
        # an HTTP-level rejection is not "OK": keep the status as the classification
        $o.kind = if ($o.code) { 'HTTP_' + $o.code } else { 'EMPTY_REPLY' }
        if (-not $o.err) { $o.err = ("HTTP {0}" -f $o.code) }   # F47: never fail without evidence
    }
    return [pscustomobject]$o
}

function Get-Percentile($values, [double]$q) {
    if (-not $values -or $values.Count -eq 0) { return $null }
    $s = @($values | Sort-Object)
    $i = [Math]::Min($s.Count - 1, [int][Math]::Floor($s.Count * $q))
    return [Math]::Round($s[$i] * 1000, 0)
}

$proxyArg = if ($Direct) { '' } else { $Proxy }

# F63/F64: capture the environment facts (masked) BEFORE touching anything.
$envFacts = Get-ProxyEnvFacts
$envOverriddenBy = if ($Direct) { '--noproxy "*"' } else { '-x <proxy> + --noproxy=; NO_PROXY/no_proxy cleared in this process' }

# F63: a proxied measurement is only valid when NO_PROXY cannot bypass the proxy.
$savedNoProxy = [Environment]::GetEnvironmentVariable('NO_PROXY')
$savedNoProxyLower = [Environment]::GetEnvironmentVariable('no_proxy')
$clearedNoProxy = $false
if (-not $Direct) {
    Remove-Item Env:NO_PROXY -ErrorAction SilentlyContinue
    Remove-Item Env:no_proxy -ErrorAction SilentlyContinue
    $clearedNoProxy = $true
}

$rows = @()
$upload = $null
try {
    foreach ($t in $Targets) {
        $stageRuns = 1..$Samples | ForEach-Object { Invoke-CurlStage -Url $t -ProxyArg $proxyArg }
        $okRuns = @($stageRuns | Where-Object { $_.ok })
        $badRuns = @($stageRuns | Where-Object { -not $_.ok })
        $rows += [pscustomobject]@{
            target = (Hide-UserInfo $t) -replace '^https?://', ''
            pass = $okRuns.Count; fail = $badRuns.Count
            rate = [Math]::Round(100.0 * $okRuns.Count / $Samples, 0)
            tlsP50Ms = Get-Percentile @($okRuns | ForEach-Object { $_.tls }) 0.5
            totalP50Ms = Get-Percentile @($okRuns | ForEach-Object { $_.total }) 0.5
            totalP95Ms = Get-Percentile @($okRuns | ForEach-Object { $_.total }) 0.95
            bytes = ($okRuns | Select-Object -First 1).dl
            kind = ($badRuns | Select-Object -First 1).kind
            err = ($badRuns | Select-Object -First 1).err
        }
    }

    if ($PostUrl) {
        $buf = New-Object byte[] 8192
        (New-Object System.Random).NextBytes($buf)
        $up = Invoke-CurlStage -Url $PostUrl -Method POST -Body ('payload=' + [Convert]::ToBase64String($buf)) -ProxyArg $proxyArg
        $upload = [pscustomobject]@{ url = Hide-UserInfo $PostUrl; ok = $up.ok; code = $up.code; kind = $up.kind; bytes = $up.dl; err = $up.err }
    }
}
finally {
    if ($clearedNoProxy) {
        if ($null -ne $savedNoProxy) { [Environment]::SetEnvironmentVariable('NO_PROXY', $savedNoProxy, 'Process') }
        if ($null -ne $savedNoProxyLower) { [Environment]::SetEnvironmentVariable('no_proxy', $savedNoProxyLower, 'Process') }
    }
}

$sumPass = ($rows | Measure-Object pass -Sum).Sum
$sumFail = ($rows | Measure-Object fail -Sum).Sum
$uploadFailed = ($upload -and -not $upload.ok)

$result = [ordered]@{
    observedAt = [datetimeoffset]::Now.ToString('o')
    path = if ($Direct) { 'DIRECT' } else { Get-MaskedProxyEndpoint $Proxy }
    curl = ((& curl.exe --version 2>$null | Select-Object -First 1) -join '')
    proxyEnv = $envFacts
    envOverriddenBy = $envOverriddenBy
    noProxyHandling = [ordered]@{
        proxied = -not $Direct
        noProxyClearedInChild = $clearedNoProxy
        mechanism = if ($Direct) { '--noproxy "*"' } else { 'NO_PROXY/no_proxy removed for the probe + --noproxy=' }
        basis = 'measured with local fixtures by tests/incidents/invoke-inc-checks.ps1; -x alone does not override NO_PROXY'
    }
    samplesPerTarget = $Samples
    targets = $rows
    upload = $upload
    summary = [ordered]@{
        pass = $sumPass; fail = $sumFail; uploadFailed = [bool]$uploadFailed
        rate = if (($sumPass + $sumFail) -gt 0) { [Math]::Round(100.0 * $sumPass / ($sumPass + $sumFail), 0) } else { 0 }
    }
    coverage = [ordered]@{
        ipVersion = if ($ForceIPv4) { 'IPv4 enforced (-4)' } else { 'IPv4 preferred; IPv6 not excluded' }
        dns = if ($Direct) { 'local resolver' } else { 'resolved by the proxy (remote); local DNS not tested' }
        udp = 'NOT_TESTED'
        webrtc = 'NOT_TESTED'
        browserStack = 'NOT_TESTED - this probe is not a browser'
    }
}

if ($Json) { $result | ConvertTo-Json -Depth 6 }
else {
    Write-Host ''
    Write-Host ("  APPLICATION-PATH MATRIX   path={0}   samples/target={1}" -f $result.path, $Samples) -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * 92))
    $rows | Format-Table -AutoSize | Out-String -Width 150 | Write-Host
    if ($upload) {
        $uc = if ($upload.ok) { 'Green' } else { 'Red' }
        Write-Host ("  upload(synthetic 8KB): ok={0} code={1} kind={2} {3}" -f $upload.ok, $upload.code, $upload.kind, $upload.err) -ForegroundColor $uc
    }
    $c = if ($result.summary.rate -ge 100 -and -not $uploadFailed) { 'Green' } elseif ($result.summary.rate -gt 0) { 'Yellow' } else { 'Red' }
    Write-Host ("  RESULT {0}/{1} ({2}%){3}" -f $sumPass, ($sumPass + $sumFail), $result.summary.rate,
        $(if ($uploadFailed) { '  + UPLOAD FAILED' } else { '' })) -ForegroundColor $c
    Write-Host ("  dns: {0}   ip: {1}" -f $result.coverage.dns, $result.coverage.ipVersion) -ForegroundColor DarkGray
    Write-Host ("  not covered: {0}" -f (($result.coverage.Keys | Where-Object { $result.coverage[$_] -like 'NOT_TESTED*' }) -join ', ')) -ForegroundColor DarkGray
    Write-Host ''
}

# F67: exit code is a three-way verdict and "everything failed" is never partial.
#   0 = every GET passed and the upload (when requested) passed
#   3 = no GET passed at all (even if the upload somehow passed)
#   2 = some GET passed, or every GET passed but the upload failed
if (($sumPass + $sumFail) -eq 0) { exit 3 }
elseif ($sumPass -eq 0) { exit 3 }
elseif ($sumFail -eq 0 -and -not $uploadFailed) { exit 0 }
else { exit 2 }
