#Requires -Version 5.1
<#
.SYNOPSIS  Incident regression INC-01..INC-10 with LOCAL controlled servers only.
.DESCRIPTION
  Every scenario is produced by a fixture owned by this script, not by "whatever the
  internet or a production proxy happens to do today".  The fixtures are the two
  helper scripts next to this file:

      mock-proxy.ps1   fail | drop | alternate | forward.  forward/alternate dial
                       ONLY 127.0.0.1:<origin port>; every other destination is
                       answered 502 and never connected (F62 - no public egress).
      mock-origin.ps1  local HTTP origin: GET 200 "ok", POST 500 "upload-rejected".

  The fail -> ok -> fail sequence of INC-03 is therefore fully local (F61): a 502
  proxy, a proxy that really forwards to the loopback origin, and the 502 proxy
  again.  No live proxy and no public host is contacted anywhere in this file.

  NO_PROXY is measured, not assumed (F63).  The run deliberately exports
  NO_PROXY=127.0.0.1 to its children; the matrix must clear it in the child process
  to reach the local proxy.  Measured curl behaviour is printed and stored in the
  JSON evidence.

  Proxy environment values are never printed: only name + presence + masked
  endpoint (F64).  The protected Clash/NexIP configuration is hashed before/after,
  no client is restarted, no proxy setting is changed, and INC-10 proves it.

  Assertions are strict: a check passes only when the measured value equals the
  expected one.  "pass -ge 0" style always-true conditions are forbidden here.

  Both entry points are covered by the same contract (tools/diag-contract.ps1):
  cab-doctor.ps1 is checked for consent gating (default = zero outbound request,
  F74), transport vs httpStatus separation (a local 500 must never look healthy,
  F75), NO_PROXY clearing in the proxied probe (a local 502 proxy must be reached
  while a hostile NO_PROXY=127.0.0.1 is exported, F73) and the upload entering the
  verdict even on the direct path (F76).  INC-02 and INC-04 also assert that both
  JSON reports embed the same contract (name, version, transport enum, exits).

  Exit: 0 all checks passed, 2 some check failed, 3 nothing executed.

.EXAMPLE
  .\invoke-inc-checks.ps1 -Json
#>
[CmdletBinding()]
param(
    # Retained for CLI compatibility only.  These checks never dial a live proxy.
    [string]$LiveProxy = 'http://127.0.0.1:11119',
    [string]$ConfigDirectory = "$env:APPDATA\io.github.clash-verge-rev.clash-verge-rev",
    [switch]$Json
)
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$pkg  = Split-Path -Parent (Split-Path -Parent $here)     # proxy_v4
$tools = Join-Path $pkg 'tools'
$matrix = Join-Path $tools 'connectivity-matrix.ps1'
$doctor = Join-Path $tools 'cab-doctor.ps1'
$contractFile = Join-Path $tools 'diag-contract.ps1'
if (-not (Test-Path -LiteralPath $contractFile)) {
    Write-Error ("diag-contract.ps1 not found: {0}" -f $contractFile)
    exit 3
}
. $contractFile
$state  = Join-Path $pkg 'state-v4.ps1'
$results = New-Object System.Collections.ArrayList
$fixtures = New-Object System.Collections.ArrayList

function Add-Result($id, $name, $mode, $expected, $actual, $pass, $detail) {
    [void]$results.Add([pscustomobject]@{
        id = $id; scenario = $name; mode = $mode; expected = $expected
        actual = $actual; pass = [bool]$pass; detail = $detail
    })
    $c = if ($pass) { 'Green' } elseif ($mode -eq 'NOT_TESTED') { 'DarkGray' } else { 'Red' }
    Write-Host ("  [{0}] {1,-32} {2,-9} exp={3,-26} act={4,-24} {5}" -f $id, $name, $mode, $expected, $actual,
        $(if ($pass) { 'PASS' } elseif ($mode -eq 'NOT_TESTED') { 'SKIPPED' } else { 'FAIL' })) -ForegroundColor $c
}

function Wait-Port([int]$Port, [int]$TimeoutMs = 8000) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        try {
            $c = New-Object Net.Sockets.TcpClient
            $c.Connect('127.0.0.1', $Port); $c.Close(); return $true
        } catch { Start-Sleep -Milliseconds 100 }
    }
    return $false
}

function Get-FreePort {
    $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $l.Start(); $p = [int]$l.LocalEndpoint.Port; $l.Stop(); return $p
}

