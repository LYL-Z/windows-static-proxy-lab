#Requires -Version 5.1
<#
.SYNOPSIS  CAB Doctor - read-only proxy/connectivity diagnosis on one shared contract.
.DESCRIPTION
  Answers: "can this machine reach the internet right now, and if not, at which
  layer does it fail?"  It never writes: no registry, no config, no process
  restart, no system-proxy change.  Recovery commands are printed, never executed.

  WHAT IS CONTACTED (explicit, not implied):
    * default (no -AllowExternal): NOTHING leaves this machine.  Only
      HKCU Internet Settings is read, *_PROXY names/presence are read, and TCP
      connects are made to the requested local proxy ports.  The default external
      targets are https://www.baidu.com and https://www.google.com; without
      -AllowExternal they are reported as SKIPPED_NO_CONSENT and never dialled.
    * -AllowExternal: exactly the -Targets list (https://www.baidu.com,
      https://www.google.com by default) is contacted: once directly for the
      baseline and -Samples times through each -Proxies entry.  If -PostUrl is
      given, it receives one synthetic 8 KB random POST; no user data is sent.
    * loopback targets (127.0.0.1 / localhost / ::1) are local-controlled and may
      be probed without -AllowExternal: the direct baseline stays on loopback, and
      a proxied probe to a loopback target is allowed only when the proxy is
      loopback too.

  NO_PROXY is handled by measurement, not assumption: curl honours NO_PROXY even
  when -x is given, so a proxied probe removes NO_PROXY/no_proxy for the probe
  process and passes --noproxy=.  The basis is measured with local fixtures by
  tests/incidents/invoke-inc-checks.ps1 and is printed in the output and stored
  as noProxyHandling.basis in -Json.

  transport vs httpStatus: transport is the curl exit-code class (OK/DNS_FAIL/...),
  httpStatus is the HTTP status actually seen.  A 500 has transport=OK and
  httpStatus=500, ok=$false, and can never make the verdict HEALTHY.

  One diagnostic core: this script and connectivity-matrix.ps1 dot-source
  tools/diag-contract.ps1 for the error enum, redaction, transport/httpStatus
  semantics, NO_PROXY handling and the exit-code contract.  No duplicate probe
  implementation remains.

  Exit: 0 all measured checks passed, 2 partial/unverified, 3 unusable.

.EXAMPLE
  .\cab-doctor.ps1
  .\cab-doctor.ps1 -AllowExternal
  .\cab-doctor.ps1 -AllowExternal -Samples 2 -Json
  .\cab-doctor.ps1 -Targets http://127.0.0.1:18804/ok -Proxies 127.0.0.1:18804
#>
[CmdletBinding()]
param(
    [string[]]$Proxies = @('127.0.0.1:7897', '127.0.0.1:11119'),
    [string[]]$Targets = @('https://www.baidu.com', 'https://www.google.com'),
    [ValidateRange(1, 5)][int]$Samples = 2,
    [int]$TimeoutSec = 15,
    [string]$PostUrl = '',
    # F74: external egress needs explicit consent.
    [switch]$AllowExternal,
    # Read-only: ignore HKCU proxy for path selection (registry is not changed).
    [switch]$IgnoreSystemProxy,
    [switch]$Json
)
$ErrorActionPreference = 'Continue'

$contractFile = Join-Path $PSScriptRoot 'diag-contract.ps1'
if (-not (Test-Path -LiteralPath $contractFile)) {
    Write-Error ("diag-contract.ps1 not found next to this script: {0}" -f $contractFile)
    exit 3
}
. $contractFile

# ---------------------------------------------------------------------------
# local helpers (machine-state reading and endpoint normalisation only; every
# probe/classification/redaction/exit decision comes from diag-contract.ps1)
# ---------------------------------------------------------------------------

function Resolve-WinInetServer {
    # WinINET allows "host:port" and per-scheme lists ("http=...;https=...").
    param([AllowNull()][string]$Raw)
    if (-not $Raw) { return '' }
    $best = ''
    foreach ($m in [regex]::Matches($Raw, '(?i)(?:^|;)\s*(http|https|socks|socks4|socks5)\s*=\s*([^;]+)')) {
        $key = $m.Groups[1].Value.ToLowerInvariant()
        $val = $m.Groups[2].Value.Trim()
        $scheme = switch ($key) {
            'socks' { 'socks5h://' }
            'socks4' { 'socks4://' }
            'socks5' { 'socks5h://' }
            default { 'http://' }
        }
        $best = $scheme + $val
        if ($key -eq 'http') { break }
    }
    if ($best) { return $best }
    $t = $Raw.Trim()
    if ($t -match '^[A-Za-z][A-Za-z0-9+.-]*://') { return $t }
    return ('http://' + $t)
}

function Get-SystemProxy {
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $p = Get-ItemProperty $k -ErrorAction SilentlyContinue
    $raw = if ($p -and $p.ProxyServer) { [string]$p.ProxyServer } else { '' }
    $resolved = Resolve-WinInetServer $raw
    $bypassEntries = 0
    if ($p -and $p.ProxyOverride) {
        $bypassEntries = @(([string]$p.ProxyOverride) -split ';' | Where-Object { $_ -ne '' }).Count
    }
    $autoconfig = if ($p -and $p.AutoConfigURL) { 'PAC: ' + (Hide-DiagUserInfo ([string]$p.AutoConfigURL)) } else { 'none' }
    return [pscustomobject]@{
        enabled        = [bool]($p -and $p.ProxyEnable)
        resolved       = $resolved
        masked         = $(if ($resolved) { Get-DiagMaskedEndpoint $resolved } else { '' })
        hasCredentials = [bool]($resolved -match '://[^/\s@]*@')
        bypassEntries  = $bypassEntries
        autoconfig     = $autoconfig
    }
}

function Resolve-ProxyArg {
    param([AllowNull()][string]$Value)
    if (-not $Value) { return '' }
    if ($Value -match '^[A-Za-z][A-Za-z0-9+.-]*://') { return $Value }
    return ('http://' + $Value)
}

function Get-ProxyEndpoint {
    param([AllowNull()][string]$Value)
    $v = Resolve-ProxyArg $Value
    $u = $null
    if ([Uri]::TryCreate($v, [UriKind]::Absolute, [ref]$u)) { return ('{0}:{1}' -f $u.Host, $u.Port) }
    return [string]$Value
}

function Test-LoopbackEndpoint {
    param([AllowNull()][string]$Value)
    if (-not $Value) { return $false }
    $text = $Value
    if ($text -notmatch '^[A-Za-z][A-Za-z0-9+.-]*://') { $text = 'http://' + $text }
    $u = $null
    if (-not [Uri]::TryCreate($text, [UriKind]::Absolute, [ref]$u)) { return $false }
    return [bool]$u.IsLoopback
}

function Test-DiagTcpPort {
    param([string]$Endpoint, [int]$TimeoutMs = 1500)
    $v = Resolve-ProxyArg $Endpoint
    $u = $null
    if (-not [Uri]::TryCreate($v, [UriKind]::Absolute, [ref]$u)) { return $false }
    $client = New-Object Net.Sockets.TcpClient
    try {
        $ok = $client.ConnectAsync($u.Host, $u.Port).Wait($TimeoutMs)
        return [bool]$ok
    }
    catch { return $false }
    finally { $client.Close() }
}

# ---------------------------------------------------------------------------
# inputs and plan
# ---------------------------------------------------------------------------
$Proxies = @($Proxies | Where-Object { $_ -and ([string]$_).Trim() })
$Targets = @($Targets | Where-Object { $_ -and ([string]$_).Trim() })

$sp = Get-SystemProxy
$sysActive = [bool]($sp.enabled -and -not $IgnoreSystemProxy)
$sysArg = if ($sysActive) { $sp.resolved } else { '' }
$sysEndpoint = if ($sysArg) { Get-ProxyEndpoint $sysArg } else { '' }

$probeList = New-Object System.Collections.ArrayList
foreach ($p in $Proxies) {
    [void]$probeList.Add([pscustomobject]@{ value = $p; source = 'CLI' })
}
if ($sysActive -and $sysEndpoint) {
    $present = @($probeList | Where-Object { (Get-ProxyEndpoint $_.value) -eq $sysEndpoint })
    if ($present.Count -eq 0) {
        [void]$probeList.Add([pscustomobject]@{ value = $sp.resolved; source = 'SYSTEM' })
    }
}

$targetPlan = @()
foreach ($t in $Targets) {
    $local = Test-LoopbackEndpoint $t
    $targetPlan += [pscustomobject]@{
        url     = $t
        local   = [bool]$local
        allowed = [bool]($AllowExternal -or $local)
    }
}
$externalDeclared = @($targetPlan | Where-Object { -not $_.local } | ForEach-Object { Hide-DiagUserInfo $_.url })
$externalSkipped = @($targetPlan | Where-Object { -not $_.allowed } | ForEach-Object { Hide-DiagUserInfo $_.url })

$report = [ordered]@{
    observedAt      = [datetimeoffset]::Now.ToString('o')
    contract        = Get-DiagContractInfo
    mode            = if ($AllowExternal) { 'ALLOW_EXTERNAL' } else { 'LOCAL_ONLY' }
    consent         = [ordered]@{
        allowExternal           = [bool]$AllowExternal
        localOnlyByDefault      = $true
        externalTargetsDeclared = $externalDeclared
        externalTargetsSkipped  = $externalSkipped
        postUrlRequested        = [bool]$PostUrl
        postUrlSkippedNoConsent = $false
        note                    = 'no outbound request leaves this machine unless -AllowExternal is set; loopback targets are local-controlled'
    }
    systemProxy     = [ordered]@{
        enabled              = $sp.enabled
        serverMasked         = $sp.masked
        hasCredentials       = $sp.hasCredentials
        bypassEntries        = $sp.bypassEntries
        autoconfig           = $sp.autoconfig
        activeForPathSelection = $sysActive
        ignoredBySwitch      = [bool]$IgnoreSystemProxy
    }
    proxyEnv        = Get-DiagProxyEnvFacts
    noProxyHandling = [ordered]@{
        proxied                = $false
        clearedInProbeProcess  = $false
        mechanism              = $script:DiagNoProxyMechanismDirect
        basis                  = $script:DiagNoProxyBasis
    }
    listeners       = [ordered]@{}
    direct          = $null
    proxies         = @()
    upload          = $null
    probes          = @()
    summary         = [ordered]@{
        httpFailures = 0
        uploadFailed = $false
    }
    verdict         = 'UNKNOWN'
    verdictClass    = 'UNUSABLE'
    exitCode        = $script:DiagExit.UNUSABLE
    recovery        = @()
}

# ---------------------------------------------------------------------------
# probes
# ---------------------------------------------------------------------------
$probes = New-Object System.Collections.ArrayList

# 1. direct baseline (loopback targets only unless -AllowExternal)
$directRuns = @()
foreach ($tp in $targetPlan) {
    if (-not $tp.allowed) { continue }
    $pr = Invoke-DiagProbe -Url $tp.url -ProxyArg '' -TimeoutSec $TimeoutSec
    [void]$probes.Add($pr)
    $directRuns += $pr
}
$directBad = $directRuns | Where-Object { -not $_.ok } | Select-Object -First 1
$report.direct = [ordered]@{
    state      = if ($directRuns.Count) { $script:DiagState.MEASURED } else { $script:DiagState.SKIPPED_NO_CONSENT }
    pass       = @($directRuns | Where-Object { $_.ok }).Count
    total      = $directRuns.Count
    transport  = if ($directRuns.Count -and -not $directBad) { 'OK' } elseif ($directBad) { $directBad.transport } else { $null }
    httpStatus = $directBad.httpStatus
    err        = $directBad.err
}

# 2. per-proxy path (system proxy is always included, marked source=SYSTEM)
foreach ($entry in $probeList) {
    $proxyArg = Resolve-ProxyArg $entry.value
    $endpoint = Get-ProxyEndpoint $entry.value
    $proxyLocal = Test-LoopbackEndpoint $entry.value

    $listening = $null
    $listenerState = $script:DiagState.SKIPPED_NO_CONSENT
    if ($proxyLocal -or $AllowExternal) {
        $listening = Test-DiagTcpPort $entry.value
        $listenerState = $script:DiagState.MEASURED
    }
    $report.listeners[$endpoint] = [ordered]@{
        listening = $listening
        state     = $listenerState
        loopback  = $proxyLocal
    }

    $runs = @()
    foreach ($tp in $targetPlan) {
        $allowed = [bool]($AllowExternal -or ($proxyLocal -and $tp.local))
        if (-not $allowed) { continue }
        for ($i = 0; $i -lt $Samples; $i++) {
            $pr = Invoke-DiagProbe -Url $tp.url -ProxyArg $proxyArg -TimeoutSec $TimeoutSec
            [void]$probes.Add($pr)
            $runs += $pr
        }
    }
    $okRuns = @($runs | Where-Object { $_.ok })
    $badRun = $runs | Where-Object { -not $_.ok } | Select-Object -First 1
    $report.proxies += [pscustomobject][ordered]@{
        proxy         = Get-DiagMaskedEndpoint $proxyArg
        endpoint      = $endpoint
        source        = $entry.source
        loopback      = [bool]$proxyLocal
        state         = if ($runs.Count) { $script:DiagState.MEASURED } else { $script:DiagState.SKIPPED_NO_CONSENT }
        listening     = $listening
        listenerState = $listenerState
        pass          = $okRuns.Count
        total         = $runs.Count
        rate          = if ($runs.Count) { [Math]::Round(100.0 * $okRuns.Count / $runs.Count, 0) } else { $null }
        totalP50Ms    = Get-DiagPercentileMs @($okRuns | ForEach-Object { $_.metrics.total }) 0.5
        transport     = if ($runs.Count -and -not $badRun) { 'OK' } elseif ($badRun) { $badRun.transport } else { $null }
        httpStatus    = $badRun.httpStatus
        err           = $badRun.err
    }
}

# 3. optional synthetic upload; always part of the verdict when measured
if ($PostUrl) {
    $postLocal = Test-LoopbackEndpoint $PostUrl
    $viaSystem = $sysActive
    $viaArg = if ($viaSystem) { $sysArg } else { '' }
    $viaLocal = if ($viaSystem) { Test-LoopbackEndpoint $sysArg } else { $true }
    $viaName = if ($viaSystem) { Get-DiagMaskedEndpoint $sysArg } else { 'DIRECT' }
    $allowed = [bool]($AllowExternal -or ($postLocal -and $viaLocal))
    if ($allowed) {
        $buf = New-Object byte[] 8192
        (New-Object System.Random).NextBytes($buf)
        $up = Invoke-DiagProbe -Url $PostUrl -ProxyArg $viaArg -Method POST `
            -Body ('payload=' + [Convert]::ToBase64String($buf)) -TimeoutSec $TimeoutSec
        [void]$probes.Add($up)
        $report.upload = [pscustomobject][ordered]@{
            state      = $script:DiagState.MEASURED
            via        = $viaName
            ok         = $up.ok
            transport  = $up.transport
            httpStatus = $up.httpStatus
            bytes      = $up.metrics.downloadBytes
            err        = $up.err
        }
    }
    else {
        $report.consent.postUrlSkippedNoConsent = $true
        $report.upload = [pscustomobject][ordered]@{
            state      = $script:DiagState.SKIPPED_NO_CONSENT
            via        = $viaName
            ok         = $null
            transport  = $null
            httpStatus = $null
            bytes      = $null
            err        = ''
        }
    }
}

$report.probes = @($probes)
$proxiedProbeCount = @($probes | Where-Object { $_.via -eq 'PROXY' }).Count
$report.noProxyHandling.proxied = ($proxiedProbeCount -gt 0)
$report.noProxyHandling.clearedInProbeProcess = ($proxiedProbeCount -gt 0)
$report.noProxyHandling.mechanism = if ($proxiedProbeCount -gt 0) { $script:DiagNoProxyMechanismProxy } else { $script:DiagNoProxyMechanismDirect }
$report.summary.httpFailures = @($probes | Where-Object {
        $_.transport -eq 'OK' -and -not (Test-DiagHttpSuccess $_.httpStatus)
    }).Count

# ---------------------------------------------------------------------------
# verdict: every input below is measured, and every measured input counts
# ---------------------------------------------------------------------------
$directMeasured = ($report.direct.state -eq $script:DiagState.MEASURED)
$directAllOk = [bool]($directMeasured -and $report.direct.total -gt 0 -and $report.direct.pass -eq $report.direct.total)
$uploadMeasured = [bool]($report.upload -and $report.upload.state -eq $script:DiagState.MEASURED)
$uploadFailed = [bool]($uploadMeasured -and -not $report.upload.ok)
$report.summary.uploadFailed = $uploadFailed
$measuredProxies = @($report.proxies | Where-Object { $_.state -eq $script:DiagState.MEASURED })
$anyProxyOk = @($measuredProxies | Where-Object { $_.pass -gt 0 })
$sysEntry = $null
if ($sysActive -and $sysEndpoint) {
    $sysEntry = $report.proxies | Where-Object { $_.endpoint -eq $sysEndpoint } | Select-Object -First 1
}

$verdict = 'UNKNOWN'
$nothingMeasured = ((-not $directMeasured) -and (@($measuredProxies).Count -eq 0) -and (-not $uploadMeasured))
$unmeasuredExternal = ($externalSkipped.Count -gt 0)

$conclusiveLocalFailure = [bool]($sysActive -and $sysEntry -and $sysEntry.loopback -and
    $sysEntry.listenerState -eq $script:DiagState.MEASURED -and -not $sysEntry.listening)

if ($nothingMeasured) {
    # F74: local-only default.  No internet health claim is allowed; the one
    # conclusive local failure is a loopback system proxy nothing listens on.
    if ($conclusiveLocalFailure) { $verdict = 'SYSTEM_PROXY_PORT_CLOSED' }
    else { $verdict = 'LOCAL_ONLY_UNVERIFIED' }
}
elseif ($unmeasuredExternal) {
    # Some declared targets were skipped for lack of consent: never claim health.
    $verdict = 'LOCAL_ONLY_UNVERIFIED'
}
elseif ($sysActive) {
    if ($sysEntry -and $sysEntry.state -eq $script:DiagState.MEASURED) {
        if ($sysEntry.rate -eq 100 -and -not $uploadFailed) { $verdict = 'HEALTHY' }
        elseif ($sysEntry.rate -eq 100 -and $uploadFailed) { $verdict = 'PARTIAL_UPLOAD_FAILED' }
        elseif ($sysEntry.rate -gt 0) { $verdict = 'PARTIAL' }
        elseif ($directAllOk) { $verdict = 'PROXY_BROKEN_DIRECT_OK' }
        else { $verdict = 'BROKEN' }
    }
    else {
        $verdict = 'LOCAL_ONLY_UNVERIFIED'
    }
}
else {
    # system proxy off (or ignored for path selection): the upload still counts
    # even when it goes direct (F76).
    if ($directAllOk -and -not $uploadFailed) { $verdict = 'DIRECT_ONLY' }
    elseif ($directAllOk -and $uploadFailed) { $verdict = 'DIRECT_ONLY_UPLOAD_FAILED' }
    elseif ($directMeasured -and $report.direct.pass -gt 0) { $verdict = 'PARTIAL' }
    elseif ($directMeasured) { $verdict = 'BROKEN' }
    else { $verdict = 'LOCAL_ONLY_UNVERIFIED' }
}

$verdictClass = switch ($verdict) {
    'HEALTHY' { 'ALL_PASS' }
    'DIRECT_ONLY' { 'ALL_PASS' }
    'BROKEN' { 'UNUSABLE' }
    'SYSTEM_PROXY_PORT_CLOSED' { 'UNUSABLE' }
    'UNKNOWN' { 'UNUSABLE' }
    default { 'PARTIAL' }
}
$exitCode = Get-DiagExitCodeForClass $verdictClass

switch ($verdict) {
    'SYSTEM_PROXY_MISMATCH' {
        $good = $anyProxyOk | Sort-Object rate -Descending | Select-Object -First 1
        if ($good) {
            $report.recovery += ("系统代理指向 {0}，但它不通；而 {1} 可用（实测）。临时恢复：" -f $sp.masked, $good.proxy)
            $report.recovery += ("  Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxyServer -Value '{0}'" -f $good.endpoint)
        }
        else {
            $report.recovery += '系统代理指向的端点无法探测；加 -AllowExternal 让本脚本实测它。'
        }
    }
    'PROXY_BROKEN_DIRECT_OK' {
        $report.recovery += '代理端口在听但出不去：先确认上游客户端（Clash/StarSky）是否在"加速中"，再重试。'
        $report.recovery += '  若上游刚重启，等 10-20 秒后重跑本脚本。'
    }
    'BROKEN' {
        $report.recovery += '基础网络也不通：先确认 Wi-Fi/网卡，再关闭上游客户端系统代理开关对照测试。'
    }
    'PARTIAL' {
        $report.recovery += '部分可用：优先看下表哪个目标/阶段失败，再决定是否切换代理。'
    }
    'PARTIAL_UPLOAD_FAILED' {
        $report.recovery += 'GET 全通但上传失败：看上传的 transport/httpStatus（HTTP 500 表示服务端拒绝，不是断网）。'
    }
    'DIRECT_ONLY_UPLOAD_FAILED' {
        $report.recovery += '直连 GET 全通但上传失败：上传结果已进入判定，退出 2 而非 0。'
    }
    'LOCAL_ONLY_UNVERIFIED' {
        $domainNote = if ($externalDeclared.Count) { ($externalDeclared -join ', ') } else { '(无外部目标)' }
        $report.recovery += ("默认只做本机受控检查，未向 {0} 发请求，因此无法判定公网可达性。" -f $domainNote)
        $report.recovery += '  需要实测时加 -AllowExternal（本脚本会按 -Targets 发起请求并写明域名）。'
    }
    'SYSTEM_PROXY_PORT_CLOSED' {
        $report.recovery += '系统代理端口没有监听：先启动上游客户端（例如 Clash/StarSky）再重跑；本脚本不重启客户端。'
    }
}

$report.verdict = $verdict
$report.verdictClass = $verdictClass
$report.exitCode = $exitCode

# ---------------------------------------------------------------------------
# output
# ---------------------------------------------------------------------------
if ($Json) { $report | ConvertTo-Json -Depth 8 }
else {
    Write-Host ''
    Write-Host '  CAB DOCTOR (read-only)' -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * 84))
    Write-Host ("  契约       : {0}/v{1}   mode={2}" -f $script:DiagContractName, $script:DiagContractVersion, $report.mode)
    if ($externalDeclared.Count) {
        $extNote = if ($AllowExternal) { '已授权（-AllowExternal）：会实际访问' } else { '未授权：SKIPPED_NO_CONSENT，不发送请求' }
        Write-Host ("  会访问的域 : {0}   {1}" -f ($externalDeclared -join ', '), $extNote)
    }
    Write-Host ("  系统代理   : {0}   bypass={1} 条   {2}{3}" -f
        $(if ($sp.enabled) { $sp.masked } else { 'OFF' }), $sp.bypassEntries, $sp.autoconfig,
        $(if ($IgnoreSystemProxy -and $sp.enabled) { '   （-IgnoreSystemProxy：路径选择忽略它，注册表未改）' } else { '' }))
    $presentEnv = @($report.proxyEnv.Keys | Where-Object { $report.proxyEnv[$_].present })
    if ($presentEnv.Count) {
        Write-Host ("  环境变量   : " + (($presentEnv | ForEach-Object {
            if ($_ -match '^no_proxy$') { "$_=***($($report.proxyEnv[$_].entries) 条)" }
            else { "$_=$($report.proxyEnv[$_].valueMasked)" }
        }) -join '  ')) -ForegroundColor DarkGray
    }
    else { Write-Host '  环境变量   : (无)' -ForegroundColor DarkGray }

    if ($report.direct.state -eq $script:DiagState.MEASURED) {
        Write-Host ("  直连基线   : {0}/{1}   {2}" -f $report.direct.pass, $report.direct.total,
            (Format-DiagTransportStatus $report.direct.transport $report.direct.httpStatus))
    }
    else { Write-Host '  直连基线   : SKIPPED_NO_CONSENT（未授权，未向外部目标发请求）' }

    Write-Host ''
    if (@($report.proxies).Count) {
        $report.proxies | Format-Table @{n = '代理'; e = { $_.proxy } },
            @{n = '来源'; e = { $_.source } },
            @{n = '监听'; e = { if ($_.listenerState -eq 'MEASURED') { $_.listening } else { 'SKIP' } } },
            @{n = '状态'; e = { $_.state } },
            @{n = '通过'; e = { if ($_.state -eq 'MEASURED') { "$($_.pass)/$($_.total)" } else { '-' } } },
            @{n = '成功率'; e = { if ($null -ne $_.rate) { "$($_.rate)%" } else { '-' } } },
            @{n = '延迟p50'; e = { if ($null -ne $_.totalP50Ms) { "$($_.totalP50Ms)ms" } else { '' } } },
            @{n = 'transport/httpStatus'; e = { Format-DiagTransportStatus $_.transport $_.httpStatus } } `
            -AutoSize | Out-String -Width 150 | Write-Host
    }
    else { Write-Host '  代理探测   : 没有可探测的代理条目' }

    if ($report.upload) {
        if ($report.upload.state -eq $script:DiagState.MEASURED) {
            $uc = if ($report.upload.ok) { 'Green' } else { 'Red' }
            Write-Host ("  上传(合成8KB): {0}  {1}  via {2}" -f
                $(if ($report.upload.ok) { 'OK' } else { 'FAIL' }),
                (Format-DiagTransportStatus $report.upload.transport $report.upload.httpStatus),
                $report.upload.via) -ForegroundColor $uc
        }
        else { Write-Host '  上传(合成8KB): SKIPPED_NO_CONSENT（未授权，未发送）' -ForegroundColor DarkGray }
    }

    Write-Host ("  NO_PROXY   : " + $(
        if ($report.noProxyHandling.proxied) { $script:DiagNoProxyMechanismProxy }
        else { '本次未做代理探测；直连用 ' + $script:DiagNoProxyMechanismDirect }
    )) -ForegroundColor DarkGray
    Write-Host ("  覆盖依据   : " + $script:DiagNoProxyBasis) -ForegroundColor DarkGray
    Write-Host ("  HTTP 失败  : {0} 个 probe 的 transport=OK 但 httpStatus 不在 2xx/3xx（不算健康）" -f $report.summary.httpFailures) -ForegroundColor DarkGray

    $c = switch ($verdictClass) { 'ALL_PASS' { 'Green' } 'PARTIAL' { 'Yellow' } default { 'Red' } }
    Write-Host ''
    Write-Host ("  判定: {0}   ({1}, exit {2})" -f $verdict, $verdictClass, $exitCode) -ForegroundColor $c
    if ($report.recovery.Count) {
        Write-Host '  建议:'
        $report.recovery | ForEach-Object { Write-Host ("    " + $_) }
    }
    Write-Host ''
}

exit $exitCode
