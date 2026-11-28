#Requires -Version 5.1
<#
Isolated tests for the Skill-side recovery entry (recovery/Invoke-Recovery.ps1).

What runs: a temporary app folder under %TEMP% is populated with the reviewed
engine files from this repository, then the entry is called with a wrong phrase
(expect refusal, nothing started) and with the operation-bound phrase shown by the
entry itself (expect the isolated rehearsal result and CompleteSuccess=true).

Boundaries: the repository engine files are only read. Nothing is written to HKCU,
no client is started or stopped, no live proxy value is changed, and credentials are
not read. The rehearsal itself runs inside its own %TEMP% folder.

This runner needs the repository sources (proxy_v4\, desktop\scripts\) next to the
skill folder. When they are absent it reports NOT_TESTED and exits 2 instead of
pretending to have tested the entry.

Exit: 0 pass, 1 failure, 2 zero tests.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$testDir = Split-Path -Parent $PSCommandPath
$root = Split-Path -Parent $testDir
$entry = Join-Path $root 'recovery\Invoke-Recovery.ps1'
$repo = Split-Path -Parent (Split-Path -Parent $root)

$failures = New-Object System.Collections.Generic.List[string]
$count = 0
function Assert-True($cond, [string]$msg) { if (-not $cond) { throw $msg } }
function Check([string]$name, [scriptblock]$body) {
    $script:count++
    try { & $body; Write-Host ('PASS ' + $name) }
    catch { $script:failures.Add($name + ': ' + $_.Exception.Message); Write-Host ('FAIL ' + $name + ': ' + $_.Exception.Message) }
}

function Get-RecoveryTargetFromRegistry {
    try {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Internet Settings')
        if ($null -eq $key) { return 'unknown' }
        try {
            $enable = $key.GetValue('ProxyEnable')
            $server = $key.GetValue('ProxyServer')
        } finally { $key.Dispose() }
    } catch { return 'unknown' }
    if ($enable -isnot [int]) { return 'unknown' }
    if ($enable -eq 0) { return 'off' }
    if ($enable -ne 1) { return 'unknown' }
    if ($server -is [string] -and $server.Trim() -match '^127\.0\.0\.1:(\d{1,5})$') {
        $port = [int]$Matches[1]
        if ($port -ge 1 -and $port -le 65535) { return '127.0.0.1:' + $port }
    }
    return 'other'
}