function Start-Fixture([string]$File, [int]$Port, [string[]]$ExtraArgs = @()) {
    $full = Join-Path $here $File
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $full + '"'), '-Port', "$Port")
    if ($ExtraArgs -and $ExtraArgs.Count -gt 0) { $argList += $ExtraArgs }
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -PassThru -WindowStyle Hidden
    [void]$fixtures.Add($p)
    if (-not (Wait-Port $Port 12000)) {
        throw ("fixture {0} did not listen on 127.0.0.1:{1} (pid {2})" -f $File, $Port, $p.Id)
    }
    return $p
}

function Run-Matrix([string[]]$extra) {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $matrix @extra -Json -TimeoutSec 10 2>&1
    $code = $LASTEXITCODE
    $txt = ($out -join '')
    $obj = $null
    try { $obj = $txt | ConvertFrom-Json } catch { }
    return [pscustomobject]@{ json = $obj; exit = $code; raw = $txt }
}

function Run-Doctor([string[]]$extra) {
    # Same read-only entry point an operator would run; JSON only, bounded timeout.
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $doctor @extra -Json -TimeoutSec 10 2>&1
    $code = $LASTEXITCODE
    $txt = ($out -join '')
    $obj = $null
    try { $obj = $txt | ConvertFrom-Json } catch { }
    return [pscustomobject]@{ json = $obj; exit = $code; raw = $txt }
}

