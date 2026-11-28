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
    * proxy environment variables are reported, and -x/--noproxy override them explicitly

  Scope is stated, not implied: IPv4 unless -ForceIPv4 is off, DNS resolved by the
  proxy itself (not tested locally) when a proxy is used.

  Exit: 0 all stages passed, 2 partial, 3 unusable.

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

function Get-ProxyEnvFacts {
    # F50: these variables change what curl does unless explicitly overridden.
    $o = [ordered]@{}
    foreach ($n in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY', 'http_proxy', 'https_proxy', 'no_proxy')) {
        $v = [Environment]::GetEnvironmentVariable($n)
        if ($v) { $o[$n] = $v }
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
    if ($ProxyArg) { $cargs += @('-x', $ProxyArg) } else { $cargs += @('--noproxy', '*') }
    if ($Method -eq 'POST') { $cargs += @('-X', 'POST', '--data-binary', $Body) }
    $cargs += $Url

    $errFile = [IO.Path]::GetTempFileName()
    try {
        $raw = & curl.exe @cargs 2> $errFile
        $rc = $LASTEXITCODE
        $errText = ''
        try { $errText = (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue) } catch { }
        if ($null -eq $errText) { $errText = '' }
        $errText = ($errText -replace '\s+', ' ').Trim()
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
    if (-not $o.ok -and -not $o.err -and $o.code) {
        $o.err = ("HTTP {0}" -f $o.code)      # F47: never return a failure without evidence
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
$rows = @()
foreach ($t in $Targets) {
    $stageRuns = 1..$Samples | ForEach-Object { Invoke-CurlStage -Url $t -ProxyArg $proxyArg }
    $okRuns = @($stageRuns | Where-Object { $_.ok })
    $badRuns = @($stageRuns | Where-Object { -not $_.ok })
    $rows += [pscustomobject]@{
        target = ($t -replace '^https?://', '')
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

$upload = $null
if ($PostUrl) {
    $buf = New-Object byte[] 8192
    (New-Object System.Random).NextBytes($buf)
    $up = Invoke-CurlStage -Url $PostUrl -Method POST -Body ('payload=' + [Convert]::ToBase64String($buf)) -ProxyArg $proxyArg
    $upload = [pscustomobject]@{ url = $PostUrl; ok = $up.ok; code = $up.code; kind = $up.kind; bytes = $up.dl; err = $up.err }
}

$sumPass = ($rows | Measure-Object pass -Sum).Sum
$sumFail = ($rows | Measure-Object fail -Sum).Sum
$uploadFailed = ($upload -and -not $upload.ok)

$result = [ordered]@{
    observedAt = [datetimeoffset]::Now.ToString('o')
    path = if ($Direct) { 'DIRECT' } else { $Proxy }
    proxyEnv = Get-ProxyEnvFacts
    envOverriddenBy = if ($Direct) { '--noproxy *' } else { '-x <proxy> (overrides *_PROXY)' }
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

# F46: a failed upload must not produce a full-success exit code
if ($sumFail -eq 0 -and -not $uploadFailed) { exit 0 }
elseif ($sumPass -gt 0 -or $uploadFailed) { exit 2 }
else { exit 3 }
