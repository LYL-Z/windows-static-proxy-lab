#Requires -Version 5.1
<#
  One synthetic case outside the 15 recovery rows and the 19 preparation
  assertions: a parseable apply-preparation journal whose wasAligned flag
  is true while wasRunning is false. Rollback must refuse ResumeClient
  with exit 34, and a dry-run apply must refuse with exit 34. The journal
  bytes stay in place and no test-mode start is recorded.

  Uses an isolated TEMP root. Does not read or write the live Windows
  proxy, firewall, DNS, clients, or real snapshots.
#>
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ne 5) { throw 'Windows PowerShell 5.1 required' }

$saved = @{
    V4_TEST_MODE = $env:V4_TEST_MODE
    V4_TEST_ROOT = $env:V4_TEST_ROOT
    V4_TEST_START_LOG = $env:V4_TEST_START_LOG
    V4_TEST_PROXY_ENABLE = $env:V4_TEST_PROXY_ENABLE
    V4_TEST_PROXY_SERVER = $env:V4_TEST_PROXY_SERVER
    V4_TEST_UI_SYSTEM_PROXY = $env:V4_TEST_UI_SYSTEM_PROXY
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('cab-f35-' + [guid]::NewGuid().ToString('N'))
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$startLog = Join-Path $root 'start.log'
$failed = $false

function Restore-Env {
    foreach ($name in @($script:saved.Keys)) {
        $value = $script:saved[$name]
        if ($null -eq $value) { Remove-Item -Path ('Env:' + $name) -ErrorAction SilentlyContinue }
        else { Set-Item -Path ('Env:' + $name) -Value $value }
    }
}

function Assert-Check([string]$Label, [bool]$Passed, [string]$Detail) {
    if (-not $Passed) { throw ('FAIL ' + $Label + $(if ($Detail) { ' ' + $Detail } else { '' })) }
    Write-Output ('PASS ' + $Label)
}

function Write-Preparation([bool]$WasRunning, [bool]$WasAligned) {
    $entry = [ordered]@{
        schema = 1
        reason = 'apply-preparation'
        port = 9
        wasRunning = $WasRunning
        wasAligned = $WasAligned
    }
    $path = Get-V4JournalPath
    $directory = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory | Out-Null
    }
    if (-not (Protect-V4Acl -Path $directory)) { throw 'cannot protect journal directory' }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [IO.File]::WriteAllText($path, ($entry | ConvertTo-Json -Compress), $utf8)
    if (-not (Protect-V4Acl -Path $path)) { throw 'cannot protect journal file' }
    return $path
}

function Invoke-Candidate([string]$ScriptPath, [string[]]$Arguments) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $ScriptPath @Arguments 2>&1
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($output) }
    }
    finally { $ErrorActionPreference = $prev }
}

try {
    New-Item -ItemType Directory -Path $root | Out-Null
    $env:V4_TEST_MODE = '1'
    $env:V4_TEST_ROOT = $root
    $env:V4_TEST_START_LOG = $startLog
    $env:V4_TEST_PROXY_ENABLE = '1'
    $env:V4_TEST_PROXY_SERVER = '127.0.0.1:9'
    $env:V4_TEST_UI_SYSTEM_PROXY = '1'
    . (Join-Path $repo 'proxy_v4\lib\V4.ps1')
    if (-not $script:TestMode -or $script:Root -ne [IO.Path]::GetFullPath($root)) {
        throw 'fixture did not stay in the isolated test root'
    }

    $journal = Write-Preparation $true $true
    $consistent = Get-V4Journal
    Assert-Check 'consistent preparation journal is readable' (
        $consistent -and $consistent.preparation -and -not $consistent.corrupt
    ) ''

    $journal = Write-Preparation $false $true
    $item = Get-Item -LiteralPath $journal -Force
    Assert-Check 'corrupt fixture is a normal file' (
        -not $item.PSIsContainer -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
    ) ''
    $planted = Get-V4Journal
    Assert-Check 'aligned-without-running preparation journal is corrupt' (
        $planted -and $planted.preparation -and $planted.corrupt -and
        $planted.data.wasAligned -eq $true -and $planted.data.wasRunning -eq $false
    ) ''
    $hash = (Get-FileHash -LiteralPath $journal -Algorithm SHA256).Hash

    $rollback = Invoke-Candidate (Join-Path $repo 'proxy_v4\rollback-v4.ps1') @('-ResolvePreparation', 'ResumeClient')
    $rollbackText = ($rollback.Output | Out-String)
    Assert-Check 'ResumeClient on a corrupt preparation journal exits 34' ($rollback.ExitCode -eq 34) $rollbackText
    Assert-Check 'refused resume leaves the journal bytes unchanged' (
        (Test-Path -LiteralPath $journal) -and ((Get-FileHash -LiteralPath $journal -Algorithm SHA256).Hash -eq $hash)
    ) ''
    Assert-Check 'refused resume does not record a client start' (-not (Test-Path -LiteralPath $startLog)) ''
    Assert-Check 'refused resume releases the fixture lock' (-not (Test-Path -LiteralPath (Join-Path $root 'config\.lock'))) ''

    $apply = Invoke-Candidate (Join-Path $repo 'proxy_v4\apply-v4.ps1') @('-DryRun')
    $applyText = ($apply.Output | Out-String)
    Assert-Check 'dry-run apply refuses the corrupt preparation journal with exit 34' ($apply.ExitCode -eq 34) $applyText
    Assert-Check 'refused apply leaves the journal bytes unchanged' (
        (Test-Path -LiteralPath $journal) -and ((Get-FileHash -LiteralPath $journal -Algorithm SHA256).Hash -eq $hash)
    ) ''
    Assert-Check 'refused apply does not record a client start' (-not (Test-Path -LiteralPath $startLog)) ''
}
catch {
    $failed = $true
    Write-Output ('FAIL ' + $_.Exception.Message)
}
finally {
    Restore-Env
    if ($root -and (Test-Path -LiteralPath $root)) {
        $tempFull = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
        $rootFull = [IO.Path]::GetFullPath($root).TrimEnd('\')
        $leaf = Split-Path -Leaf $rootFull
        $inside = $rootFull.StartsWith($tempFull + '\', [StringComparison]::OrdinalIgnoreCase)
        if ($inside -and $leaf -match '^cab-f35-[a-f0-9]{32}$') {
            Remove-Item -LiteralPath $rootFull -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($failed) { exit 1 }
Write-Output 'CAB-CORRUPT-PREPARATION OK'
exit 0
