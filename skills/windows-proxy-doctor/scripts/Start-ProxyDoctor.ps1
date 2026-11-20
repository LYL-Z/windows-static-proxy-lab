#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Auto','Setup','Diagnose')][string]$Goal = 'Auto',
    [ValidateSet('Unknown','Working','Broken')][string]$NetworkStatus = 'Unknown',
    [ValidateSet('None','UseCurrentSoftware','InstallationDeclined','InstallationReported','UseExistingService',
        'SkipService','ConfigurationDeclined','ChangeReported','RollbackRequested','RollbackReported')]
    [string]$Decision = 'None',
    [ValidateSet('UNKNOWN','AVAILABLE','UNAVAILABLE')][string]$BrowserTool = 'UNKNOWN',
    [ValidateSet('UNKNOWN','AVAILABLE','UNAVAILABLE')][string]$DesktopTool = 'UNKNOWN',
    [string]$CheckpointPath,
    [string[]]$VerifyUrl,
    [switch]$Json,
    [string]$TestFixture
)
$ErrorActionPreference = 'Stop'

function New-DoctorAction($step, $why, $operation, $permissions, $confirmation, $back, $assistance) {
    [ordered]@{
        step = $step; why = $why; operation = $operation; permissionsOrCost = $permissions
        confirm = $confirmation; onFailure = $back; assistance = $assistance
    }
}

function Read-DoctorCheckpoint([string]$Path) {
    if (-not $Path -or -not [IO.File]::Exists($Path)) {
        return [ordered]@{ schema = 1; goal = $Goal; software = 'Pending'; service = 'Pending'; change = 'Pending' }
    }
    try {
        if ([IO.FileInfo]::new($Path).Length -gt 8192) { throw 'oversize' }
        $saved = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
        $allowed = @{goal=@('Auto','Setup','Diagnose'); software=@('Pending','Current','Declined','Reported')
            service=@('Pending','Existing','Skipped'); change=@('Pending','Declined','Reported','RollbackPending','RollbackReported')}
        if ($saved.schema -ne 1) { throw 'schema' }
        $result = [ordered]@{ schema = 1 }
        foreach ($field in 'goal','software','service','change') {
            if ($saved.$field -isnot [string] -or $saved.$field -cnotin $allowed[$field]) { throw 'field' }
            $result[$field] = $saved.$field
        }
        return $result
    } catch { throw '无法读取检查点。原文件已保留，请另选空目录或检查原文件的格式。' }
}

function Save-DoctorCheckpoint([string]$Path, $State) {
    $temp = Join-Path ([IO.Path]::GetDirectoryName($Path)) ([guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $State.updatedAt = [DateTimeOffset]::UtcNow.ToString('o')
        [IO.File]::WriteAllText($temp, ($State | ConvertTo-Json -Depth 3))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temp, $Path) }
    } finally {
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
    }
}

