#Requires -Version 5.1
<#
  recovery/Invoke-Recovery.ps1 - the only Skill-side recovery entry.

  What this script does:
    1. resolves the packaged engine folder (<AppRoot>\engine) and verifies the
       manifest plus the reviewed SHA-256 values carried below;
    2. prints the same consent text the Desktop dialog and the CLI show;
    3. runs the reviewed engine wrapper <engine>\scripts\Invoke-IsolatedRecovery.ps1
       in a throw-away TEMP folder and passes its result through;
    4. judges that result with the existing scripts/RecoveryVerdict.ps1.

  What this script never does: it does not implement recovery logic, does not write
  HKCU Internet Settings, does not change the system proxy, does not restart or close
  a client and does not read credentials. V4_TEST_MODE is process-local logic, not an
  operating-system sandbox.

  Authorization: the caller must pass the operation-bound phrase that a person typed
  after seeing the consent text, e.g. -ConfirmPhrase 'RECOVER-ISOLATED 127.0.0.1:7897'.
  A phrase for another target, another case, an extra word or an empty value is a
  refusal; nothing is started and read-only diagnosis remains available.

  Exit: 0 complete success, 1 refused before any script started, 2 started but not complete.
#>
[CmdletBinding()]
param(
    [string]$AppRoot,
    [string]$ConfirmPhrase,
    [switch]$Json
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$RequiredEngineVersion = 'v4.0'
$ExpectedTransactionExit = 32

# Must stay identical to ProxyDoctor.RecoveryTrust in
# desktop/src/ProxyDoctor.Core/RecoveryTrust.cs. tests/Run-RecoveryTests.ps1 proves it.
# The wrapper script hash is LF-normalised, the other two are the raw file bytes.
$ReviewedSha = [ordered]@{
    'proxy_v4\rollback-v4.ps1'            = '04EDBA1C16A854F09E45A50F5C084D82A17B868787C5D007CBFC20A4D951EEE9'
    'proxy_v4\lib\V4.ps1'                 = '4D41D4D652690340D6FE75009D1D0CA7B1F9656989578806C251E72D5BABCC7D'
    'scripts\Invoke-IsolatedRecovery.ps1' = '6F0EA61E1668F8D16DE5973066ABB9FCF688BE97C9C7BB054356FEBC191C9999'
}

$OperationName = 'RECOVER-ISOLATED'
$TargetOff = 'off'
$TargetOther = 'other'
$TargetUnknown = 'unknown'

function Get-EngineRootFrom([string]$Root) {
    try { $full = [System.IO.Path]::GetFullPath($Root) } catch { return $null }
    foreach ($candidate in @($full, (Join-Path $full 'CLI'), (Join-Path $full 'Desktop'))) {
        $engine = Join-Path $candidate 'engine'
        if (Test-Path -LiteralPath (Join-Path $engine 'engine-manifest.json') -PathType Leaf) { return $engine }
    }
    return $null
}

function Find-EngineRoot([string]$Root) {
    if (-not [string]::IsNullOrWhiteSpace($Root)) { return (Get-EngineRootFrom $Root) }
    $bases = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $bases.Add((Join-Path $env:LOCALAPPDATA 'Programs\ProxyDoctor'))
        $bases.Add((Join-Path $env:LOCALAPPDATA 'ProxyDoctor'))
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $bases.Add((Join-Path $env:ProgramFiles 'ProxyDoctor'))
    }
    foreach ($base in $bases) {
        if (-not (Test-Path -LiteralPath $base -PathType Container)) { continue }
        $found = Get-EngineRootFrom $base
        if ($found) { return $found }
    }
    return $null
}

function Get-Sha256([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }

function Get-LfSha256([string]$Path) {
    $text = [System.IO.File]::ReadAllText($Path).Replace("`r`n", "`n").Replace("`r", "`n")
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text)) }
    finally { $sha.Dispose() }
    return ([System.BitConverter]::ToString($bytes)).Replace('-', '')
}

function Get-RegistryProxyValues {
    $values = @{ Enable = $null; Server = $null; Readable = $false }
    try {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Internet Settings')
        if ($null -eq $key) { return $values }
        try {
            $values.Enable = $key.GetValue('ProxyEnable')
            $values.Server = $key.GetValue('ProxyServer')
            $values.Readable = $true
        } finally { $key.Dispose() }
    } catch { }
    return $values
}

function Get-RecoveryTarget {
    $values = Get-RegistryProxyValues
    if (-not $values.Readable) { return $TargetUnknown }
    if ($values.Enable -isnot [int]) { return $TargetUnknown }
    if ($values.Enable -eq 0) { return $TargetOff }
    if ($values.Enable -ne 1) { return $TargetUnknown }
    if ($values.Server -is [string] -and $values.Server.Trim() -match '^127\.0\.0\.1:(\d{1,5})$') {
        $port = [int]$Matches[1]
        if ($port -ge 1 -and $port -le 65535) { return '127.0.0.1:' + $port }
    }
    return $TargetOther
}

