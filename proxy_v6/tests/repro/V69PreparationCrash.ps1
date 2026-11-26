#Requires -Version 5.1
[CmdletBinding()]
param([switch]$Worker, [switch]$Crash, [string]$LegacyRoot)

$ErrorActionPreference = 'Stop'
$shell = Join-Path $PSHOME 'powershell.exe'
if ($Worker) {
    if ($env:V4_TEST_MODE -ne '1' -or -not $env:V4_PREP_FIXTURE_ROOT) { throw 'invalid worker scope' }
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, [int]$env:V4_PREP_FIXTURE_PORT)
    try {
        $listener.Start()
        [IO.File]::WriteAllText((Join-Path $env:V4_PREP_FIXTURE_ROOT 'listening'), [string]$PID)
        Start-Sleep -Seconds 120
    }
    finally { $listener.Stop() }
    return
}
if ($Crash) {
    . (Join-Path $env:V4_PREP_FIXTURE_ROOT 'candidate\lib\V4.ps1')
    if (-not $script:TestMode) { throw 'invalid crash fixture scope' }
    $ops = @{
        RecordsPreparation = $true
        GetSystemProxy = { Get-V4SystemProxy }
        IsAppRunning = { @(Get-V4AppPids).Count -gt 0 }
        Snapshot = { param($reason) New-V4Snapshot -Reason $reason -Port ([int]$env:V4_PREP_FIXTURE_PORT) }
    }
    $result = Invoke-V4ApplyTransaction -Context @{ Ops=$ops; Reason='apply-strict' }
    if ($env:V4_PREP_NO_STOP -eq '1') { exit $result.exitCode }
    throw 'crash hook did not fire'
}

function Check([string]$Label, [bool]$Passed) {
    if (-not $Passed) { throw ('FAIL ' + $Label) }
    Write-Output ('PASS ' + $Label)
}

$temp = [IO.Path]::GetTempPath()
$root = Join-Path $temp ('v69-prep-' + [guid]::NewGuid().ToString('N'))
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$stage = Join-Path $root 'candidate'
$fixtureLibrary = Join-Path $stage 'lib\V4.ps1'
$reserve = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$reserve.Start()
$port = $reserve.LocalEndpoint.Port
$reserve.Stop()
$env:V4_TEST_MODE = '1'
$env:V4_TEST_ROOT = $root
$env:V4_TEST_APPDATA = Join-Path $root 'app'
$env:V4_PREP_FIXTURE_ROOT = $root
$env:V4_PREP_FIXTURE_PORT = [string]$port
$env:V4_PREP_FIXTURE_SCRIPT = $PSCommandPath
$env:V4_PREP_LIBRARY = Join-Path $repo 'proxy_v4\lib\V4.ps1'
$env:V4_PREP_NO_STOP = '0'
$env:V4_TEST_UI_SYSTEM_PROXY = '1'
$selection = Join-Path $root 'selection.json'
$target = '127.0.0.1:' + $port

function Set-Selection([bool]$Enabled, [string]$Server) {
    [IO.File]::WriteAllText($selection, (@{enabled=$Enabled; server=$Server} | ConvertTo-Json -Compress))
}

function Start-IsolatedWorker {
    Remove-Item -LiteralPath (Join-Path $root 'listening') -ErrorAction SilentlyContinue
    $proc = Start-Process -FilePath $shell -ArgumentList ('-NoProfile -NonInteractive -File "' + $PSCommandPath + '" -Worker') -WindowStyle Hidden -PassThru
    $info = @{pid=$proc.Id; started=$proc.StartTime.ToUniversalTime().Ticks}
    [IO.File]::WriteAllText((Join-Path $root 'worker.json'), ($info | ConvertTo-Json -Compress))
    $deadline = [datetime]::UtcNow.AddSeconds(8)
    while ([datetime]::UtcNow -lt $deadline -and -not $proc.HasExited) {
        $ready = Join-Path $root 'listening'
        if ([IO.File]::Exists($ready) -and [IO.File]::ReadAllText($ready) -eq [string]$proc.Id) { return $true }
        Start-Sleep -Milliseconds 50
    }
    if (-not $proc.HasExited) { $proc.Kill(); $proc.WaitForExit() }
    return $false
}

