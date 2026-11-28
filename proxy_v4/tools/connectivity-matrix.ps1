#Requires -Version 5.1
<#
.SYNOPSIS  Layered application-path probe (read-only, no credentials, no cert bypass).
.DESCRIPTION
  Measures, per target and per sample, the stages an application actually depends on:
      DNS -> TCP(CONNECT) -> TLS -> first byte -> full body -> repeat
  and optionally a synthetic upload (a random buffer, never user data).

  Design rules:
    * never disables certificate validation (a "pass" must mean a real TLS success)
    * never sends real files, credentials, cookies or account data
    * reports each stage separately so "page opens but XHR fails" is classifiable
    * a sample only counts as PASS when the HTTP status is 2xx/3xx

  Exit: 0 all samples passed, 2 partial, 3 failed/unusable.

.EXAMPLE
  .\connectivity-matrix.ps1 -Proxy http://127.0.0.1:11119
  .\connectivity-matrix.ps1 -Proxy http://127.0.0.1:7897 -Samples 5 -Json
  .\connectivity-matrix.ps1 -Proxy http://127.0.0.1:11119 -PostUrl https://postman-echo.com/post
#>
[CmdletBinding()]
param(
    [string]$Proxy = 'http://127.0.0.1:7897',
    [switch]$Direct,
    [string[]]$Targets = @('https://www.google.com', 'https://www.baidu.com', 'https://chatgpt.com'),
    [ValidateRange(1, 20)][int]$Samples = 3,
    [string]$PostUrl = '',
    [int]$TimeoutSec = 20,
    [switch]$Json
)
$ErrorActionPreference = 'Continue'

function Invoke-CurlStage {
    param([string]$Url, [string]$Method = 'GET', [string]$Body = $null, [string]$ProxyArg)
    # -w metrics are parsed instead of scraping stderr; no -k / --insecure anywhere.
    $fmt = 'code=%{http_code};dns=%{time_namelookup};conn=%{time_connect};tls=%{time_appconnect};ttfb=%{time_starttransfer};total=%{time_total};dl=%{size_download}'
    $cargs = @('-sS', '-m', "$TimeoutSec", '-o', 'NUL', '-w', $fmt)
    if ($ProxyArg) { $cargs += @('-x', $ProxyArg) } else { $cargs += @('--noproxy', '*') }
    if ($Method -eq 'POST') { $cargs += @('-X', 'POST', '--data-binary', $Body) }
    $cargs += $Url
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $raw = & curl.exe @cargs 2>&1; $rc = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
    $text = ($raw -join ' ')
    $o = [ordered]@{ ok = $false; rc = $rc; code = $null; dns = $null; conn = $null; tls = $null; ttfb = $null; total = $null; dl = $null; err = '' }
    if ($text -match 'code=(\d+);dns=([\d\.]+);conn=([\d\.]+);tls=([\d\.]+);ttfb=([\d\.]+);total=([\d\.]+);dl=(\d+)') {
        $o.code = [int]$Matches[1]; $o.dns = [double]$Matches[2]; $o.conn = [double]$Matches[3]
        $o.tls = [double]$Matches[4]; $o.ttfb = [double]$Matches[5]; $o.total = [double]$Matches[6]; $o.dl = [int]$Matches[7]
        $o.ok = ($rc -eq 0 -and $o.code -ge 200 -and $o.code -lt 400)
    }
    else {
        $o.err = ($text -replace '\s+', ' ').Trim()
        if ($o.err.Length -gt 120) { $o.err = $o.err.Substring(0, 120) }
    }
    return [pscustomobject]$o
}

function Get-Percentile($values, [double]$q) {
    if (-not $values -or $values.Count -eq 0) { return $null }
    $s = @($values | Sort-Object)
    $i = [Math]::Min($s.Count - 1, [int][Math]::Floor($s.Count * $q))
    return [Math]::Round($s[$i] * 1000, 0)   # ms
}

$proxyArg = if ($Direct) { '' } else { $Proxy }
$rows = @()
foreach ($t in $Targets) {
    $stageRuns = 1..$Samples | ForEach-Object { Invoke-CurlStage -Url $t -ProxyArg $proxyArg }
    $okN = @($stageRuns | Where-Object { $_.ok }).Count
    $totals = @($stageRuns | Where-Object { $_.ok } | ForEach-Object { $_.total })
    $tlss = @($stageRuns | Where-Object { $_.ok } | ForEach-Object { $_.tls })
    $firstErr = ($stageRuns | Where-Object { -not $_.ok } | Select-Object -First 1).err
    $rows += [pscustomobject]@{
        target = ($t -replace '^https?://', '')
        pass = $okN; fail = ($Samples - $okN)
        rate = [Math]::Round(100.0 * $okN / $Samples, 0)
        tlsP50Ms = Get-Percentile $tlss 0.5
        totalP50Ms = Get-Percentile $totals 0.5
        totalP95Ms = Get-Percentile $totals 0.95
        bytes = ($stageRuns | Where-Object { $_.ok } | Select-Object -First 1).dl
        err = $firstErr
    }
}

$upload = $null
if ($PostUrl) {
    # synthetic payload only: 8 KB of random bytes, never user data
    $buf = New-Object byte[] 8192
    (New-Object System.Random).NextBytes($buf)
    $b64 = [Convert]::ToBase64String($buf)
    $up = Invoke-CurlStage -Url $PostUrl -Method POST -Body ("payload=" + $b64) -ProxyArg $proxyArg
    $upload = [pscustomobject]@{ url = $PostUrl; ok = $up.ok; code = $up.code; bytes = $up.dl; err = $up.err }
}

$totalPass = ($rows | Measure-Object pass -Sum).Sum
$totalReq = ($rows | Measure-Object pass, fail -Sum)
$sumPass = ($rows | Measure-Object pass -Sum).Sum
$sumFail = ($rows | Measure-Object fail -Sum).Sum

$result = [ordered]@{
    observedAt = [datetimeoffset]::Now.ToString('o')
    path = if ($Direct) { 'DIRECT' } else { $Proxy }
    samplesPerTarget = $Samples
    targets = $rows
    upload = $upload
    summary = [ordered]@{
        pass = $sumPass; fail = $sumFail
        rate = if (($sumPass + $sumFail) -gt 0) { [Math]::Round(100.0 * $sumPass / ($sumPass + $sumFail), 0) } else { 0 }
    }
    scope = 'IPv4 TCP/HTTPS only. UDP, IPv6 and the real browser stack are NOT covered by this probe.'
}

if ($Json) { $result | ConvertTo-Json -Depth 6 }
else {
    Write-Host ''
    Write-Host ("  APPLICATION-PATH MATRIX   path={0}   samples/target={1}" -f $result.path, $Samples) -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * 84))
    $rows | Format-Table -AutoSize | Out-String -Width 140 | Write-Host
    if ($upload) { Write-Host ("  upload(synthetic 8KB): ok={0} code={1} {2}" -f $upload.ok, $upload.code, $upload.err) }
    $c = if ($result.summary.rate -ge 100) { 'Green' } elseif ($result.summary.rate -gt 0) { 'Yellow' } else { 'Red' }
    Write-Host ("  RESULT {0}/{1} ({2}%)" -f $sumPass, ($sumPass + $sumFail), $result.summary.rate) -ForegroundColor $c
    Write-Host ("  note: {0}" -f $result.scope) -ForegroundColor DarkGray
    Write-Host ''
}

if ($sumFail -eq 0) { exit 0 } elseif ($sumPass -gt 0) { exit 2 } else { exit 3 }