function Invoke-RawCurl {
    # F63: run raw curl against the local fixtures with a controlled NO_PROXY.
    param(
        [string]$Url,
        [string]$ProxyArg,
        [AllowNull()][string]$NoProxyValue = $null,
        [switch]$ClearNoProxy,
        [string[]]$ExtraArgs = @()
    )
    $saveUpper = [Environment]::GetEnvironmentVariable('NO_PROXY')
    $saveLower = [Environment]::GetEnvironmentVariable('no_proxy')
    $errFile = [IO.Path]::GetTempFileName()
    try {
        if ($ClearNoProxy) {
            Remove-Item Env:NO_PROXY -ErrorAction SilentlyContinue
            Remove-Item Env:no_proxy -ErrorAction SilentlyContinue
        }
        else {
            $env:NO_PROXY = $NoProxyValue
            $env:no_proxy = $NoProxyValue
        }
        $a = @('-sS', '-m', '8', '-o', 'NUL', '-w', 'code=%{http_code}')
        if ($ProxyArg) { $a += @('-x', $ProxyArg) }
        if ($ExtraArgs -and $ExtraArgs.Count -gt 0) { $a += $ExtraArgs }
        $a += $Url
        $raw = & curl.exe @a 2> $errFile
        $rc = $LASTEXITCODE
        $text = (($raw -join '') -replace '\s+', ' ').Trim()
        $code = $null
        if ($text -match 'code=(\d+)') { $code = [int]$Matches[1] }
        return [pscustomobject]@{ rc = $rc; code = $code; text = $text }
    }
    finally {
        [Environment]::SetEnvironmentVariable('NO_PROXY', $saveUpper, 'Process')
        [Environment]::SetEnvironmentVariable('no_proxy', $saveLower, 'Process')
        Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-ProxyRegSnapshot {
    # Explicit read state so a failed registry read can never masquerade as "no change".
    $hk = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $p = $null
    for ($i = 0; $i -lt 5; $i++) {
        $p = Get-ItemProperty $hk -ErrorAction SilentlyContinue
        if ($null -ne $p) { break }
        Start-Sleep -Milliseconds 150
    }
    if ($null -eq $p) { return [ordered]@{ ok = $false; enable = $null; server = $null } }
    return [ordered]@{ ok = $true; enable = $p.ProxyEnable; server = $p.ProxyServer }
}

$savedUpperNoProxy = [Environment]::GetEnvironmentVariable('NO_PROXY')
$savedLowerNoProxy = [Environment]::GetEnvironmentVariable('no_proxy')
$noProxyExperiment = $null
try {
    Write-Host ''
    Write-Host '  INCIDENT REGRESSION (local fixtures only, no third-party dependency)' -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * 118))

    # ---- protected-resource manifest (F48: presence, not just 4 hashes) ----
    $manifestFiles = @('clash-verge.yaml', 'config.yaml', 'profiles.yaml', 'verge.yaml')
    $before = [ordered]@{}
    foreach ($f in $manifestFiles) {
        $p = Join-Path $ConfigDirectory $f
        $before[$f] = if (Test-Path $p) { (Get-FileHash $p -Algorithm SHA256).Hash } else { 'ABSENT' }
    }
    $regBefore = Get-ProxyRegSnapshot
    $listingBefore = @(Get-ChildItem $ConfigDirectory -File -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { $_.Name })

    # ---- local fixtures (dynamic loopback ports, unique per run) ----
    $usedPorts = @{}
    function New-Port {
        do { $p = Get-FreePort } while ($usedPorts.ContainsKey($p))
        $usedPorts[$p] = $true
        return $p
    }
    $ports = [ordered]@{ fail = New-Port; drop = New-Port; alternate = New-Port; forward = New-Port; origin = New-Port }

    [void](Start-Fixture 'mock-origin.ps1' $ports.origin)
    [void](Start-Fixture 'mock-proxy.ps1' $ports.fail @('-Mode', 'fail'))
    [void](Start-Fixture 'mock-proxy.ps1' $ports.drop @('-Mode', 'drop'))
    [void](Start-Fixture 'mock-proxy.ps1' $ports.alternate @('-Mode', 'alternate', '-OriginPort', "$($ports.origin)"))
    [void](Start-Fixture 'mock-proxy.ps1' $ports.forward @('-Mode', 'forward', '-OriginPort', "$($ports.origin)"))

    $pFail = "http://127.0.0.1:$($ports.fail)"
    $pDrop = "http://127.0.0.1:$($ports.drop)"
    $pAlt  = "http://127.0.0.1:$($ports.alternate)"
    $pFwd  = "http://127.0.0.1:$($ports.forward)"
    $origin = "http://127.0.0.1:$($ports.origin)"

    # F63: hostile parent NO_PROXY for the whole run.  If the matrix did not clear
    # it in the child process the proxied checks below would silently go direct.
    $env:NO_PROXY = '127.0.0.1'
    $env:no_proxy = '127.0.0.1'
    Write-Host ("  ENV  fixtures on 127.0.0.1:{0}; child NO_PROXY=127.0.0.1 exported (must be cleared by the matrix)" -f ($ports.Values -join ',')) -ForegroundColor DarkGray

    # ---- F63 measurement: what curl really does with NO_PROXY and -x ----
    $cA = Invoke-RawCurl -Url "$origin/ok" -ProxyArg $pFail -NoProxyValue '127.0.0.1'
    $cB = Invoke-RawCurl -Url "$origin/ok" -ProxyArg $pFail -ClearNoProxy
    $cC = Invoke-RawCurl -Url "$origin/ok" -ProxyArg $pFail -NoProxyValue '127.0.0.1' -ExtraArgs @('--noproxy=')

    function Describe-NoProxyCase($r) {
        if ($null -eq $r.code) { return 'NO HTTP CODE' }
        if ($r.code -eq 502) { return 'proxy USED (502 from the mock proxy)' }
        if ($r.code -eq 200) { return 'proxy BYPASSED (200 from the loopback origin)' }
        return ("unexpected HTTP {0}" -f $r.code)
    }
    Write-Host ''
    Write-Host '  NO_PROXY MEASUREMENT (raw curl, local 502 proxy vs local 200 origin)' -ForegroundColor DarkGray
    Write-Host ("    A  -x + NO_PROXY=127.0.0.1                 -> HTTP {0}  {1}" -f $cA.code, (Describe-NoProxyCase $cA)) -ForegroundColor DarkGray
    Write-Host ("    B  -x + NO_PROXY cleared in the child      -> HTTP {0}  {1}" -f $cB.code, (Describe-NoProxyCase $cB)) -ForegroundColor DarkGray
    Write-Host ("    C  -x + --noproxy= + NO_PROXY=127.0.0.1    -> HTTP {0}  {1}" -f $cC.code, (Describe-NoProxyCase $cC)) -ForegroundColor DarkGray

    $noProxyWinsOverX = ($cA.code -eq 200 -and $cB.code -eq 502)
    $explicitOverrideWorks = ($cC.code -eq 502)
    $noProxyExperiment = [ordered]@{
        curl = ((& curl.exe --version 2>$null | Select-Object -First 1) -join '')
        fixtures = 'local mock proxy answering 502 + local mock origin answering 200'
        cases = @(
            [ordered]@{ id = 'A'; setup = '-x proxy + NO_PROXY=127.0.0.1'; httpCode = $cA.code; rc = $cA.rc; observed = (Describe-NoProxyCase $cA) }
            [ordered]@{ id = 'B'; setup = '-x proxy + NO_PROXY/no_proxy removed from the curl child'; httpCode = $cB.code; rc = $cB.rc; observed = (Describe-NoProxyCase $cB) }
            [ordered]@{ id = 'C'; setup = '-x proxy + --noproxy= + NO_PROXY=127.0.0.1'; httpCode = $cC.code; rc = $cC.rc; observed = (Describe-NoProxyCase $cC) }
        )
        conclusion = if ($noProxyWinsOverX) {
            '-x does NOT override NO_PROXY: the request bypassed the proxy while NO_PROXY matched. Clearing NO_PROXY/no_proxy in the curl child (or --noproxy=) is what forces the proxied measurement; the matrix does both.'
        }
        elseif ($cA.code -eq 502) {
            '-x took precedence over NO_PROXY in this build; the matrix still clears NO_PROXY defensively.'
        }
        else {
            'inconclusive: the raw curl cases did not produce the discriminating codes; see the recorded cases.'
        }
        parentNoProxyDuringRun = '127.0.0.1 (hostile, restores on exit)'
        explicitOverrideWorks = $explicitOverrideWorks
    }
    Write-Host ''

    # INC-01: the PORT IS LISTENING, the upstream is not usable (F43).
    # F67: when every GET *and* the upload fail the verdict must be 3, never 2.
    $listening = (Wait-Port $ports.fail 2000)
    $r1 = Run-Matrix @('-Proxy', $pFail, '-Samples', '2', '-Targets', "$origin/ok", '-PostUrl', "$origin/upload")
    $rate1 = if ($r1.json) { $r1.json.summary.rate } else { '?' }
    $upFail1 = if ($r1.json) { $r1.json.summary.uploadFailed } else { '?' }

    # F73: the doctor's proxied probe must still reach the proxy while the
    # harness has NO_PROXY/no_proxy=127.0.0.1 exported.  The mock proxy answers
    # 502, the mock origin answers 200: httpStatus=502 proves the proxy was used.
    # If NO_PROXY leaked into the curl child, the probe would go direct and the
    # result would be 200.
    $d73 = Run-Doctor @('-IgnoreSystemProxy', '-Proxies', $pFail, '-Targets', "$origin/ok", '-Samples', '1')
    $d73proxy = $null
    if ($d73.json) { $d73proxy = @($d73.json.proxies | Where-Object { $_.state -eq 'MEASURED' }) | Select-Object -First 1 }
    $p73 = [bool]($d73.json -and $d73proxy -and $d73proxy.listening -eq $true -and
        $d73proxy.rate -eq 0 -and $d73proxy.transport -eq 'OK' -and $d73proxy.httpStatus -eq 502)

    $p1 = ($listening -and $r1.json -and $rate1 -eq 0 -and $upFail1 -eq $true -and $r1.exit -eq 3 -and $p73)
    $a1 = ("listen=$listening rate=$rate1 upFail=$upFail1 exit=$($r1.exit) doctor502=$(if ($d73proxy) { $d73proxy.httpStatus } else { '?' })")
    Add-Result 'INC-01' 'listening but upstream 502' 'LIVE' 'rate=0 upFail=true exit=3 doctor502' $a1 $p1 'all GETs and the upload fail on a local 502 listener -> exit 3 (F67: never 2); doctor reaches the same proxy under hostile NO_PROXY -> 502 not 200 (F73)'

    # INC-02: accept TCP then drop the session (the NexIP symptom).
    # F66: only three concrete classifications are accepted; OTHER is a failure.
    # Contract: the matrix must declare the shared enum and exit codes.
    $r2 = Run-Matrix @('-Proxy', $pDrop, '-Samples', '2', '-Targets', "$origin/ok")
    $rate2 = if ($r2.json) { $r2.json.summary.rate } else { '?' }
    $kinds2 = @()
    if ($r2.json) { $kinds2 = @($r2.json.targets | ForEach-Object { $_.transport }) }
    $allowed2 = @('EMPTY_REPLY', 'RECV_FAIL', 'CONNECT_REFUSED')
    $rejected2 = @($kinds2 | Where-Object { $allowed2 -notcontains $_ })
    $contractKinds2 = @()
    if ($r2.json) { $contractKinds2 = @($r2.json.contract.transportKinds) }
    $contract2 = [bool]($r2.json -and
        (($contractKinds2) -join ',') -eq (((Get-DiagContractInfo).transportKinds) -join ',') -and
        $r2.json.contract.exitCodes.allPass -eq 0 -and
        $r2.json.contract.exitCodes.partial -eq 2 -and
        $r2.json.contract.exitCodes.unusable -eq 3)
    $p2 = ($r2.json -and $rate2 -eq 0 -and $r2.exit -eq 3 -and $kinds2.Count -gt 0 -and
        $rejected2.Count -eq 0 -and $contract2)
    Add-Result 'INC-02' 'accept then drop' 'LIVE' 'rate=0 exit=3 kind=allowed3 contract' ("rate=$rate2 exit=$($r2.exit) kind=$($kinds2 -join ',') contract=$contract2") $p2 'F66: only EMPTY_REPLY/RECV_FAIL/CONNECT_REFUSED; OTHER fails the check; transport enum and exit codes match diag-contract.ps1'

    # INC-03: fail -> live -> fail must reverse cleanly.  F61: the "live" leg is a
    # local proxy that really forwards to the local origin; no public host is used.
    $r3a = Run-Matrix @('-Proxy', $pFail, '-Samples', '1', '-Targets', "$origin/ok")
    $r3b = Run-Matrix @('-Proxy', $pFwd, '-Samples', '2', '-Targets', "$origin/ok")
    $r3c = Run-Matrix @('-Proxy', $pFail, '-Samples', '1', '-Targets', "$origin/ok")
    $seq = @()
    foreach ($r in @($r3a, $r3b, $r3c)) { $seq += $(if ($r.json) { $r.json.summary.rate } else { '?' }) }
    $exits = @($r3a.exit, $r3b.exit, $r3c.exit)
    $p3 = ($r3a.json -and $r3b.json -and $r3c.json -and
        $seq[0] -eq 0 -and $seq[1] -eq 100 -and $seq[2] -eq 0 -and
        $exits[0] -eq 3 -and $exits[1] -eq 0 -and $exits[2] -eq 3)
    Add-Result 'INC-03' 'recover then fail again' 'LIVE' 'rate 0/100/0 exit 3/0/3' ("$($seq -join '/') exit $($exits -join '/')") $p3 'F61: local 502 -> local forwarding -> local 502; no public host, no live proxy'

    # INC-04: GET works and the upload result must decide between 2 and 0 (F46/F67).
    #   POST /upload    -> 500 => exit 2 (partial)
    #   POST /upload-ok -> 200 => exit 0 (control: an all-success run really can be 0)
    $r4 = Run-Matrix @('-Direct', '-Samples', '1', '-Targets', "$origin/ok", '-PostUrl', "$origin/upload")
    $r4ok = Run-Matrix @('-Direct', '-Samples', '1', '-Targets', "$origin/ok", '-PostUrl', "$origin/upload-ok")

    # The same local origin also covers the shared contract on cab-doctor:
    #   F74: default run sends nothing (all external targets SKIPPED_NO_CONSENT,
    #        zero probes) -> LOCAL_ONLY_UNVERIFIED, exit 2.
    #   F75: GET /error500 -> transport=OK, httpStatus=500, ok=false, direct 0/1;
    #        a 500 can never produce a healthy verdict.
    #   F76: system proxy ignored for path selection (read-only switch): direct GET
    #        passes, the direct upload 500 fails, and it is in the verdict
    #        (DIRECT_ONLY_UPLOAD_FAILED, exit 2).
    $dDefault = Run-Doctor @()
    $d74 = [bool]($dDefault.json -and $dDefault.json.consent.allowExternal -eq $false -and
        $dDefault.json.direct.state -eq 'SKIPPED_NO_CONSENT' -and
        @($dDefault.json.consent.externalTargetsSkipped).Count -ge 2 -and
        @($dDefault.json.probes).Count -eq 0 -and
        $dDefault.json.verdict -eq 'LOCAL_ONLY_UNVERIFIED' -and $dDefault.exit -eq 2)

    # An empty-string proxy argument is swallowed by "powershell -File", so point
    # the proxy probe at a freshly closed loopback port instead: it is measured,
    # refused quickly, and cannot affect the direct/upload assertions below.
    $closedProxy = "127.0.0.1:$(New-Port)"
    $d75 = Run-Doctor @('-IgnoreSystemProxy', '-Proxies', $closedProxy, '-Targets', "$origin/error500", '-Samples', '1')
    $probe500 = $null
    if ($d75.json) { $probe500 = @($d75.json.probes | Where-Object { $_.via -eq 'DIRECT' }) | Select-Object -First 1 }
    $d75ok = [bool]($d75.json -and $probe500 -and $probe500.transport -eq 'OK' -and
        $probe500.httpStatus -eq 500 -and $probe500.ok -eq $false -and
        $d75.json.direct.pass -eq 0 -and $d75.json.direct.total -eq 1 -and
        $d75.json.verdict -eq 'BROKEN' -and $d75.exit -eq 3)

    $d76 = Run-Doctor @('-IgnoreSystemProxy', '-Proxies', $closedProxy, '-Targets', "$origin/ok", '-PostUrl', "$origin/upload", '-Samples', '1')
    $d76ok = [bool]($d76.json -and $d76.json.direct.pass -eq 1 -and
        $d76.json.summary.uploadFailed -eq $true -and
        $d76.json.upload.state -eq 'MEASURED' -and $d76.json.upload.ok -eq $false -and
        $d76.json.upload.transport -eq 'OK' -and $d76.json.upload.httpStatus -eq 500 -and
        $d76.json.verdict -eq 'DIRECT_ONLY_UPLOAD_FAILED' -and $d76.exit -eq 2)

    $sameContract = [bool]($r4.json -and $dDefault.json -and
        (($r4.json.contract | ConvertTo-Json -Compress -Depth 5) -eq ($dDefault.json.contract | ConvertTo-Json -Compress -Depth 5)))

    $p4 = ($r4.json -and $r4.json.summary.pass -eq 1 -and $r4.json.summary.uploadFailed -eq $true -and $r4.exit -eq 2) -and
          ($r4ok.json -and $r4ok.json.summary.uploadFailed -eq $false -and $r4ok.exit -eq 0) -and
          $d74 -and $d75ok -and $d76ok -and $sameContract
    $d4 = ("failExit={0} failUp={1} okExit={2} okUp={3} F74={4} F75={5} F76={6} contract={7}" -f $r4.exit,
        $(if ($r4.json) { $r4.json.summary.uploadFailed } else { '?' }),
        $r4ok.exit, $(if ($r4ok.json) { $r4ok.json.summary.uploadFailed } else { '?' }),
        $d74, $d75ok, $d76ok, $sameContract)
    Add-Result 'INC-04' 'upload decides exit 2/0' 'LIVE' 'up500:2 up200:0 F74-76 contract' $d4 $p4 'local origin: POST /upload 500 -> 2; POST /upload-ok 200 -> 0; upload is in the verdict. Doctor: default=no egress (F74), GET 500 != healthy (F75), direct upload failure changes the verdict (F76), both reports share one contract'

    # INC-05: deterministic intermittency from the alternate fixture (F44/F62).
    $r5 = Run-Matrix @('-Proxy', $pAlt, '-Samples', '6', '-Targets', "$origin/ok")
    $pass5 = if ($r5.json) { $r5.json.summary.pass } else { -1 }
    $tot5 = if ($r5.json) { $r5.json.summary.pass + $r5.json.summary.fail } else { 0 }
    $p5 = ($r5.json -and $tot5 -eq 6 -and $pass5 -gt 0 -and $pass5 -lt 6 -and $r5.exit -eq 2)
    Add-Result 'INC-05' 'alternating failures' 'LIVE' '0<pass<6 exit=2' ("pass=$pass5/$tot5 exit=$($r5.exit)") $p5 'F62: fixture alternates 502/forward per connection and forwards only to the loopback origin'

    # INC-06: state must emit a verdict for empty, corrupt and text modes (F51)
    $empty = Join-Path $env:TEMP ('inc06e-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $empty -Force | Out-Null
    $corrupt = Join-Path $env:TEMP ('inc06c-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $corrupt -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $corrupt 'settings.json') -Value '{ this is not json' -Encoding utf8
    $o1 = & powershell -NoProfile -ExecutionPolicy Bypass -File $state -Json -ConfigDirectory $empty 2>&1; $e1 = $LASTEXITCODE
    $o2 = & powershell -NoProfile -ExecutionPolicy Bypass -File $state -Json -ConfigDirectory $corrupt 2>&1; $e2 = $LASTEXITCODE
    $o3 = & powershell -NoProfile -ExecutionPolicy Bypass -File $state -ConfigDirectory $empty 2>&1; $e3 = $LASTEXITCODE
    $j1 = ($o1 -join ''); $j2 = ($o2 -join '')
    $parse1 = $null; try { $parse1 = $j1 | ConvertFrom-Json } catch { }
    $parse2 = $null; try { $parse2 = $j2 | ConvertFrom-Json } catch { }
    $crash = (($o1 -join ' ') + ($o2 -join ' ') + ($o3 -join ' ')) -match 'VariableIsUndefined|cannot be retrieved|has not been set'
    $p6 = ($e1 -ne 1 -and $e2 -ne 1 -and $e3 -ne 1 -and $parse1 -and $parse2 -and -not $crash)
    Add-Result 'INC-06' 'state verdict, no crash' 'LIVE' 'no crash, 3 modes' ("empty=$e1 corrupt=$e2 text=$e3") $p6 ("empty={0} corrupt={1} text={2}" -f $(if ($parse1) { $parse1.state } else { 'no-json' }), $(if ($parse2) { $parse2.state } else { 'no-json' }), $e3)
    Remove-Item $empty, $corrupt -Recurse -Force -ErrorAction SilentlyContinue

    # INC-07: regenerated runtime / lost marker must be detected.
    # F65: both halves are asserted - the profile must NOT carry the marker, while
    # the synthetic runtime file (which carries dialer-proxy) must be seen as marked.
    $synth = Join-Path $env:TEMP ('inc07-' + [guid]::NewGuid().ToString('N'))
    $prof = Join-Path $synth 'profiles'; New-Item -ItemType Directory $prof -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $prof 'v4-managed.yaml') -Value "proxies:`n  - name: X`n" -Encoding utf8
    $rt = Join-Path $synth 'clash-verge.yaml'; Set-Content -LiteralPath $rt -Value "proxies:`n  - name: US`n    dialer-proxy: STAR-FIRSTHOP`n" -Encoding utf8
    $probe = @'
param($pkg,$profDir,$runtime)
$ErrorActionPreference='SilentlyContinue'
. (Join-Path $pkg 'lib\V4.ps1')
$paths = [pscustomobject]@{ ProfilesDir=$profDir; RuntimeFile=$runtime }
$r = Get-V4Integrity -Paths $paths
@{ markerOk=$r.markerOk; runtimeMarkerOk=$r.runtimeMarkerOk; profileExists=$r.profileExists } | ConvertTo-Json -Compress
'@
    $probeFile = Join-Path $env:TEMP ('probe-' + [guid]::NewGuid().ToString('N') + '.ps1')
    Set-Content -LiteralPath $probeFile -Value $probe -Encoding utf8
    $pi = & powershell -NoProfile -ExecutionPolicy Bypass -File $probeFile $pkg $prof $rt 2>&1
    $pj = ($pi -join '') | ConvertFrom-Json -ErrorAction SilentlyContinue
    $p7 = ($pj -and $pj.profileExists -eq $true -and $pj.markerOk -eq $false -and $pj.runtimeMarkerOk -eq $true)
    Add-Result 'INC-07' 'marker lost detected' 'LIVE' 'markerOk=false runtimeMarkerOk=true' ("exists=$(if($pj){$pj.profileExists}else{'?'}) markerOk=$(if($pj){$pj.markerOk}else{'?'}) runtimeMarkerOk=$(if($pj){$pj.runtimeMarkerOk}else{'?'})") $p7 'F65: synthetic profile lacks the marker while the synthetic runtime file carries dialer-proxy'
    Remove-Item $synth, $probeFile -Recurse -Force -ErrorAction SilentlyContinue

    # INC-08: partial availability must not be reported as full health (F45)
    $r8 = Run-Matrix @('-Proxy', $pAlt, '-Samples', '4', '-Targets', "$origin/ok")
    $rate8 = if ($r8.json) { $r8.json.summary.rate } else { -1 }
    $p8 = ($r8.json -and $rate8 -gt 0 -and $rate8 -lt 100 -and $r8.exit -eq 2)
    Add-Result 'INC-08' 'partial != healthy' 'LIVE' '0<rate<100 exit=2' ("rate=$rate8 exit=$($r8.exit)") $p8 'exit 2 is partial; only a clean run may return 0'

    # INC-09: no unattended recoverer (tasks + processes + startup) (F52)
    $allTasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue)
    $oursTasks = @($allTasks | Where-Object {
        $act = ($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' '
        $act -match 'apply-v4|state-v4|rollback-v4|connectivity-matrix|proxy_v4|cab-'
    })
    # Our own probe children are not "unattended recoverers".  Walk the ancestor
    # chain and ignore anything inside it: a synchronous powershell child that is
    # still terminating can otherwise be miscounted (observed once as proc=1).
    $selfTree = New-Object System.Collections.ArrayList
    [void]$selfTree.Add($PID)
    $walk = $PID
    for ($i = 0; $i -lt 8; $i++) {
        $pp = (Get-CimInstance Win32_Process -Filter "ProcessId=$walk" -ErrorAction SilentlyContinue).ParentProcessId
        if (-not $pp -or $selfTree -contains [int]$pp) { break }
        [void]$selfTree.Add([int]$pp)
        $walk = [int]$pp
    }
    $oursProcs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessId -and $selfTree -notcontains [int]$_.ProcessId -and
        $selfTree -notcontains [int]$_.ParentProcessId -and
        $_.CommandLine -and $_.CommandLine -notmatch 'invoke-inc-checks' -and
        $_.CommandLine -match 'apply-v4\.ps1|state-v4\.ps1|rollback-v4\.ps1|connectivity-matrix\.ps1'
    })
    $runKeys = @()
    foreach ($k in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run')) {
        $p = Get-ItemProperty $k -ErrorAction SilentlyContinue
        if ($p) { $p.PSObject.Properties | Where-Object { $_.Value -match 'apply-v4|state-v4|proxy_v4|cab-' } | ForEach-Object { $runKeys += $_.Name } }
    }
    $startup = @(Get-ChildItem ([Environment]::GetFolderPath('Startup')) -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'cab|proxy|clash|verge' })
    $p9 = ($oursTasks.Count -eq 0 -and $oursProcs.Count -eq 0 -and $runKeys.Count -eq 0 -and $startup.Count -eq 0)
    Add-Result 'INC-09' 'no unattended recoverer' 'LIVE' '0 everywhere' ("task=$($oursTasks.Count) proc=$($oursProcs.Count) run=$($runKeys.Count) startup=$($startup.Count)") $p9 'scheduled tasks + live processes + Run keys + Startup folder'

    # INC-10: manifest-based integrity of the protected resources (F48)
    $changed = @()
    foreach ($f in $manifestFiles) {
        $p = Join-Path $ConfigDirectory $f
        $now = if (Test-Path $p) { (Get-FileHash $p -Algorithm SHA256).Hash } else { 'ABSENT' }
        if ($now -ne $before[$f]) { $changed += $f }
    }
    $listingAfter = @(Get-ChildItem $ConfigDirectory -File -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { $_.Name })
    $newFiles = @($listingAfter | Where-Object { $listingBefore -notcontains $_ })
    $regAfter = Get-ProxyRegSnapshot
    $regChanged = (-not $regBefore.ok) -or (-not $regAfter.ok) -or
        ($regBefore.enable -ne $regAfter.enable) -or ($regBefore.server -ne $regAfter.server)
    $absent = @($before.Keys | Where-Object { $before[$_] -eq 'ABSENT' })
    $p10 = ($changed.Count -eq 0 -and -not $regChanged -and $newFiles.Count -eq 0)
    Add-Result 'INC-10' 'protected resources intact' 'LIVE' '0 delta' ("files=$($changed.Count) reg=$regChanged new=$($newFiles.Count) absentInit=$($absent.Count)") $p10 'files + new files + HKCU proxy values; two samples only, not continuous monitoring'
}
finally {
    foreach ($p in $fixtures) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    [Environment]::SetEnvironmentVariable('NO_PROXY', $savedUpperNoProxy, 'Process')
    [Environment]::SetEnvironmentVariable('no_proxy', $savedLowerNoProxy, 'Process')
}

