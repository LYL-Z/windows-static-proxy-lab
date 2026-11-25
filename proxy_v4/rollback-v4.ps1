#Requires -Version 5.1
<#
.SYNOPSIS  Transactional rollback for proxy_v4.
.EXAMPLE   .\rollback-v4.ps1 -List
           .\rollback-v4.ps1
           .\rollback-v4.ps1 -SnapshotDir .\backup\<stamp>
  Exit: 0 ok, 32 files restored and a user-disabled proxy was left off,
        33 lock busy, 40 failed, 41 system proxy could not be held.
#>
[CmdletBinding()]
param([string]$SnapshotDir, [switch]$List, [switch]$KeepSystemProxy)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\V4.ps1')
if (-not $List) {
    $null = Enable-V4ProductionWrites
    $null = Start-V4Log 'rollback'
}
$exit = 0
$lock = $null
$userLock = $null
$mixedPort = 7897

function Get-RollbackSnapshots {
    if (Test-Path -LiteralPath $script:BackupDir) {
        Get-ChildItem -LiteralPath $script:BackupDir -Directory |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.json') } |
            Sort-Object LastWriteTime -Descending
    }
}

try {
    if ($List) {
        $all = @(Get-RollbackSnapshots)
        if (-not $all) { Write-V4Log 'no snapshots' -Level WARN; return }
        $all | ForEach-Object {
            $m = Get-Content (Join-Path $_.FullName 'manifest.json') -Raw | ConvertFrom-Json
            '{0}  created={1}  reason={2}  files={3}' -f $_.Name, $m.createdAt, $m.reason, @($m.files).Count
        }
        return
    }
    try { $mixedPort = [int](Get-V4Settings -StatusOnly).mixedPort } catch { }
    $userLock = Enter-V4UserMutationLock
    if ($userLock) { $lock = Enter-V4Lock }
    if (-not $lock) {
        Write-V4Log 'another operation holds the lock' -Level ERROR
        $exit = 33
        return
    }

    # R2A-01: lock is held until after any补救 restart. Only a failure that
    # actually entered restore may start the app; a pre-restore failure must not.
    try {
        if (Get-V4RepairReceipt) {
            Write-V4Log 'interrupted or unreadable repair receipt; review before rollback' -Level ERROR
            $exit = 34
            return
        }
        $restoreAttempted = $false
        try {
            $journal = Get-V4Journal
            $rollbackJournal = $journal -and -not $journal.corrupt -and $journal.data.reason -eq 'rollback'
            if ($rollbackJournal -and -not $PSBoundParameters.ContainsKey('KeepSystemProxy')) {
                $KeepSystemProxy = [bool]$journal.data.keepSystemProxy
            }
            if (-not $SnapshotDir) {
                if ($journal -and $journal.corrupt) { throw 'transaction journal is unreadable; select a verified snapshot explicitly' }
                if ($journal) { $SnapshotDir = [string]$journal.data.snapshot }
                else {
                    $latest = Get-RollbackSnapshots | Select-Object -First 1
                    if (-not $latest) { throw 'no snapshot available' }
                    $SnapshotDir = $latest.FullName
                }
            }
            $SnapshotDir = (Get-Item -LiteralPath $SnapshotDir -ErrorAction Stop).FullName
            # Verify the manifest before considering the app "possibly stopped".
            $manifest = Test-V4SnapshotManifest -SnapshotDir $SnapshotDir
            Write-V4Log ('restoring verified snapshot ' + (Split-Path $SnapshotDir -Leaf)) -Level STEP
            $journalMatches = $rollbackJournal -and [string]$journal.data.snapshot -eq $SnapshotDir -and [bool]$journal.data.keepSystemProxy -eq [bool]$KeepSystemProxy
            if ($KeepSystemProxy -and $journalMatches -and $journal.data.PSObject.Properties.Name -notcontains 'keptEnabled') {
                Write-V4Log 'rollback journal does not record the proxy selection it intended to keep' -Level ERROR
                $exit = 41
                return
            }
            $keptProxy = $null
            if ($KeepSystemProxy) {
                if ($journalMatches) {
                    $keptProxy = [pscustomobject]@{ enabled = [bool]$journal.data.keptEnabled; server = [string]$journal.data.keptServer }
                } else {
                    $keptProxy = Get-V4SystemProxy
                }
            }
            $preserveUserOff = $false
            if ($journalMatches -and $journal.data.PSObject.Properties.Name -contains 'preserveUserOff') {
                $preserveUserOff = [bool]$journal.data.preserveUserOff
            }
            $snapshotProxy = $manifest.manifest.systemProxy
            if (-not $KeepSystemProxy -and -not $preserveUserOff -and $snapshotProxy -and [bool]$snapshotProxy.enabled) {
                $observed = Get-V4SystemProxy
                if (-not $observed.enabled) { $preserveUserOff = $true }
            }
            if (-not $journalMatches) {
                Write-V4Journal -SnapshotDir $SnapshotDir -Reason 'rollback' -KeepSystemProxy:$KeepSystemProxy -PreserveUserOff:$preserveUserOff -KeptProxy $keptProxy
            }
            if ($script:TestMode -and $env:V4_TEST_EXIT_AFTER_JOURNAL -eq '1') {
                Write-V4Log 'test injection stopped after the rollback journal was durable' -Level WARN
                $exit = 41
                return
            }
            $restoreAttempted = $true
            $m = Restore-V4Snapshot -SnapshotDir $SnapshotDir -Port $mixedPort
            Write-V4Log 'files restored and hash-verified' -Level OK

            $restoreProxy = -not $KeepSystemProxy -and -not $preserveUserOff -and $null -ne $m.systemProxy
            if ($restoreProxy) {
                if ($m.systemProxy.enabled) { Set-V4SystemProxy -Server $m.systemProxy.server } else { Clear-V4SystemProxy }
            }
            $ready = Start-V4Clash -TimeoutSec 40 -Port $mixedPort
            # A restart can reassert the UI setting. Preserve the snapshot's
            # established "off" behavior and verify the actual final proxy.
            if ($restoreProxy -and -not $m.systemProxy.enabled) { Clear-V4SystemProxy }
            if ($preserveUserOff) {
                $now = Get-V4SystemProxy
                if ($now.enabled -and [string]$now.server -eq [string]$m.systemProxy.server) { Clear-V4SystemProxy }
                elseif ($now.enabled) {
                    Write-V4Log 'a different proxy was enabled during rollback; left unchanged and journal retained' -Level ERROR
                    $exit = 41
                    return
                }
                $now = Get-V4SystemProxy
                if ($now.enabled -or -not $ready) {
                    Write-V4Log 'user-disabled proxy could not be confirmed after rollback; journal retained' -Level ERROR
                    $exit = $(if ($ready) { 41 } else { 40 })
                    return
                }
                Set-V4Owner -Owner 'rollback' -SystemProxy 'off' -Note ('user-off preserved; snapshot=' + (Split-Path $SnapshotDir -Leaf))
                if (-not (Clear-V4Journal)) {
                    Write-V4Log 'user-off was preserved but the journal remains' -Level ERROR
                    $exit = 40
                    return
                }
                Write-V4Log 'rollback restored files and left the user-disabled proxy off' -Level OK
                $exit = 32
                return
            }
            if (-not $ready) {
                Write-V4Log 'Clash listener did not become ready; rollback journal retained' -Level ERROR
                $exit = 40
                return
            }
            $px = Get-V4SystemProxy
            $expectedProxy = if ($KeepSystemProxy) { $keptProxy } else { $m.systemProxy }
            if ($expectedProxy -and -not (Test-V4SystemProxyMatch -Expected $expectedProxy -Actual $px)) {
                Write-V4Log 'Windows proxy changed after Clash start; rollback journal retained' -Level ERROR
                $exit = 41
                return
            }
            Set-V4Owner -Owner 'rollback' -SystemProxy $px.server -Note ('snapshot=' + (Split-Path $SnapshotDir -Leaf))
            if (-not (Clear-V4Journal)) {
                Write-V4Log 'rollback completed but the transaction journal remains; review before another apply' -Level ERROR
                $exit = 40
                return
            }
            Write-V4Log 'rollback complete; Clash listener ready' -Level OK
        }
        catch {
            Write-V4Log ('rollback failed: ' + (Get-V4Redacted $_.Exception.Message)) -Level ERROR
            if ($restoreAttempted) {
                try {
                    if (Start-V4Clash -TimeoutSec 40 -Port $mixedPort) { Write-V4Log 'clash restarted after failed restore' -Level WARN }
                    else { Write-V4Log 'clash did not come back after failed restore' -Level ERROR }
                }
                catch { Write-V4Log ('clash restart after failed restore also failed: ' + (Get-V4Redacted $_.Exception.Message)) -Level ERROR }
            }
            $exit = 40
        }
    }
    finally { if ($lock) { $null = Exit-V4Lock $lock } }
}
catch {
    Write-V4Log ('rollback refused/failed before restore: ' + (Get-V4Redacted $_.Exception.Message)) -Level ERROR
    $exit = 40
}
finally {
    if ($userLock) { $userLock.ReleaseMutex(); $userLock.Dispose() }
    exit $exit
}
