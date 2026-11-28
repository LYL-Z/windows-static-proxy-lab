#Requires -Version 5.1
<#
.SYNOPSIS
  Single shared diagnostic contract.  Dot-source only: cab-doctor.ps1 and
  connectivity-matrix.ps1 both load this file instead of keeping their own copies
  of the probe core, error enum, redaction and exit semantics.

.DESCRIPTION
  This file only defines functions and constants.  Loading it never touches the
  machine: no registry write, no config write, no proxy change, no network.

  STATUS FIELD NAMES (both entry points emit exactly these names):
    transport
        curl exit-code class, i.e. "did the transport work":
        OK | DNS_FAIL | CONNECT_REFUSED | TIMEOUT | TLS_FAIL | EMPTY_REPLY |
        RECV_FAIL | CERT_FAIL | OTHER
        HTTP status is NOT part of transport: a 500 has transport=OK.
    httpStatus
        the HTTP status actually observed (200/404/500/...), or $null when no
        HTTP response arrived (DNS failure, refusal, timeout, drop, TLS failure).
    ok
        $true only when transport=OK AND httpStatus is 2xx/3xx.
        transport=OK + httpStatus=500 => ok=$false.  "The server answered and
        said no" is never a healthy probe.
    state
        MEASURED | SKIPPED_NO_CONSENT | NOT_APPLICABLE (measurement state of a
        whole check or of one run), never a substitute for ok.
    target / via / proxy / rc / metrics / err
        target = redacted URL, via = DIRECT|PROXY, proxy = redacted endpoint,
        rc = raw curl exit code, metrics = {dns,connect,tls,ttfb,total,
        downloadBytes} in seconds/bytes, err = redacted curl stderr.

  EXIT CODES (single source of truth: $script:DiagExit, Get-DiagExitCode):
    0  ALL_PASS: every measured check passed (and the requested upload passed)
    2  PARTIAL : something passed, or nothing failed but nothing was verified
    3  UNUSABLE: nothing measured passed at all

  BODY CAPTURE (v2, opt-in):
    Invoke-DiagProbe -CaptureBody keeps at most -MaxBodyBytes of the response
    body in .body (whitespace collapsed, control characters stripped).  This is
    what path-report.ps1 / webrtc-probe.ps1 need to read an egress-IP echo
    ("107.149.115.70", "ip=..." in a Cloudflare trace) through the SAME probe
    instead of a second curl wrapper.  Without -CaptureBody .body is $null and
    the body is still discarded to NUL exactly as in v1, so existing callers
    keep their behaviour and output.

  REDACTION ($Hide-DiagUserInfo):
    any scheme://user:pass@host becomes scheme://***:***@; Proxy-Authorization
    values become ***.  Raw proxy environment values are never emitted; only
    presence plus a masked endpoint.  curl stderr is redacted before storage.

  NO_PROXY is handled by measurement, not assumption.  Measured with curl 8.x,
  a local 502 proxy and a local 200 origin (see
  tests/incidents/invoke-inc-checks.ps1):
      -x proxy, NO_PROXY=127.0.0.1          -> 200 from the origin (bypassed)
      -x proxy, NO_PROXY cleared            -> 502 from the proxy (used)
      -x proxy, --noproxy= + NO_PROXY set   -> 502 from the proxy (used)
  Therefore -x is not an override: Invoke-DiagProbe removes NO_PROXY/no_proxy
  for the duration of every proxied curl child and passes --noproxy=; a direct
  run passes --noproxy "*".
#>

$script:DiagContractName = 'cab-diag-contract'
$script:DiagContractVersion = 2
$script:DiagExit = [ordered]@{ ALL_PASS = 0; PARTIAL = 2; UNUSABLE = 3 }
$script:DiagTransportKind = @(
    'OK', 'DNS_FAIL', 'CONNECT_REFUSED', 'TIMEOUT', 'TLS_FAIL',
    'EMPTY_REPLY', 'RECV_FAIL', 'CERT_FAIL', 'OTHER'
)
$script:DiagState = [ordered]@{
    MEASURED           = 'MEASURED'
    SKIPPED_NO_CONSENT = 'SKIPPED_NO_CONSENT'
    NOT_APPLICABLE     = 'NOT_APPLICABLE'
}
$script:DiagNoProxyBasis = 'measured with local fixtures (proxy_v4/tests/incidents/invoke-inc-checks.ps1): -x does NOT override NO_PROXY; a proxied probe must clear NO_PROXY/no_proxy and pass --noproxy='
$script:DiagNoProxyMechanismProxy = 'NO_PROXY/no_proxy removed for the probe process + --noproxy='
$script:DiagNoProxyMechanismDirect = '--noproxy "*"'