$executed = @($results | Where-Object { $_.mode -ne 'NOT_TESTED' })
$passed = @($executed | Where-Object { $_.pass }).Count
Write-Host ''
Write-Host ("  executed {0}, passed {1}, skipped {2}" -f $executed.Count, $passed, ($results.Count - $executed.Count)) -ForegroundColor $(
    if ($passed -eq $executed.Count) { 'Green' } else { 'Red' })

$ev = [ordered]@{
    observedAt = [datetimeoffset]::Now.ToString('o')
    contract = Get-DiagContractInfo
    liveProxy = [ordered]@{
        configured = (Get-DiagMaskedEndpoint $LiveProxy)
        contacted = $false
        note = 'retained for CLI compatibility; the checks are local-only and never dial it'
    }
    configDir = $ConfigDirectory
    fixtures = 'tests/incidents/mock-proxy.ps1 + tests/incidents/mock-origin.ps1 (127.0.0.1 only; no public egress)'
    noProxyExperiment = $noProxyExperiment
    doctorChecks = [ordered]@{
        contractShared          = $sameContract
        defaultNoConsent        = $d74
        noProxyClearedOnProbe   = $p73
        http500NotHealthy       = $d75ok
        directUploadInVerdict   = $d76ok
    }
    executed = $executed.Count; passed = $passed; skipped = ($results.Count - $executed.Count)
    checks = $results
}
if ($Json) { $ev | ConvertTo-Json -Depth 8 }
if ($executed.Count -eq 0) { exit 3 }
if ($passed -eq $executed.Count) { exit 0 } else { exit 2 }
