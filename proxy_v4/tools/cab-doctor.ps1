#Requires -Version 5.1
<#
.SYNOPSIS  CAB Doctor - one file, read-only, runnable now.
.DESCRIPTION
  Answers one question: "can this machine actually reach the internet right now,
  and if not, at which layer does it fail?"

  It never writes: no registry, no config, no process restart, no proxy change.
  It prints the exact recovery command instead of executing it.

  Layers checked, in order:
    1. system proxy      HKCU Internet Settings (what WinINET/Edge/Chrome use)
    2. listeners         is anything listening on the proxy port
    3. proxy env         *_PROXY / NO_PROXY (redacted; curl obeys these, browsers obey layer 1)
    4. direct path       curl --noproxy * (is the base network alive)
    5. proxy path        explicit -x (curl does NOT read layer 1)
    6. upload path       optional synthetic 8KB POST (never user data)

  Exit: 0 all good, 2 partial, 3 broken.

.EXAMPLE
  .\cab-doctor.ps1
  .\cab-doctor.ps1 -Json
  .\cab-doctor.ps1 -Proxies 127.0.0.1:7897,127.0.0.1:11119 -Samples 2
#>
[CmdletBinding()]
param(
    [string[]]$Proxies = @('127.0.0.1:7897', '127.0.0.1:11119'),
    [string[]]$Targets = @('https://www.baidu.com', 'https://www.google.com'),
    [ValidateRange(1, 5)][int]$Samples = 2,
    [int]$TimeoutSec = 15,
    [string]$PostUrl = '',
    [switch]$Json
)
$ErrorActionPreference = 'Continue'

function Get-SystemProxy {
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $p = Get-ItemProperty $k -ErrorAction SilentlyContinue
    [pscustomobject]@{
        enabled = [bool]$p.ProxyEnable
        server  = if ($p.ProxyServer) { $p.ProxyServer } else { '' }
        bypass  = if ($p.ProxyOverride) { $p.ProxyOverride } else { '' }
        autoconfig = if ($p.AutoConfigURL) { 'PAC: ' + $p.AutoConfigURL } else { 'none' }
    }
}

function Get-ProxyEnv {
    # values are redacted: only presence + a scheme://***@host:port shape is reported
    $o = [ordered]@{}
    foreach ($n in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY','http_proxy','https_proxy','no_proxy')) {
        $v = [Environment]::GetEnvironmentVariable($n)
        if (-not $v) { continue }
        if ($n -match 'NO_PROXY') { $o[$n] = ({ $v -split ',' }.Invoke()).Count.ToString() + ' entr(y/ies)' ; continue }
        $o[$n] = ($v -replace '//[^@/]*@', '//***:***@')
    }
    $o
}

function Test-Port([string]$HostPort) {
    $hp = $HostPort -split ':'
    try {
        $c = New-Object Net.Sockets.TcpClient
        $ok = $c.ConnectAsync($hp[0], [int]$hp[1]).Wait(1500)
        $c.Close(); return $ok
    } catch { return $false }
}

function Invoke-Probe {
    param([string]$Url, [string]$ProxyArg, [string]$Method = 'GET', [string]$Body = $null)
    $fmt = 'code=%{http_code};conn=%{time_connect};tls=%{time_appconnect};total=%{time_total}'
    $cargs = @('-sS', '-m', "$TimeoutSec", '-o', 'NUL', '-w', $fmt)
    if ($ProxyArg) { $cargs += @('-x', $ProxyArg) } else { $cargs += @('--noproxy', '*') }
    if ($Method -eq 'POST') { $cargs += @('-X', 'POST', '--data-binary', $Body) }
    $cargs += $Url
    $err = [IO.Path]::GetTempFileName()
    try {
        $raw = & curl.exe @cargs 2> $err
        $rc = $LASTEXITCODE
        $et = ''
        try { $et = (Get-Content -LiteralPath $err -Raw -ErrorAction SilentlyContinue) } catch { }
        if ($null -eq $et) { $et = '' }
    } finally { Remove-Item -LiteralPath $err -Force -ErrorAction SilentlyContinue }
    $m = ($raw -join ' ')
    $code = $null; $total = $null
    if ($m -match 'code=(\d+);conn=([\d\.]+);tls=([\d\.]+);total=([\d\.]+)') { $code = [int]$Matches[1]; $total = [double]$Matches[4] }
    $kind = switch ($rc) {
        0 { 'OK' }; 6 { 'DNS_FAIL' }; 7 { 'CONNECT_REFUSED' }; 28 { 'TIMEOUT' }
        35 { 'TLS_FAIL' }; 52 { 'EMPTY_REPLY' }; 56 { 'RECV_FAIL' }; 60 { 'CERT_FAIL' }
        default { 'OTHER' }
    }
    [pscustomobject]@{
        ok = ($rc -eq 0 -and $code -ge 200 -and $code -lt 400)
        rc = $rc; kind = $kind; code = $code; totalMs = if ($total) { [Math]::Round($total * 1000, 0) } else { $null }
        err = (($et -replace '\s+', ' ').Trim())
    }
}

