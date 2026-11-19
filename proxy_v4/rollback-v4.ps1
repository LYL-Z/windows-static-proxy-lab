#Requires -Version 5.1
<#
.SYNOPSIS  Transactional rollback for proxy_v4.
.EXAMPLE   .\rollback-v4.ps1 -List
           .\rollback-v4.ps1
           .\rollback-v4.ps1 -SnapshotDir .\backup\<stamp>
  Exit: 0 ok, 33 lock busy, 40 failed, 41 system proxy could not be held.
#>
[CmdletBinding()]
param([string]$SnapshotDir, [switch]$List, [switch]$KeepSystemProxy)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\V4.ps1')
$null = Enable-V4ProductionWrites
$null = Start-V4Log 'rollback'
$exit = 0
$lock = $null
$mixedPort = 7897

function Get-RollbackSnapshots {
    if (Test-Path -LiteralPath $script:BackupDir) {
        Get-ChildItem -LiteralPath $script:BackupDir -Directory |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.json') } |
            Sort-Object LastWriteTime -Descending
    }
}

try {
    try {
        $settings = Get-V4Settings
        $mixedPort = [int]$settings.mixedPort
    }
    catch { }

    if ($List) {
        $all = @(Get-RollbackSnapshots)
        if (-not $all) { Write-V4Log 'no snapshots' -Level WARN; return }
        $all | ForEach-Object {
            $m = Get-Content (Join-Path $_.FullName 'manifest.json') -Raw | ConvertFrom-Json
            '{0}  created={1}  reason={2}  files={3}' -f $_.Name, $m.createdAt, $m.reason, @($m.files).Count
        }
        return
    }
    $lock = Enter-V4Lock
    if (-not $lock) {
        Write-V4Log 'another operation holds the lock' -Level ERROR
        $exit = 33
        return
    }

    # R2A-01: lock is held until after any补救 restart. Only a failure that
    # actually entered restore may start the app; a pre-restore failure must not.
    try {
        $restoreAttempted = $false
        try {
            $journal = Get-V4Journal
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
            Test-V4SnapshotManifest -SnapshotDir $SnapshotDir | Out-Null
            Write-V4Log ('restoring verified snapshot ' + (Split-Path $SnapshotDir -Leaf)) -Level STEP
            $keptProxy = if ($KeepSystemProxy) { Get-V4SystemProxy } else { $null }
            if (-not $journal -or $journal.corrupt -or $journal.data.snapshot -ne $SnapshotDir) {
                Write-V4Journal -SnapshotDir $SnapshotDir -Reason 'rollback'
            }
            $restoreAttempted = $true
            $m = Restore-V4Snapshot -SnapshotDir $SnapshotDir -Port $mixedPort
            Write-V4Log 'files restored and hash-verified' -Level OK

            $restoreProxy = -not $KeepSystemProxy -and $null -ne $m.systemProxy
            if ($restoreProxy) {
                if ($m.systemProxy.enabled) { Set-V4SystemProxy -Server $m.systemProxy.server } else { Clear-V4SystemProxy }
            }
            $ready = Start-V4Clash -TimeoutSec 40 -Port $mixedPort
            # A restart can reassert the UI setting. Preserve the snapshot's
            # established "off" behavior and verify the actual final proxy.
            if ($restoreProxy -and -not $m.systemProxy.enabled) { Clear-V4SystemProxy }
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
finally { exit $exit }