function Get-DiagContractInfo {
    # Embedded in both JSON reports so a caller can prove the two entry points
    # really share one contract instead of two look-alike copies.
    return [ordered]@{
        name           = $script:DiagContractName
        version        = $script:DiagContractVersion
        transportKinds = @($script:DiagTransportKind)
        states         = @($script:DiagState.Values)
        exitCodes      = [ordered]@{
            allPass  = $script:DiagExit.ALL_PASS
            partial  = $script:DiagExit.PARTIAL
            unusable = $script:DiagExit.UNUSABLE
        }
        fields         = @('target', 'via', 'proxy', 'transport', 'httpStatus', 'ok', 'state', 'rc', 'metrics', 'err', 'body')
        bodyCapture    = 'opt-in via Invoke-DiagProbe -CaptureBody; .body is $null unless requested (v2)'
    }
}

function Get-DiagCurlVersion {
    try {
        $v = & curl.exe --version 2>$null | Select-Object -First 1
        return (([string]::Join(' ', @($v))).Trim())
    }
    catch { return '' }
}

function Hide-DiagUserInfo {
    # Remove credentials from anything that can reach the report or the console.
    [CmdletBinding()]
    param([AllowNull()][string]$Text)
    if (-not $Text) { return $Text }
    $t = $Text -replace '(?i)([a-z][a-z0-9+.-]*://)[^/\s@]*@', '$1***:***@'
    $t = $t -replace '(?i)(proxy-authorization\s*:\s*)\S+', '$1***'
    return $t
}

function Get-DiagMaskedEndpoint {
    # Keep scheme, a masked-userinfo marker and host:port.  Never the full value.
    # Accepts both "http://host:port" and a bare "host:port".
    [CmdletBinding()]
    param([AllowNull()][string]$Value)
    if (-not $Value) { return '' }
    $text = $Value
    if ($text -notmatch '^[A-Za-z][A-Za-z0-9+.-]*://') { $text = 'http://' + $text }
    $u = $null
    if ([Uri]::TryCreate($text, [UriKind]::Absolute, [ref]$u)) {
        $auth = if ($u.UserInfo) { '***:***@' } else { '' }
        $port = if ($u.IsDefaultPort) { '' } else { ':' + $u.Port }
        return ('{0}://{1}{2}{3}' -f $u.Scheme, $auth, $u.Host, $port)
    }
    return '***'
}

function Get-DiagProxyEnvFacts {
    # Name + presence + masked value only.  NO_PROXY is never echoed; its entry
    # count is reported because it decides whether a proxy would be bypassed.
    $o = [ordered]@{}
    foreach ($n in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY', 'http_proxy', 'https_proxy', 'no_proxy')) {
        $v = [Environment]::GetEnvironmentVariable($n)
        if (-not $v) {
            $o[$n] = [ordered]@{ present = $false }
            continue
        }
        if ($n -match '^no_proxy$') {
            $o[$n] = [ordered]@{
                present     = $true
                valueMasked = '***'
                entries     = @($v -split ',' | Where-Object { $_ -ne '' }).Count
            }
            continue
        }
        $o[$n] = [ordered]@{
            present        = $true
            valueMasked    = (Get-DiagMaskedEndpoint $v)
            hasCredentials = [bool]($v -match '://[^/\s@]*@')
        }
    }
    return $o
}

function Get-DiagTransportKind {
    # Deterministic classification from curl's own exit code first, stderr second.
    param([int]$Rc, [AllowNull()][string]$ErrText)
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
    if ($ErrText) {
        if ($ErrText -match '(?i)schannel|SSL|TLS') { return 'TLS_FAIL' }
        if ($ErrText -match '(?i)empty reply') { return 'EMPTY_REPLY' }
        if ($ErrText -match '(?i)refused') { return 'CONNECT_REFUSED' }
        if ($ErrText -match '(?i)timed out|timeout') { return 'TIMEOUT' }
        if ($ErrText -match '(?i)not resolve|resolve host|Could not resolve') { return 'DNS_FAIL' }
        if ($ErrText -match '(?i)certificate') { return 'CERT_FAIL' }
    }
    return 'OTHER'
}