$sp = Get-SystemProxy
$envs = Get-ProxyEnv
$report = [ordered]@{
    observedAt = [datetimeoffset]::Now.ToString('o')
    systemProxy = $sp
    proxyEnv = $envs
    listeners = [ordered]@{}
    direct = $null
    proxies = @()
    upload = $null
    verdict = 'UNKNOWN'
    recovery = @()
}

foreach ($p in $Proxies) { $report.listeners[$p] = (Test-Port $p) }

# base network: does anything work at all?
$directRuns = @()
foreach ($t in $Targets) { $directRuns += Invoke-Probe -Url $t -ProxyArg '' }
$dOk = @($directRuns | Where-Object { $_.ok }).Count
$report.direct = [pscustomobject]@{
    pass = $dOk; total = $directRuns.Count
    kind = ($directRuns | Where-Object { -not $_.ok } | Select-Object -First 1).kind
}

foreach ($p in $Proxies) {
    $listening = $report.listeners[$p]
    $runs = @()
    foreach ($t in $Targets) { for ($i = 0; $i -lt $Samples; $i++) { $runs += Invoke-Probe -Url $t -ProxyArg ('http://' + $p) } }
    $okN = @($runs | Where-Object { $_.ok }).Count
    $bad = @($runs | Where-Object { -not $_.ok })
    $report.proxies += [pscustomobject]@{
        proxy = $p; listening = $listening
        pass = $okN; total = $runs.Count
        rate = if ($runs.Count) { [Math]::Round(100.0 * $okN / $runs.Count, 0) } else { 0 }
        kind = ($bad | Select-Object -First 1).kind
        totalP50Ms = if ((@($runs | Where-Object { $_.ok })).Count) {
            [int]((@($runs | Where-Object { $_.ok } | ForEach-Object { $_.totalMs }) | Sort-Object)[[int]((@($runs | Where-Object { $_.ok })).Count / 2)])
        } else { $null }
        err = ($bad | Select-Object -First 1).err
    }
}

if ($PostUrl) {
    $buf = New-Object byte[] 8192
    (New-Object System.Random).NextBytes($buf)
    $sysAgent = if ($sp.enabled -and $sp.server) { $sp.server } else { $null }
    $up = Invoke-Probe -Url $PostUrl -ProxyArg $(if ($sysAgent) { 'http://' + $sysAgent } else { '' }) -Method POST -Body ('payload=' + [Convert]::ToBase64String($buf))
    $report.upload = [pscustomobject]@{ via = $(if ($sysAgent) { $sysAgent } else { 'DIRECT' }); ok = $up.ok; code = $up.code; kind = $up.kind }
}

# ---- verdict: the system proxy is what the browser actually uses ----
$sys = $report.proxies | Where-Object { $_.proxy -eq $sp.server } | Select-Object -First 1
$anyProxy = @($report.proxies | Where-Object { $_.rate -gt 0 })
$uploadBad = ($report.upload -and -not $report.upload.ok)

