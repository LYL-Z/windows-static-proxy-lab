#Requires -Version 5.1
<#
.SYNOPSIS  Layered application-path probe (read-only, no credentials, no cert bypass).
.DESCRIPTION
  One probe core: this script shares tools/diag-contract.ps1 with cab-doctor.ps1
  (error enum, redaction, transport/httpStatus semantics, exit codes, NO_PROXY
  handling).  No probe logic is duplicated here any more.

  Stages measured per target per sample:
      DNS -> TCP(CONNECT) -> TLS -> first byte -> body -> download bytes
  plus an optional synthetic upload (random buffer, never user data).

  Guarantees:
    * never disables certificate validation (-k / --insecure are never used)
    * never sends real files, credentials, cookies or account data
    * curl exit code, stderr and the -w metrics are captured SEPARATELY, so a
      failure never loses its evidence (a 502 with timings still shows the 502)
    * transport (curl exit-code class) and httpStatus (the HTTP status seen) are
      different fields: a 500 is transport=OK, httpStatus=500, ok=$false and is
      never counted as a pass
    * the optional upload is part of the final verdict, not a side note
    * proxy environment variables are reported by NAME and PRESENCE only; their
      values are masked (scheme://***:***@host:port), never printed verbatim

  Proxy environment handling is measured, not assumed (basis recorded by
  tests/incidents/invoke-inc-checks.ps1): curl honours NO_PROXY/no_proxy even
  when -x is given, so -x is NOT an override.  The shared probe clears
  NO_PROXY/no_proxy for every proxied curl child AND passes --noproxy=.
  -Direct uses --noproxy "*".  noProxyHandling.basis in -Json records this.

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

$contractFile = Join-Path $PSScriptRoot 'diag-contract.ps1'
if (-not (Test-Path -LiteralPath $contractFile)) {
    Write-Error ("diag-contract.ps1 not found next to this script: {0}" -f $contractFile)
    exit 3
}
. $contractFile

$proxyArg = if ($Direct) { '' } else { $Proxy }

# Environment facts are captured (masked) before anything is measured.
$envFacts = Get-DiagProxyEnvFacts
$envOverriddenBy = if ($Direct) { $script:DiagNoProxyMechanismDirect } else { '-x <proxy> + --noproxy=; NO_PROXY/no_proxy cleared for the probe process' }

$rows = @()
$allRuns = @()
$upload = $null
foreach ($t in $Targets) {
    $stageRuns = @(1..$Samples | ForEach-Object {
        Invoke-DiagProbe -Url $t -ProxyArg $proxyArg -TimeoutSec $TimeoutSec -ForceIPv4:$ForceIPv4
    })
    $allRuns += $stageRuns
    $okRuns = @($stageRuns | Where-Object { $_.ok })
    $badRuns = @($stageRuns | Where-Object { -not $_.ok })
    $firstBad = $badRuns | Select-Object -First 1
    $rows += [pscustomobject][ordered]@{
        target     = (Hide-DiagUserInfo $t) -replace '^https?://', ''
        state      = $script:DiagState.MEASURED
        pass       = $okRuns.Count
        fail       = $badRuns.Count
        rate       = [Math]::Round(100.0 * $okRuns.Count / $Samples, 0)
        tlsP50Ms   = Get-DiagPercentileMs @($okRuns | ForEach-Object { $_.metrics.tls }) 0.5
        totalP50Ms = Get-DiagPercentileMs @($okRuns | ForEach-Object { $_.metrics.total }) 0.5
        totalP95Ms = Get-DiagPercentileMs @($okRuns | ForEach-Object { $_.metrics.total }) 0.95
        bytes      = ($okRuns | Select-Object -First 1).metrics.downloadBytes
        transport  = if ($stageRuns.Count -and -not $firstBad) { 'OK' } elseif ($firstBad) { $firstBad.transport } else { $null }
        httpStatus = $firstBad.httpStatus
        err        = $firstBad.err
    }
}

if ($PostUrl) {
    $buf = New-Object byte[] 8192
    (New-Object System.Random).NextBytes($buf)
    $up = Invoke-DiagProbe -Url $PostUrl -Method POST -Body ('payload=' + [Convert]::ToBase64String($buf)) `
        -ProxyArg $proxyArg -TimeoutSec $TimeoutSec -ForceIPv4:$ForceIPv4
    $allRuns += $up
    $upload = [pscustomobject][ordered]@{
        url        = (Hide-DiagUserInfo $PostUrl)
        state      = $script:DiagState.MEASURED
        ok         = $up.ok
        transport  = $up.transport
        httpStatus = $up.httpStatus
        bytes      = $up.metrics.downloadBytes
        err        = $up.err
    }
}

$sumPass = ($rows | Measure-Object pass -Sum).Sum
$sumFail = ($rows | Measure-Object fail -Sum).Sum
$uploadFailed = [bool]($upload -and -not $upload.ok)
$httpFailures = @($allRuns | Where-Object {
        $_.transport -eq 'OK' -and -not (Test-DiagHttpSuccess $_.httpStatus)
    }).Count

$exitCode = Get-DiagExitCode -Pass $sumPass -Total ($sumPass + $sumFail) -UploadFailed $uploadFailed
$verdictClass = switch ($exitCode) {
    0 { 'ALL_PASS' }
    2 { 'PARTIAL' }
    default { 'UNUSABLE' }
}

$result = [ordered]@{
    observedAt        = [datetimeoffset]::Now.ToString('o')
    contract          = Get-DiagContractInfo
    path              = if ($Direct) { 'DIRECT' } else { Get-DiagMaskedEndpoint $Proxy }
    curl              = Get-DiagCurlVersion
    proxyEnv          = $envFacts
    envOverriddenBy   = $envOverriddenBy
    noProxyHandling   = [ordered]@{
        proxied              = (-not $Direct)
        clearedInProbeProcess = (-not $Direct)
        mechanism            = if ($Direct) { $script:DiagNoProxyMechanismDirect } else { $script:DiagNoProxyMechanismProxy }
        basis                = $script:DiagNoProxyBasis
    }
    samplesPerTarget  = $Samples
    targets           = $rows
    upload            = $upload
    summary           = [ordered]@{
        pass          = $sumPass
        fail          = $sumFail
        uploadFailed  = [bool]$uploadFailed
        httpFailures  = $httpFailures
        rate          = if (($sumPass + $sumFail) -gt 0) { [Math]::Round(100.0 * $sumPass / ($sumPass + $sumFail), 0) } else { 0 }
    }
    verdictClass      = $verdictClass
    exitCode          = $exitCode
    coverage          = [ordered]@{
        ipVersion   = if ($ForceIPv4) { 'IPv4 enforced (-4)' } else { 'IPv4 preferred; IPv6 not excluded' }
        dns         = if ($Direct) { 'local resolver' } else { 'resolved by the proxy (remote); local DNS not tested' }
        udp         = 'NOT_TESTED'
        webrtc      = 'NOT_TESTED'
        browserStack = 'NOT_TESTED - this probe is not a browser'
    }
}

if ($Json) { $result | ConvertTo-Json -Depth 8 }
else {
    Write-Host ''
    Write-Host ("  APPLICATION-PATH MATRIX   path={0}   samples/target={1}   contract={2}/v{3}" -f $result.path, $Samples, $script:DiagContractName, $script:DiagContractVersion) -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * 92))
    $rows | Format-Table @{n = 'target'; e = { $_.target } },
        @{n = 'pass'; e = { $_.pass } }, @{n = 'fail'; e = { $_.fail } },
        @{n = 'rate'; e = { "$($_.rate)%" } },
        @{n = 'transport'; e = { $_.transport } }, @{n = 'httpStatus'; e = { $_.httpStatus } },
        @{n = 'p50ms'; e = { $_.totalP50Ms } } -AutoSize | Out-String -Width 150 | Write-Host
    if ($upload) {
        $uc = if ($upload.ok) { 'Green' } else { 'Red' }
        Write-Host ("  upload(synthetic 8KB): ok={0} transport={1} httpStatus={2} {3}" -f $upload.ok, $upload.transport, $upload.httpStatus, $upload.err) -ForegroundColor $uc
    }
    $c = if ($exitCode -eq 0) { 'Green' } elseif ($exitCode -eq 2) { 'Yellow' } else { 'Red' }
    Write-Host ("  RESULT {0}/{1} ({2}%){3}" -f $sumPass, ($sumPass + $sumFail), $result.summary.rate,
        $(if ($uploadFailed) { '  + UPLOAD FAILED' } else { '' })) -ForegroundColor $c
    Write-Host ("  httpFailures={0} (transport=OK but status outside 2xx/3xx)" -f $httpFailures) -ForegroundColor DarkGray
    Write-Host ("  dns: {0}   ip: {1}" -f $result.coverage.dns, $result.coverage.ipVersion) -ForegroundColor DarkGray
    Write-Host ("  not covered: {0}" -f (($result.coverage.Keys | Where-Object { $result.coverage[$_] -like 'NOT_TESTED*' }) -join ', ')) -ForegroundColor DarkGray
    Write-Host ''
}

# 0 = every GET passed and the upload (when requested) passed
# 3 = no GET passed at all (even if the upload somehow passed)
# 2 = some GET passed, or every GET passed but the upload failed
# (single source of truth: diag-contract.ps1 Get-DiagExitCode)
exit $exitCode