function Get-LiveProxyStamp {
    $values = Get-RegistryProxyValues
    if (-not $values.Readable) { return 'unreadable' }
    $enable = if ($null -eq $values.Enable) { 'missing' } else { [string]$values.Enable }
    $server = if ($null -eq $values.Server) { '' } else { [string]$values.Server }
    return $enable + '|' + $server
}

function Test-EnginePackage([string]$EngineRoot) {
    $found = New-Object System.Collections.Generic.List[string]
    $manifestPath = Join-Path $EngineRoot 'engine-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        $found.Add('missing engine-manifest.json')
        return $found
    }
    try { $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch {
        $found.Add('cannot read engine-manifest.json')
        return $found
    }

    if ([int]$manifest.schemaVersion -ne 1) { $found.Add('unsupported manifest schemaVersion') }
    if ([string]$manifest.engineVersion -ne $RequiredEngineVersion) {
        $found.Add('incompatible engineVersion ' + [string]$manifest.engineVersion)
    }

    $declared = @{}
    foreach ($entry in @($manifest.files)) {
        $relative = ([string]$entry.path).Replace('/', '\')
        if ($relative -ne $relative.Trim() -or $relative -match '^\\' -or
            $relative -match '[:*?"<>|]' -or $relative -match '(^|\\)\.\.?(\\|$)') {
            $found.Add('unsafe manifest path')
            continue
        }
        if (-not $ReviewedSha.Contains($relative)) {
            $found.Add('manifest lists a file outside the whitelist: ' + $relative)
            continue
        }
        if ($declared.ContainsKey($relative)) {
            $found.Add('manifest lists ' + $relative + ' twice')
            continue
        }
        $declared[$relative] = $true
        $full = Join-Path $EngineRoot $relative
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            $found.Add('missing engine file: ' + $relative)
            continue
        }
        $fileItem = Get-Item -LiteralPath $full -Force
        if (($fileItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            $found.Add('engine file is a reparse point: ' + $relative)
            continue
        }
        $actual = Get-Sha256 $full
        if (-not $actual.Equals([string]$entry.sha256, [StringComparison]::OrdinalIgnoreCase)) {
            $found.Add('SHA-256 mismatch against the manifest for ' + $relative)
            continue
        }
        $reviewedActual = if ($relative -eq 'scripts\Invoke-IsolatedRecovery.ps1') { Get-LfSha256 $full } else { $actual }
        if (-not $reviewedActual.Equals([string]$ReviewedSha[$relative], [StringComparison]::OrdinalIgnoreCase)) {
            $found.Add('file does not match the reviewed hash: ' + $relative)
        }
    }
    foreach ($required in $ReviewedSha.Keys) {
        if (-not $declared.ContainsKey($required)) { $found.Add('manifest does not list required file ' + $required) }
    }
    return $found
}

function Write-RecoveryOutcome($Outcome, [int]$Code) {
    if ($Json) { $Outcome | ConvertTo-Json -Depth 5 }
    else {
        foreach ($name in $Outcome.Keys) { Write-Host ($name + '=' + [string]$Outcome[$name]) }
    }
    exit $Code
}

# The existing Skill judgement: it must not be re-implemented here.
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\RecoveryVerdict.ps1')

$issues = New-Object System.Collections.Generic.List[string]
$engineRoot = Find-EngineRoot $AppRoot
if (-not $engineRoot) {
    $issues.Add('engine folder not found under the given app folder; install the packaged Desktop/CLI first')
} else {
    $issues = Test-EnginePackage $engineRoot
}

$target = Get-RecoveryTarget
$phrase = $OperationName + ' ' + $target
# Strict ordinal comparison: PowerShell's -eq is case-insensitive, which let
# "RECOVER-ISOLATED OFF" authorise a target of "off" and diverged from the C#
# RecoveryConsent implementation (StringComparison.Ordinal).
$authorized = [string]::Equals(
    ([string]$ConfirmPhrase).Trim(),
    $phrase,
    [System.StringComparison]::Ordinal
)

# Interpolation, not '+': inside a multi-line @() a plus-expression would be parsed
# with the array separator binding tighter than '+', splitting each line into pieces.
$briefLines = @(
    '隔离演练授权（不是真实生产写入）',
    "操作：$OperationName（隔离演练）",
    "目标：$target",
    '操作范围：在 %TEMP% 下新建一次性目录，把随包且哈希相符的 rollback-v4.ps1 与 V4.ps1 复制进去，用 V4_TEST_MODE=1 运行一次回滚演练。只运行随包 Engine，不实现别的恢复逻辑。',
    '受影响资源：只影响这次的一次性临时目录和其中的测试夹具。不写 HKCU Internet Settings，不改注册表，不重启客户端，不读写凭据，不启动或关闭任何客户端进程。',
    '是否写系统代理：否。执行前后各读一次 ProxyEnable/ProxyServer；这只证明两次读取相同，不能证明中间没有写入。',
    '回滚方式：结束时删除这个临时目录。当前用户代理没有被本次操作改动，因此没有系统状态需要回滚。',
    '真实生产写入：未实现。Executor 固定 V4_TEST_MODE + stub，不会写真实系统代理。',
    '拒绝授权后仍可继续只读诊断。',
    "确认短语：$phrase"
)
# The brief goes to stderr so stdout stays machine-readable (-Json) and so a caller can
# print it verbatim to the person before asking for the phrase.
foreach ($line in $briefLines) { [Console]::Error.WriteLine($line) }

if (-not $engineRoot) {
    Write-RecoveryOutcome ([ordered]@{
            mode = 'isolated-rehearsal'; productionWrite = 'not-implemented'; authorized = $false
            grantedBy = ''; target = $target; phrase = $phrase; CompleteSuccess = $false
            ScriptStarted = $false; Reasons = @('engine unavailable'); Detail = ($issues -join '; ')
        }) 1
}

if (-not $authorized) {
    Write-RecoveryOutcome ([ordered]@{
            mode = 'isolated-rehearsal'; productionWrite = 'not-implemented'; authorized = $false
            grantedBy = ''; target = $target; phrase = $phrase; CompleteSuccess = $false
            ScriptStarted = $false; Reasons = @('authorization phrase did not match this operation and target')
            Detail = '没有授权。没有启动脚本。拒绝后仍可继续只读诊断。'
        }) 1
}

if ($issues.Count -ne 0) {
    Write-RecoveryOutcome ([ordered]@{
            mode = 'isolated-rehearsal'; productionWrite = 'not-implemented'; authorized = $true
            grantedBy = 'skill-user-phrase'; target = $target; phrase = $phrase; CompleteSuccess = $false
            ScriptStarted = $false; Reasons = @('engine package refused'); Detail = ($issues -join '; ')
        }) 1
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('proxy-doctor-skill-recovery-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null

$verdictInput = [pscustomobject]@{
    ScriptStarted           = $false
    Cancelled               = $false
    TimedOut                = $false
    ProcessExit             = -1
    TransactionExit         = 40
    ExpectedTransactionExit = $ExpectedTransactionExit
    ProfileRestored         = $false
    WritesMatch             = $false
    Writes                  = ''
    JournalClear            = $false
    LiveUnchanged           = $true
}
$detail = ''
$engineDetail = 'engine manifest and reviewed hashes verified at ' + $engineRoot
$processExit = -1
$before = Get-LiveProxyStamp
try {
    $shell = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
    $wrapper = Join-Path $engineRoot 'scripts\Invoke-IsolatedRecovery.ps1'
    $verdictInput.ScriptStarted = $true
    $null = & $shell -NoProfile -ExecutionPolicy Bypass -File $wrapper `
        -EngineRoot $engineRoot -WorkRoot $work `
        -ExpectedRollbackSha $ReviewedSha['proxy_v4\rollback-v4.ps1'] `
        -ExpectedLibrarySha $ReviewedSha['proxy_v4\lib\V4.ps1'] 2>&1
    $processExit = $LASTEXITCODE
    $resultPath = Join-Path $work 'result.json'
    if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
        $raw = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $verdictInput.TransactionExit = [int]$raw.exitCode
        $verdictInput.ProfileRestored = [bool]$raw.profileRestored
        $verdictInput.Writes = [string]$raw.writes
        $verdictInput.WritesMatch = (Test-ProxyDoctorRecoveryWrites ([string]$raw.writes))
        $hasJournal = $null -ne $raw.PSObject.Properties['journalRemains']
        $verdictInput.JournalClear = ($hasJournal -and -not [bool]$raw.journalRemains)
        $detail = [string]$raw.detail
    } else {
        $detail = '脚本没有留下结果。'
    }
} catch {
    $detail = '隔离脚本没有跑完：' + $_.Exception.GetType().Name
} finally {
    $after = Get-LiveProxyStamp
    $verdictInput.ProcessExit = $processExit
    $verdictInput.LiveUnchanged = ($before -eq $after)
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

$verdict = Test-ProxyDoctorRecoveryResult $verdictInput
$success = [bool]$verdict.CompleteSuccess
$exitCode = if ($success) { 0 } else { 2 }

Write-RecoveryOutcome ([ordered]@{
        mode = 'isolated-rehearsal'; productionWrite = 'not-implemented'; authorized = $true
        grantedBy = 'skill-user-phrase'; target = $target; phrase = $phrase
        CompleteSuccess = $success
        ScriptStarted = $verdictInput.ScriptStarted
        ProcessExit = $verdictInput.ProcessExit
        TransactionExit = $verdictInput.TransactionExit
        ExpectedTransactionExit = $verdictInput.ExpectedTransactionExit
        ProfileRestored = $verdictInput.ProfileRestored
        WritesMatch = $verdictInput.WritesMatch
        Writes = $verdictInput.Writes
        JournalClear = $verdictInput.JournalClear
        LiveUnchanged = $verdictInput.LiveUnchanged
        EvidenceScope = $verdict.EvidenceScope
        Reasons = @($verdict.Reasons)
        Engine = $engineDetail
        Detail = $detail
    }) $exitCode