function Measure-DoctorWebAccess([uri[]]$Urls) {
    if (-not $Urls.Count) { return }
    Add-Type -AssemblyName System.Net.Http
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.Proxy = [Net.WebRequest]::GetSystemWebProxy()
    $handler.UseCookies = $false
    $handler.UseDefaultCredentials = $false
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(10)
    try {
        foreach ($uri in $Urls) {
            try {
                $response = $client.GetAsync($uri, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
                try { [int]$response.StatusCode } finally { $response.Dispose() }
            } catch { 0 }
        }
    } finally { $client.Dispose() }
}

if ($TestFixture -and $VerifyUrl) { throw '夹具模式无法发起真实访问。' }
if ($VerifyUrl.Count -gt 2) { throw '每次最多验证两个站点。' }
$targets = @(foreach ($target in $VerifyUrl) {
    [uri]$parsed = $null
    if (-not [uri]::TryCreate($target, [UriKind]::Absolute, [ref]$parsed) -or $parsed.Scheme -ne 'https' -or
        $parsed.UserInfo -or $parsed.Query -or $parsed.Fragment -or $target -match '[?#@]') {
        throw '验证地址须为无凭据、无查询参数、无片段的 HTTPS 地址。'
    }
    $parsed
})

$checkpoint = $null
$mutex = $null
$held = $false
try {
    if ($CheckpointPath) {
        $checkpoint = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($CheckpointPath)
        $drive = [IO.Path]::GetPathRoot($checkpoint)
        $folder = [IO.Path]::GetDirectoryName($checkpoint)
        if ($drive -notmatch '^[A-Za-z]:\\$' -or -not [IO.Directory]::Exists($folder) -or
            [IO.Path]::GetFileName($checkpoint) -ine 'windows-proxy-doctor-checkpoint.json') {
            throw '请在已有的本地目录内保存 windows-proxy-doctor-checkpoint.json。'
        }
        if ([IO.DriveInfo]::new($drive).DriveType -notin @('Fixed','Removable','Ram')) {
            throw '检查点需要本地磁盘。'
        }
        for ($entry = [IO.DirectoryInfo]::new($folder); $entry; $entry = $entry.Parent) {
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '检查点目录需要使用本地实体路径。' }
        }
        $hash = [Security.Cryptography.SHA256]::Create()
        try { $lockId = [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($checkpoint.ToUpperInvariant()))).Replace('-', '') }
        finally { $hash.Dispose() }
        $mutex = [Threading.Mutex]::new($false, "Global\WindowsProxyDoctor-$lockId")
        try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw '另一个向导正在使用该检查点。请稍后重试。' }
        if ([IO.File]::Exists($checkpoint) -and ([IO.File]::GetAttributes($checkpoint) -band [IO.FileAttributes]::ReparsePoint)) {
            throw '检查点需要使用普通本地文件。'
        }
    }

    $progress = Read-DoctorCheckpoint $checkpoint
    if ($PSBoundParameters.ContainsKey('Goal')) { $progress.goal = $Goal }
    $discovery = Join-Path $PSScriptRoot 'Get-ProxyDoctorEnvironment.ps1'
    $environment = & $discovery -BrowserTool $BrowserTool -DesktopTool $DesktopTool -AsObject -TestFixture $TestFixture
    $observedProxy = $environment.proxy
    $signal = 'CHECK_APPLICATION'
    $explanation = '请把客户端界面、Windows 代理、监听端口和实际应用访问分别核对。'
    if ($observedProxy.pacConfigured -eq $true) {
        $signal = 'PAC_PRESENT'
        $explanation = 'Windows 配置了自动代理脚本。先核对具体应用实际选用的路径。'
    } elseif ($observedProxy.manualEnabled -eq $true -and $observedProxy.targetListenerObserved -eq $false) {
        $signal = 'LISTENER_MISSING'
        $explanation = 'Windows 指向的本机端口没有观察到可用监听。先核对客户端是否运行和端口是否一致。'
    } elseif ($observedProxy.manualEnabled -eq $true -and $observedProxy.clashSavedEnabled -eq $true -and
        $observedProxy.targetPort -and $observedProxy.targetListenerObserved -eq $true -and
        $observedProxy.targetClient -notin @('clashVerge','mihomo')) {
        $signal = 'POSSIBLE_OWNER_MISMATCH'
        $explanation = 'Clash 显示应管理系统代理，但 Windows 选中的本机端口由其他或未知进程监听。请先核实预期归属。'
    } elseif ($observedProxy.manualEnabled -eq $false -and $observedProxy.clashSavedEnabled -eq $true) {
        $signal = 'SAVED_SYSTEM_STATE_DIFFER'
        $explanation = 'Clash 保存的开关和 Windows 手动代理状态不同。先核对你希望使用的设置和应用选路。'
    }
    $recognized = @($environment.clients.starsky, $environment.clients.clashVerge | Where-Object {
        $_.installation -in @('REGISTERED','PORTABLE_OR_UNREGISTERED') -or $_.running -eq $true
    }).Count
    $audience = switch ($recognized) { 0 { 'UNCONFIRMED' }; 1 { 'PARTIAL_INSTALLATION' }; 2 { 'CLIENTS_DETECTED' } }
    if ($NetworkStatus -eq 'Broken') { $audience = 'NETWORK_PROBLEM_REPORTED' }
    $mode = $progress.goal
    if ($mode -eq 'Auto') {
        $mode = if ($NetworkStatus -eq 'Broken' -or $recognized -eq 2 -or $environment.proxy.manualEnabled -eq $true -or
            $environment.proxy.pacConfigured -eq $true) { 'Diagnose' } else { 'Setup' }
    }
    switch ($Decision) {
        'UseCurrentSoftware' { $progress.software = 'Current' }
        'InstallationDeclined' { $progress.software = 'Declined' }
        'InstallationReported' { $progress.software = 'Reported' }
        'UseExistingService' { $progress.service = 'Existing' }
        'SkipService' { $progress.service = 'Skipped' }
        'ConfigurationDeclined' {
            if ($progress.change -ne 'Pending') { throw '检查点已有变更记录。请先核实实际状态。' }
            $progress.change = 'Declined'
        }
        'ChangeReported' {
            if ($mode -ne 'Setup' -or $progress.change -ne 'Pending' -or $progress.service -ne 'Existing' -or
                ($recognized -lt 2 -and $progress.software -ne 'Current')) { throw '请先完成准备并核对配置方案，再记录已实施的变更。' }
            $progress.change = 'Reported'
        }
        'RollbackRequested' {
            if ($progress.change -ne 'Reported') { throw '检查点没有待回退的变更记录。' }
            $progress.change = 'RollbackPending'
        }
        'RollbackReported' {
            if ($progress.change -ne 'RollbackPending') { throw '请先记录回退请求，再记录回退结果。' }
            $progress.change = 'RollbackReported'
        }
    }
    if ($progress.goal -eq 'Auto' -and ($progress.software -ne 'Pending' -or $progress.service -ne 'Pending')) {
        $progress.goal = $mode
    }
    $http = @(Measure-DoctorWebAccess $targets)
    $verification = if (-not $http.Count) { 'NOT_TESTED' }
        elseif (@($http | Where-Object { $_ -ge 200 -and $_ -lt 300 }).Count -eq $http.Count) { 'HTTPS_REACHABLE' }
        else { 'PARTIAL_OR_FAILED' }
    $assistance = if ($DesktopTool -eq 'AVAILABLE') { '可在你另行授权后协助操作界面。' } else { '请按指引手动操作，向导继续提供只读检查。' }
    if ($progress.change -eq 'RollbackPending') {
        $state = 'ROLLBACK_REQUIRED'
        $action = New-DoctorAction 'rollback' '需要恢复先前确认的状态。' '按已核实的原值逐项回退。Agent 在做任何改动前重新询问授权。' '修改需要单独授权。' '复查原设置、监听及受测网站，再记录 RollbackReported。' '保留原有备份。无法核实原值时暂停写入。' $assistance
    } elseif ($environment.windows.supported -eq $false) {
        $state = 'BLOCKED'
        $action = New-DoctorAction 'unsupported-environment' '未检测到支持的 Windows 环境。' '请在要检查的 Windows 10 或 11 电脑运行只读发现。' '无需更改本机权限。' '核对采集结果中的系统类型，再决定是否继续。' '可先按应用自己的故障手册检查。' $assistance
    } elseif ($progress.change -in @('Reported','RollbackReported')) {
        $state = if ($verification -eq 'HTTPS_REACHABLE') { 'PARTIAL' } else { 'VERIFYING' }
        $action = New-DoctorAction 'verify' '已记录操作者报告，需要现场验证应用和原始配置。' '用日常应用访问指定站点，并核对监听和 Windows 实际选路。可用 VerifyUrl 补测。' '验证本身只读。' '分别记录 HTTPS 与日常应用的结果，注明是否由本人观察。' '若访问仍异常，重新检查并按原计划申请回退。' $assistance
    } elseif ($mode -eq 'Diagnose' -or $progress.software -eq 'Declined' -or $progress.change -eq 'Declined') {
        $state = if ($verification -eq 'HTTPS_REACHABLE' -and $NetworkStatus -ne 'Broken' -and $signal -eq 'CHECK_APPLICATION') { 'COMPLETED' } else { 'PARTIAL' }
        $action = New-DoctorAction 'diagnose' '需要区分 Windows 配置、本机监听和网站访问。' '对照故障手册，告诉 Agent 哪个应用和网站失败。可指定 HTTPS 测试地址。' '只读，无需购买服务。' '分别核对系统选路、实际监听及上下游测试。' '保留当前设置，转到故障手册中的对应场景。' $assistance
    } elseif ($recognized -lt 2 -and $progress.software -ne 'Current') {
        $state = 'WAITING_USER'
        $action = New-DoctorAction 'software' 'StarSky 或 Clash Verge 的安装尚未全部确认。' '核对已安装的客户端。需要时从官方来源准备安装包，或选用当前软件继续。' '安装前确认权限、来源和校验信息。' '安装后选择 InstallationReported 并重新发现；继续用现有软件请选择 UseCurrentSoftware。' '校验失败或不想安装时选择 InstallationDeclined，继续诊断。' $assistance
    } elseif ($progress.service -eq 'Pending') {
        $state = 'WAITING_USER'
        $action = New-DoctorAction 'service' '不同网络需求可以使用已有服务，也可以只做诊断。' '选择已有服务，或跳过服务准备。可选供应商资料与邀请利益见参考页。' '费用以当时官方页面为准。购买、登录和凭据输入由用户完成。' '可选择 UseExistingService 或 SkipService。' '无法核实价格和服务条款时保留原方案。' $assistance
    } elseif ($progress.service -eq 'Skipped') {
        $state = 'PARTIAL'
        $action = New-DoctorAction 'diagnose' '已跳过服务准备。' '继续检查现有网络和应用访问。' '只读，无需付款。' '记录受测网站和结果。' '根据故障手册继续检查，无需修改配置。' $assistance
    } else {
        $state = 'READY_FOR_REVIEW'
        $action = New-DoctorAction 'configuration-review' '环境与已有服务已进入方案核对。' '对照官方客户端功能和当前实际系统代理，逐项核对原值、建议值、影响和回退。' '每项更改需操作当时的明确授权。' '用户或 Agent 实际改动后选择 ChangeReported。' '选择 ConfigurationDeclined 可保留网络并继续诊断。' $assistance
    }

    if ($checkpoint) { Save-DoctorCheckpoint $checkpoint $progress }
    $out = [ordered]@{
        schema = 1; source = $environment.source; mode = $mode; audience = $audience; state = $state
        action = $action; environment = $environment; diagnostic = [ordered]@{ code = $signal; explanation = $explanation }
        verification = [ordered]@{ status = $verification; statusCodes = $http; userReportedNetwork = $NetworkStatus }
        checkpointSaved = [bool]$checkpoint
        authorization = 'NEVER_PERSISTED'
    }
    if ($Json) { $out | ConvertTo-Json -Depth 10 }
    else {
        Write-Output ('{0} · {1}' -f $state, $action.step)
        Write-Output $explanation
        foreach ($field in 'why','operation','permissionsOrCost','confirm','onFailure','assistance') { Write-Output $action[$field] }
    }
} finally {
    if ($held) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
}