function Test-DiagHttpSuccess {
    param([AllowNull()]$HttpStatus)
    if ($null -eq $HttpStatus) { return $false }
    $code = 0
    if (-not [int]::TryParse([string]$HttpStatus, [ref]$code)) { return $false }
    return ($code -ge 200 -and $code -lt 400)
}

function Format-DiagTransportStatus {
    # One canonical rendering of the transport/httpStatus pair ("OK/500").
    param([AllowNull()][string]$Transport, [AllowNull()]$HttpStatus)
    if (-not $Transport) { return 'NOT_MEASURED' }
    if ($null -ne $HttpStatus -and "$HttpStatus" -ne '') { return ('{0}/{1}' -f $Transport, $HttpStatus) }
    return $Transport
}

function Get-DiagPercentileMs {
    # Input: samples in seconds (curl -w time_*).  Output: milliseconds, rounded.
    param($Values, [double]$Quantile = 0.5)
    $s = @($Values | Where-Object { $null -ne $_ } | Sort-Object)
    if ($s.Count -eq 0) { return $null }
    $i = [Math]::Min($s.Count - 1, [int][Math]::Floor($s.Count * $Quantile))
    return [Math]::Round($s[$i] * 1000, 0)
}

function Get-DiagExitCode {
    # 0 all measured checks passed; 2 partial/unknown; 3 nothing worked.
    # -Unverified means "nothing failed, but nothing was allowed to be measured"
    # (for example an external baseline skipped without consent): partial, never 0.
    param(
        [int]$Pass = 0,
        [int]$Total = 0,
        [bool]$UploadFailed = $false,
        [switch]$Unverified
    )
    if ($Unverified) { return $script:DiagExit.PARTIAL }
    if ($Total -le 0 -or $Pass -le 0) { return $script:DiagExit.UNUSABLE }
    if ($Pass -eq $Total -and -not $UploadFailed) { return $script:DiagExit.ALL_PASS }
    return $script:DiagExit.PARTIAL
}

function Get-DiagExitCodeForClass {
    # Entry points that phrase their own verdict still get the exit code from
    # the shared contract: ALL_PASS=0, PARTIAL=2, everything else=3.
    param([AllowNull()][string]$VerdictClass)
    switch ($VerdictClass) {
        'ALL_PASS' { return $script:DiagExit.ALL_PASS }
        'PARTIAL' { return $script:DiagExit.PARTIAL }
        default { return $script:DiagExit.UNUSABLE }
    }
}

function Get-DiagNoProxySnapshot {
    return [ordered]@{
        upper = [Environment]::GetEnvironmentVariable('NO_PROXY')
        lower = [Environment]::GetEnvironmentVariable('no_proxy')
    }
}

function Clear-DiagNoProxy {
    # Only affects THIS probe process (and the curl child it starts).  The
    # caller's environment is restored by Restore-DiagNoProxy.
    Remove-Item Env:NO_PROXY -ErrorAction SilentlyContinue
    Remove-Item Env:no_proxy -ErrorAction SilentlyContinue
}

function Restore-DiagNoProxy {
    param($Snapshot)
    if ($null -eq $Snapshot) { return }
    if ($null -ne $Snapshot.upper) { [Environment]::SetEnvironmentVariable('NO_PROXY', [string]$Snapshot.upper, 'Process') }
    else { [Environment]::SetEnvironmentVariable('NO_PROXY', $null, 'Process') }
    if ($null -ne $Snapshot.lower) { [Environment]::SetEnvironmentVariable('no_proxy', [string]$Snapshot.lower, 'Process') }
    else { [Environment]::SetEnvironmentVariable('no_proxy', $null, 'Process') }
}

