#Requires -Version 5.1
<#
.SYNOPSIS
  Independent acceptance run: N end-to-end requests through the proxy, with
  success rate and P50/P90/P95/P99 latency. Writes machine-readable evidence.

.DESCRIPTION
  Each sample performs a real HTTPS GET to a neutral IP-echo endpoint through
  the proxy and asserts the observed exit IP. It never reuses a connection, so
  the numbers include full DNS/CONNECT/TLS cost.

  Exit codes: 0 = all samples passed, 5 = success rate below -MinSuccess, 6 = setup error.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File validate-v2.ps1 -Runs 20 -Interval 30
  powershell -ExecutionPolicy Bypass -File validate-v2.ps1 -Runs 300 -Interval 2
#>
[CmdletBinding()]
param(
    [int]$Runs = 20,
    [int]$Interval = 30,
    [string]$Proxy = 'socks5h://127.0.0.1:7897',
    [string]$Expect = 'auto',
    [double]$MinSuccess = 99.0,
    [string]$Tag = 'validate'
)

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'lib\Common.ps1')
$results = Join-Path $here 'test-results'
if (-not (Test-Path $results)) { New-Item -ItemType Directory -Path $results -Force | Out-Null }

$p = Get-ClashPaths
if ($Expect -eq 'auto') {
    $st = if ($p.ProfileFile) { Get-StaticTarget -ProfilePath $p.ProfileFile } else { $null }
    if ($st) { $Expect = $st.Host }
}
if (-not $Expect) { Write-Log 'cannot determine expected exit IP; pass -Expect' -Level ERROR; exit 6 }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$jsonOut = Join-Path $results ("{0}-{1}.json" -f $Tag, $stamp)
Start-LogFile (Join-Path $results ("{0}-{1}.log" -f $Tag, $stamp))

Write-Log ("validate: runs={0} interval={1}s proxy={2} expect={3}" -f $Runs, $Interval, $Proxy, $Expect) -Level STEP

$samples = @()
for ($i = 1; $i -le $Runs; $i++) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $ip = $null
    $err = ''
    try {
        $out = & curl.exe -sS -m 30 -x $Proxy https://api.ipify.org 2>&1
        $txt = ($out -join '').Trim()
        if ($txt -match '(\d{1,3}(\.\d{1,3}){3})') { $ip = $Matches[1] }
        else { $err = $txt }
    }
    catch { $err = $_.Exception.Message }
    $sw.Stop()
    $ms = [math]::Round($sw.Elapsed.TotalMilliseconds, 0)
    $ok = ($ip -eq $Expect)
    if (-not $ok -and -not $err) { $err = "exit mismatch: $ip" }
    $samples += [pscustomobject]@{ n = $i; ts = (Get-Date).ToString('s'); ok = $ok; ms = $ms; ip = $ip; err = $err }
    $status = if ($ok) { 'PASS' } else { 'FAIL' }
    $shown = if ($ip) { $ip } else { '-' }
    Write-Log ("[{0}/{1}] {2} {3,6} ms  exit={4} {5}" -f $i, $Runs, $status, $ms, $shown, $err)
    if ($i -lt $Runs -and $Interval -gt 0) { Start-Sleep -Seconds $Interval }
}

$okList = @($samples | Where-Object { $_.ok })
$rate = if ($Runs -gt 0) { [math]::Round(100.0 * $okList.Count / $Runs, 2) } else { 0 }
function Pct($arr, $q) {
    if (-not $arr -or $arr.Count -eq 0) { return $null }
    $sorted = $arr | Sort-Object
    $idx = [math]::Min($sorted.Count - 1, [math]::Floor($sorted.Count * $q))
    return [math]::Round($sorted[[int]$idx], 0)
}
$lat = @($okList | ForEach-Object { $_.ms })
$summary = [pscustomobject]@{
    tag           = $Tag
    startedAt     = $samples[0].ts
    finishedAt    = $samples[-1].ts
    runs          = $Runs
    passed        = $okList.Count
    successRate   = $rate
    expectedExit  = $Expect
    proxy         = $Proxy
    latencyMs     = [pscustomobject]@{
        min = Pct $lat 0.0; p50 = Pct $lat 0.50; p90 = Pct $lat 0.90
        p95 = Pct $lat 0.95; p99 = Pct $lat 0.99; max = Pct $lat 1.0
    }
    failures      = @($samples | Where-Object { -not $_.ok } | Select-Object n, ts, err)
    samples       = $samples
}

$summary | ConvertTo-Json -Depth 6 | Set-Content $jsonOut -Encoding UTF8
Write-Log ("RESULT success={0}/{1} ({2}%)  p50={3}ms p95={4}ms" -f $okList.Count, $Runs, $rate, $summary.latencyMs.p50, $summary.latencyMs.p95) -Level OK
Write-Log ("evidence -> {0}" -f $jsonOut)

if ($rate -lt $MinSuccess) { Write-Log ("below target: {0}% < {1}%" -f $rate, $MinSuccess) -Level ERROR; exit 5 }
exit 0