New-Item -ItemType Directory -Path (Split-Path -Parent $fixtureLibrary),$env:V4_TEST_APPDATA | Out-Null
foreach ($scriptFile in 'apply-v4.ps1','rollback-v4.ps1','state-v4.ps1') {
    Copy-Item -LiteralPath (Join-Path $repo "proxy_v4\$scriptFile") -Destination $stage
}
$body = @'
. $env:V4_PREP_LIBRARY
if (-not $script:TestMode -or $env:V4_PREP_FIXTURE_ROOT -ne $script:Root) { throw 'fixture requires isolated test mode' }
function Get-V69FixtureWorker {
    $raw = Join-Path $script:Root 'worker.json'
    if (-not [IO.File]::Exists($raw)) { return $null }
    $held = [IO.File]::ReadAllText($raw) | ConvertFrom-Json
    $p = Get-Process -Id ([int]$held.pid) -ErrorAction SilentlyContinue
    if ($p -and $p.ProcessName -eq 'powershell' -and $p.StartTime.ToUniversalTime().Ticks -eq [long]$held.started) { return $p }
    return $null
}
function Get-V4AppPids { $p=Get-V69FixtureWorker; if ($p) { $p.Id } }
function Stop-V4Clash {
    param([int]$Port)
    $p = Get-V69FixtureWorker
    if (-not $p) { throw 'missing controlled listener' }
    $p.Kill()
    $p.WaitForExit()
    [Environment]::Exit(91)
}
function Get-V4SystemProxy {
    [IO.File]::ReadAllText((Join-Path $script:Root 'selection.json')) | ConvertFrom-Json
}
function Get-V4AutomaticProxyStatus { 'NOT_OBSERVED' }
function Get-V4Paths {
    @{
        AppData=$env:V4_TEST_APPDATA; Core='fixture-core'; Exe='fixture-exe';
        ProfilesDir=(Join-Path $env:V4_TEST_APPDATA 'profiles');
        RuntimeFile=(Join-Path $env:V4_TEST_APPDATA 'clash-verge.yaml')
    }
}
function Test-V4ClashListener {
    param([int]$Port, [string]$ExpectedCore, [switch]$RequireImagePath)
    return ($ExpectedCore -eq 'fixture-core' -and $RequireImagePath -and $null -ne (Get-V69FixtureWorker) -and (Test-V4Port -Port $Port))
}
function Start-V4Clash {
    param([int]$TimeoutSec, [int]$Port)
    if ($Port -ne [int]$env:V4_PREP_FIXTURE_PORT -or (Get-V69FixtureWorker)) { throw 'unexpected fixture launch' }
    Add-Content -LiteralPath (Join-Path $script:Root 'launch.log') -Value 'launch'
    $ready = Join-Path $script:Root 'listening'
    Remove-Item -LiteralPath $ready -ErrorAction SilentlyContinue
    $shell = Join-Path $PSHOME 'powershell.exe'
    $proc = Start-Process -FilePath $shell -ArgumentList ('-NoProfile -NonInteractive -File "' + $env:V4_PREP_FIXTURE_SCRIPT + '" -Worker') -WindowStyle Hidden -PassThru
    $info = @{pid=$proc.Id; started=$proc.StartTime.ToUniversalTime().Ticks}
    [IO.File]::WriteAllText((Join-Path $script:Root 'worker.json'), ($info | ConvertTo-Json -Compress))
    $deadline = [datetime]::UtcNow.AddSeconds(8)
    while ([datetime]::UtcNow -lt $deadline -and -not $proc.HasExited) {
        if ([IO.File]::Exists($ready) -and [IO.File]::ReadAllText($ready) -eq [string]$proc.Id) {
            if ($env:V4_PREP_EXIT_AFTER_START -eq '1') { [Environment]::Exit(92) }
            return $true
        }
        Start-Sleep -Milliseconds 50
    }
    if (-not $proc.HasExited) { $proc.Kill(); $proc.WaitForExit() }
    return $false
}
'@
[IO.File]::WriteAllText($fixtureLibrary, $body)
. $fixtureLibrary
try {
    $profile = Join-Path $env:V4_TEST_APPDATA 'profiles.yaml'
    [IO.File]::WriteAllText($profile, 'synthetic-untouched')
    $originalHash = (Get-FileHash -LiteralPath $profile).Hash
    $journal = Get-V4JournalPath
    $directory = Split-Path -Parent $journal
    New-Item -ItemType Directory -Path $directory | Out-Null
    Set-Selection $true $target
    Check 'fixture client initially listens' (Start-IsolatedWorker)
    if ($LegacyRoot) {
        $env:V4_PREP_LIBRARY = Join-Path $LegacyRoot 'proxy_v4\lib\V4.ps1'
        & $shell -NoProfile -NonInteractive -File $PSCommandPath -Crash
        Check 'baseline stops the real isolated listener before a journal exists' ($LASTEXITCODE -eq 91 -and -not (Test-Path $journal) -and -not (Test-V4Port -Port $port))
        $env:V4_PREP_LIBRARY = Join-Path $repo 'proxy_v4\lib\V4.ps1'
        Check 'fixture listener restarted for candidate tests' (Start-IsolatedWorker)
    }
    $env:V4_PREP_NO_STOP = '1'
    & $shell -NoProfile -NonInteractive -File $PSCommandPath -Crash
    Check 'unprotected journal directory prevents stopping the listener' ($LASTEXITCODE -eq 34 -and -not (Test-Path $journal) -and (Test-V4Port -Port $port))
    $env:V4_PREP_NO_STOP = '0'
    if (-not (Protect-V4Acl -Path $directory)) { throw 'fixture cannot secure journal directory' }
    & $shell -NoProfile -NonInteractive -File $PSCommandPath -Crash
    Check 'candidate stops real isolated listener and retains durable journal after process exit' ($LASTEXITCODE -eq 91 -and (Test-Path -LiteralPath $journal) -and -not (Test-V4Port -Port $port))
    $receipt = Get-V4Journal
    Check 'retained journal distinguishes snapshot preparation from completed backup' ($receipt.preparation -and -not $receipt.corrupt -and $receipt.data.wasAligned -and -not $receipt.data.snapshot)
    $writtenHash = (Get-FileHash -LiteralPath $journal).Hash
    $rollback = Join-Path $stage 'rollback-v4.ps1'
    $state = & $shell -NoProfile -NonInteractive -File (Join-Path $stage 'state-v4.ps1') -Json | ConvertFrom-Json
    Check 'independent state detects interrupted preparation' ($state.recoveryAction -eq 'REVIEW_INTERRUPTED_PREPARATION')
    & $shell -NoProfile -NonInteractive -File (Join-Path $stage 'apply-v4.ps1') -DryRun | Out-Null
    Check 'ordinary apply refuses pending preparation' ($LASTEXITCODE -eq 34)
    & $shell -NoProfile -NonInteractive -File $rollback | Out-Null
    Check 'ordinary rollback refuses rather than restoring a different snapshot' ($LASTEXITCODE -eq 34)
    Set-Selection $false $target
    & $shell -NoProfile -NonInteractive -File $rollback -ResolvePreparation ResumeClient | Out-Null
    Check 'user-off is preserved with no restart' ($LASTEXITCODE -eq 41 -and -not (Get-V4SystemProxy).enabled -and -not (Test-Path (Join-Path $root 'launch.log')))
    Set-Selection $true 'unrelated.invalid:17777'
    & $shell -NoProfile -NonInteractive -File $rollback -ResolvePreparation ResumeClient | Out-Null
    Check 'new proxy selection is preserved with no restart' ($LASTEXITCODE -eq 41 -and (Get-V4SystemProxy).server -eq 'unrelated.invalid:17777' -and -not (Test-Path (Join-Path $root 'launch.log')))
    Check 'refusals leave the pre-stop record unchanged' ((Get-FileHash -LiteralPath $journal).Hash -eq $writtenHash)
    Set-Selection $true $target
    $env:V4_PREP_EXIT_AFTER_START = '1'
    & $shell -NoProfile -NonInteractive -File $rollback -ResolvePreparation ResumeClient | Out-Null
    Check 'interrupted resume retains preparation after client starts' ($LASTEXITCODE -eq 92 -and (Test-V4Port -Port $port) -and (Test-Path -LiteralPath $journal))
    $env:V4_PREP_EXIT_AFTER_START = '0'
    & $shell -NoProfile -NonInteractive -File $rollback -ResolvePreparation ResumeClient | Out-Null
    Check 'resumed resolution verifies the real listener and does not start twice' ($LASTEXITCODE -eq 0 -and (Test-V4Port -Port $port) -and -not (Test-Path $journal) -and @(Get-Content (Join-Path $root 'launch.log')).Count -eq 1)
    & $shell -NoProfile -NonInteractive -File $PSCommandPath -Crash
    Check 'second interruption leaves pending preparation' ($LASTEXITCODE -eq 91 -and (Get-V4Journal).preparation)
    Set-Selection $false $target
    & $shell -NoProfile -NonInteractive -File $rollback -ResolvePreparation KeepCurrent | Out-Null
    Check 'explicit KeepCurrent retires preparation without launching' ($LASTEXITCODE -eq 0 -and -not (Test-Path $journal) -and -not (Test-V4Port -Port $port) -and -not (Get-V4SystemProxy).enabled)
    Check 'preparation-only handling preserved the configuration file bytes' ((Get-FileHash -LiteralPath $profile).Hash -eq $originalHash)
    $snapshot = New-V4Snapshot -Port $port
    Check 'completed snapshot is verified while preparation is still pending' ((Test-Path -LiteralPath (Join-Path $snapshot 'manifest.json')) -and (Get-V4Journal).preparation)
    Write-V4Journal -SnapshotDir $snapshot -Reason 'apply-strict'
    $now = Get-V4Journal
    Check 'snapshot journal promotion preserves the existing rollback format' (-not $now.preparation -and -not $now.corrupt -and $now.data.snapshot -eq $snapshot)
}
finally {
    $p = Get-V69FixtureWorker
    if ($p) { $p.Kill(); $p.WaitForExit() }
    Assert-V4SnapshotPath $root
    if ((Test-V4DirectoryInside $root $temp) -and (Split-Path -Leaf $root) -match '^v69-prep-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}