function Invoke-Entry([string]$AppRoot, [string]$Phrase) {
    $shell = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
    $outFile = Join-Path $tmp ('entry-' + [guid]::NewGuid().ToString('N') + '.json')
    $errFile = Join-Path $tmp ('entry-' + [guid]::NewGuid().ToString('N') + '.txt')
    # Start-Process keeps the entry's stderr (the consent brief) out of the JSON while
    # still failing loudly if the child does not start.
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $entry + '"'), '-Json')
    if (-not [string]::IsNullOrEmpty($AppRoot)) { $arguments += @('-AppRoot', ('"' + $AppRoot + '"')) }
    if (-not [string]::IsNullOrEmpty($Phrase)) { $arguments += @('-ConfirmPhrase', ('"' + $Phrase + '"')) }
    $process = Start-Process -FilePath $shell -ArgumentList $arguments `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile -NoNewWindow -Wait -PassThru
    $json = Get-Content -LiteralPath $outFile -Raw -Encoding UTF8
    Remove-Item -LiteralPath $outFile -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $errFile -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Exit = $process.ExitCode; Result = ($json | ConvertFrom-Json) }
}

$rollback = Join-Path $repo 'proxy_v4\rollback-v4.ps1'
$library = Join-Path $repo 'proxy_v4\lib\V4.ps1'
$wrapper = Join-Path $repo 'desktop\scripts\Invoke-IsolatedRecovery.ps1'
$trustSource = Join-Path $repo 'desktop\src\ProxyDoctor.Core\RecoveryTrust.cs'
if (-not (Test-Path -LiteralPath $entry -PathType Leaf) -or
    -not (Test-Path -LiteralPath $rollback -PathType Leaf) -or
    -not (Test-Path -LiteralPath $library -PathType Leaf) -or
    -not (Test-Path -LiteralPath $wrapper -PathType Leaf) -or
    -not (Test-Path -LiteralPath $trustSource -PathType Leaf)) {
    Write-Host 'NOT_TESTED: the repository engine sources are not next to this skill folder.'
    exit 2
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('wpdoctor-recovery-test-' + [guid]::NewGuid().ToString('N'))
$app = Join-Path $tmp 'app'
$engine = Join-Path $app 'engine'
New-Item -ItemType Directory -Path (Join-Path $engine 'proxy_v4\lib') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $engine 'scripts') -Force | Out-Null
Copy-Item -LiteralPath $rollback -Destination (Join-Path $engine 'proxy_v4\rollback-v4.ps1')
Copy-Item -LiteralPath $library -Destination (Join-Path $engine 'proxy_v4\lib\V4.ps1')
Copy-Item -LiteralPath $wrapper -Destination (Join-Path $engine 'scripts\Invoke-IsolatedRecovery.ps1')
$manifest = [ordered]@{
    schemaVersion = 1
    engineVersion = 'v4.0'
    files         = @(
        [ordered]@{ path = 'proxy_v4/rollback-v4.ps1'; sha256 = (Get-FileHash -LiteralPath (Join-Path $engine 'proxy_v4\rollback-v4.ps1') -Algorithm SHA256).Hash },
        [ordered]@{ path = 'proxy_v4/lib/V4.ps1'; sha256 = (Get-FileHash -LiteralPath (Join-Path $engine 'proxy_v4\lib\V4.ps1') -Algorithm SHA256).Hash },
        [ordered]@{ path = 'scripts/Invoke-IsolatedRecovery.ps1'; sha256 = (Get-FileHash -LiteralPath (Join-Path $engine 'scripts\Invoke-IsolatedRecovery.ps1') -Algorithm SHA256).Hash }
    )
}
[System.IO.File]::WriteAllText((Join-Path $engine 'engine-manifest.json'), ($manifest | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))

$target = Get-RecoveryTargetFromRegistry
$phrase = 'RECOVER-ISOLATED ' + $target

try {
    Check 'skill-entry-points-at-the-packaged-engine' {
        $text = Get-Content -LiteralPath $entry -Raw -Encoding UTF8
        Assert-True ($text.Contains('Invoke-IsolatedRecovery.ps1')) 'entry does not call the packaged engine wrapper'
        Assert-True ($text.Contains('engine-manifest.json')) 'entry does not read the engine manifest'
        Assert-True ($text.Contains('RECOVER-ISOLATED')) 'entry does not carry the bound operation name'
        Assert-True ($text.Contains('真实生产写入：未实现')) 'entry does not state that the production write is not implemented'
        Assert-True ($text.Contains('不写 HKCU Internet Settings')) 'entry does not state that it avoids the live proxy key'
        Assert-True ($text.Contains('RecoveryVerdict.ps1')) 'entry does not reuse the existing verdict'
    }

    Check 'pinned-hashes-match-proxy-doctor-core' {
        $trust = Get-Content -LiteralPath $trustSource -Raw -Encoding UTF8
        $entryText = Get-Content -LiteralPath $entry -Raw -Encoding UTF8
        $pairs = @(
            @{ field = 'RollbackSha256'; name = 'proxy_v4\rollback-v4.ps1' },
            @{ field = 'LibrarySha256'; name = 'proxy_v4\lib\V4.ps1' },
            @{ field = 'ScriptSha256'; name = 'scripts\Invoke-IsolatedRecovery.ps1' }
        )
        foreach ($pair in $pairs) {
            $match = [regex]::Match($trust, $pair.field + '\s*=\s*"([0-9A-Fa-f]{64})"')
            Assert-True $match.Success ('RecoveryTrust.' + $pair.field + ' not found')
            $value = $match.Groups[1].Value.ToUpperInvariant()
            Assert-True ($entryText.ToUpperInvariant().Contains($value)) ('skill entry does not pin ' + $pair.name)
        }
        $skillRollback = [regex]::Match($entryText, "'proxy_v4\\rollback-v4\.ps1'\s*=\s*'([0-9A-Fa-f]{64})'").Groups[1].Value.ToUpperInvariant()
        Assert-True ($skillRollback -eq (Get-FileHash -LiteralPath $rollback -Algorithm SHA256).Hash.ToUpperInvariant()) 'pinned rollback hash differs from the reviewed file'
    }

    Check 'missing-engine-is-refused-without-starting' {
        $run = Invoke-Entry (Join-Path $tmp 'no-such-app') $phrase
        Assert-True ($run.Exit -eq 1) ('exit=' + $run.Exit)
        Assert-True ($run.Result.authorized -eq $false) 'engine refusal claimed authorization'
        Assert-True ($run.Result.ScriptStarted -eq $false) 'engine refusal started a script'
        Assert-True (($run.Result.Reasons -join ' ') -match 'engine unavailable') 'engine refusal reason missing'
    }

    Check 'wrong-phrase-is-refused-and-starts-nothing' {
        foreach ($wrong in @('RECOVER-ISOLATED 127.0.0.1:1', 'RECOVER-ISOLATED OFF', 'recover-isolated ' + $target, 'YES', '')) {
            $run = Invoke-Entry $app $wrong
            Assert-True ($run.Exit -eq 1) ('phrase <' + $wrong + '> exit=' + $run.Exit)
            Assert-True ($run.Result.authorized -eq $false) ('phrase <' + $wrong + '> was accepted')
            Assert-True ($run.Result.ScriptStarted -eq $false) ('phrase <' + $wrong + '> started a script')
            Assert-True ($run.Result.CompleteSuccess -eq $false) ('phrase <' + $wrong + '> counted as success')
        }
    }

    Check 'tampered-engine-is-refused' {
        $tamper = Join-Path $engine 'proxy_v4\lib\V4.ps1'
        $original = [System.IO.File]::ReadAllText($tamper)
        try {
            [System.IO.File]::WriteAllText($tamper, $original + "`r`n# tampered`r`n")
            $run = Invoke-Entry $app $phrase
            Assert-True ($run.Exit -eq 1) ('tampered engine exit=' + $run.Exit)
            Assert-True ($run.Result.ScriptStarted -eq $false) 'tampered engine started a script'
            Assert-True (($run.Result.Detail -join ' ') -match 'SHA-256|reviewed|whitelist') 'tampered engine refusal is not specific'
        } finally {
            [System.IO.File]::WriteAllText($tamper, $original)
        }
    }

    Check 'bound-phrase-runs-the-isolated-rehearsal' {
        $run = Invoke-Entry $app $phrase
        Assert-True ($run.Exit -eq 0) ('exit=' + $run.Exit)
        Assert-True ($run.Result.authorized -eq $true) 'authorization missing'
        Assert-True ($run.Result.grantedBy -eq 'skill-user-phrase') 'grant source missing'
        Assert-True ($run.Result.target -eq $target) 'target is not the bound one'
        Assert-True ($run.Result.ScriptStarted -eq $true) 'script did not start'
        Assert-True ($run.Result.TransactionExit -eq 32) ('transaction exit=' + $run.Result.TransactionExit)
        Assert-True ($run.Result.ProfileRestored -eq $true) 'profile was not restored'
        Assert-True ($run.Result.WritesMatch -eq $true) 'writes do not match the scenario'
        Assert-True ($run.Result.JournalClear -eq $true) 'journal was not cleared'
        Assert-True ($run.Result.LiveUnchanged -eq $true) 'live proxy fingerprint changed'
        Assert-True ($run.Result.CompleteSuccess -eq $true) ('incomplete: ' + ($run.Result.Reasons -join ','))
        Assert-True ($run.Result.Writes.Trim() -eq 'enabled=0 server=old:8080') 'raw writes differ'
    }

    Check 'skill-md-documents-the-three-stages' {
        $skill = Get-Content -LiteralPath (Join-Path $root 'SKILL.md') -Raw -Encoding UTF8
        Assert-True ($skill.Contains('只读诊断')) 'missing read-only diagnosis section'
        Assert-True ($skill.Contains('隔离演练')) 'missing isolated rehearsal section'
        Assert-True ($skill.Contains('需要授权的真实操作')) 'missing authorized real-operation section'
        Assert-True ($skill.Contains('真实生产写入未实现')) 'missing the not-implemented statement'
        Assert-True ($skill.Contains('recovery/Invoke-Recovery.ps1')) 'skill does not point at the recovery entry'
        Assert-True ($skill.Contains('RECOVER-ISOLATED')) 'skill does not explain the bound phrase'
    }
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ('COUNTS=' + $count + ' failures=' + $failures.Count)
if ($failures.Count) { $failures | ForEach-Object { Write-Host ('  - ' + $_) }; exit 1 }
if ($count -eq 0) { exit 2 }
exit 0