function Invoke-DiagProbe {
    <#
      The one probe implementation used by both entry points.
      - never disables certificate validation (-k / --insecure are never passed)
      - proxied run: NO_PROXY/no_proxy removed for the curl child + --noproxy=
      - direct run : --noproxy "*"
      - transport and httpStatus stay separate; a 5xx is transport=OK/ok=$false
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [string]$ProxyArg = '',
        [ValidateSet('GET', 'POST')][string]$Method = 'GET',
        [AllowNull()][string]$Body = $null,
        [int]$TimeoutSec = 20,
        [switch]$ForceIPv4,
        [switch]$CaptureBody,
        [ValidateRange(16, 65536)][int]$MaxBodyBytes = 2048
    )

    $safeProxy = if ($ProxyArg) { Get-DiagMaskedEndpoint $ProxyArg } else { '' }
    $fmt = 'code=%{http_code};dns=%{time_namelookup};conn=%{time_connect};tls=%{time_appconnect};ttfb=%{time_starttransfer};total=%{time_total};dl=%{size_download}'
    # v2: opt-in body capture.  Without -CaptureBody the body still goes to NUL.
    $bodyFile = if ($CaptureBody) { [IO.Path]::GetTempFileName() } else { $null }
    $outTarget = if ($bodyFile) { $bodyFile } else { 'NUL' }
    $cargs = @('-sS', '-m', "$TimeoutSec", '-o', $outTarget, '-w', $fmt)
    if ($ForceIPv4) { $cargs += '-4' }
    if ($ProxyArg) {
        # F73: -x alone does not override NO_PROXY (measured).  Do both.
        $cargs += @('-x', $ProxyArg, '--noproxy=')
    }
    else {
        $cargs += @('--noproxy', '*')
    }
    if ($Method -eq 'POST') { $cargs += @('-X', 'POST', '--data-binary', $Body) }
    $cargs += $Url

    $snapshot = Get-DiagNoProxySnapshot
    $errFile = [IO.Path]::GetTempFileName()
    $rc = 1
    $metricsText = ''
    $launchError = ''
    $capturedBody = $null
    try {
        if ($ProxyArg) { Clear-DiagNoProxy }
        try {
            $raw = & curl.exe @cargs 2> $errFile
            $rc = $LASTEXITCODE
        }
        catch {
            $rc = 1
            $launchError = ('curl.exe could not be started: {0}' -f $_.Exception.Message)
        }
        $fileErr = ''
        try { $fileErr = [string](Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue) } catch { }
        $errText = (($launchError + ' ' + $fileErr) -replace '\s+', ' ').Trim()
        $metricsText = ([string]::Join(' ', @($raw))).Trim()
        $capturedBody = $null
        if ($bodyFile -and (Test-Path -LiteralPath $bodyFile)) {
            try {
                $bytes = [IO.File]::ReadAllBytes($bodyFile)
                if ($bytes.Length -gt $MaxBodyBytes) { $bytes = $bytes[0..($MaxBodyBytes - 1)] }
                $text = [Text.Encoding]::UTF8.GetString($bytes)
                # collapse whitespace/control chars: an echo body is one short line,
                # and no control byte may reach a report.
                $text = ($text -replace '[\u0000-\u001f\u007f]', ' ') -replace '\s+', ' '
                $capturedBody = $text.Trim()
            }
            catch { $capturedBody = $null }
        }
    }
    finally {
        Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
        if ($bodyFile) { Remove-Item -LiteralPath $bodyFile -Force -ErrorAction SilentlyContinue }
        Restore-DiagNoProxy -Snapshot $snapshot
    }

    $httpStatus = $null
    $metrics = [ordered]@{ dns = $null; connect = $null; tls = $null; ttfb = $null; total = $null; downloadBytes = $null }
    if ($metricsText -match 'code=(\d+);dns=([\d.]+);conn=([\d.]+);tls=([\d.]+);ttfb=([\d.]+);total=([\d.]+);dl=(\d+)') {
        # curl writes code=000 when the exchange never produced a status.
        if ($Matches[1] -ne '000') { $httpStatus = [int]$Matches[1] }
        $metrics.dns = [double]$Matches[2]
        $metrics.connect = [double]$Matches[3]
        $metrics.tls = [double]$Matches[4]
        $metrics.ttfb = [double]$Matches[5]
        $metrics.total = [double]$Matches[6]
        $metrics.downloadBytes = [int]$Matches[7]
    }

    $transport = Get-DiagTransportKind -Rc $rc -ErrText $errText
    $ok = [bool](($rc -eq 0) -and (Test-DiagHttpSuccess $httpStatus))
    if ($rc -eq 0 -and -not $ok -and -not $errText) {
        # never fail silently: keep the HTTP status as the evidence
        $errText = if ($null -ne $httpStatus) { 'HTTP {0}' -f $httpStatus } else { 'no HTTP status and no error text' }
    }

    return [pscustomobject][ordered]@{
        target     = (Hide-DiagUserInfo $Url)
        via        = $(if ($ProxyArg) { 'PROXY' } else { 'DIRECT' })
        proxy      = $safeProxy
        transport  = $transport
        httpStatus = $httpStatus
        ok         = $ok
        rc         = $rc
        metrics    = [pscustomobject]$metrics
        err        = (Hide-DiagUserInfo $errText)
        body       = $capturedBody
    }
}