if (-not $sp.enabled) {
    if ($report.direct.pass -eq $report.direct.total) { $report.verdict = 'DIRECT_ONLY' }
    else { $report.verdict = 'BROKEN' }
}
elseif ($sys -and $sys.rate -ge 100 -and -not $uploadBad) { $report.verdict = 'HEALTHY' }
elseif ($sys -and $sys.rate -gt 0) { $report.verdict = 'PARTIAL' }
elseif (-not $sys -and $anyProxy.Count) { $report.verdict = 'SYSTEM_PROXY_MISMATCH' }
elseif ($report.direct.pass -gt 0) { $report.verdict = 'PROXY_BROKEN_DIRECT_OK' }
else { $report.verdict = 'BROKEN' }

switch ($report.verdict) {
    'SYSTEM_PROXY_MISMATCH' {
        $good = $anyProxy | Sort-Object rate -Descending | Select-Object -First 1
        $report.recovery += ("系统代理指向 {0}，但它不通；而 {1} 可用。临时恢复：" -f $sp.server, $good.proxy)
        $report.recovery += ("  Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxyServer -Value '{0}'" -f $good.proxy)
    }
    'PROXY_BROKEN_DIRECT_OK' {
        $report.recovery += '代理端口在听但出不去：先确认上游客户端（StarSky/Clash）是否在"加速中"，再重试。'
        $report.recovery += '  若上游刚重启，等 10-20 秒后重跑本脚本。'
    }
    'BROKEN' {
        $report.recovery += '基础网络也不通：先确认 Wi-Fi/网卡，再关闭 Clash 的系统代理开关对照测试。'
    }
    'PARTIAL' {
        $report.recovery += '部分可用：优先看下表哪个目标/阶段失败，再决定是否切换代理。'
    }
}

if ($Json) { $report | ConvertTo-Json -Depth 6 }
else {
    Write-Host ''
    Write-Host '  CAB DOCTOR (read-only)' -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * 78))
    Write-Host ("  系统代理   : " + $(if ($sp.enabled) { $sp.server } else { 'OFF' }) + "   bypass=" + $sp.bypass.Length + " 字符   " + $sp.autoconfig)
    if ($envs.Count) { Write-Host ("  环境变量   : " + (($envs.Keys | ForEach-Object { "$_=$($envs[$_])" }) -join '  ')) -ForegroundColor DarkGray }
    else { Write-Host '  环境变量   : (无)' -ForegroundColor DarkGray }
    Write-Host ("  直连基线   : {0}/{1}  {2}" -f $report.direct.pass, $report.direct.total, $(if ($report.direct.kind) { $report.direct.kind } else { '' }))
    Write-Host ''
    $report.proxies | Format-Table @{n='代理';e={$_.proxy}}, @{n='监听';e={$_.listening}}, @{n='通过';e={"$($_.pass)/$($_.total)"}},
        @{n='成功率';e={"$($_.rate)%"}}, @{n='延迟p50';e={ if ($_.totalP50Ms) { "$($_.totalP50Ms)ms" } else { '' } }}, @{n='失败类型';e={$_.kind}} -AutoSize | Out-String -Width 120 | Write-Host
    if ($report.upload) { Write-Host ("  上传(合成8KB): {0} via {1}" -f $(if ($report.upload.ok) { 'OK' } else { 'FAIL ' + $report.upload.kind }), $report.upload.via) }
    $c = switch ($report.verdict) { 'HEALTHY' { 'Green' } 'DIRECT_ONLY' { 'Yellow' } 'PARTIAL' { 'Yellow' } default { 'Red' } }
    Write-Host ''
    Write-Host ("  判定: {0}" -f $report.verdict) -ForegroundColor $c
    if ($report.recovery.Count) { Write-Host '  建议:'; $report.recovery | ForEach-Object { Write-Host ("    " + $_) } }
    Write-Host ''
}

switch ($report.verdict) {
    'HEALTHY' { exit 0 }
    'DIRECT_ONLY' { exit 0 }
    'PARTIAL' { exit 2 }
    'SYSTEM_PROXY_MISMATCH' { exit 2 }
    default { exit 3 }
}
