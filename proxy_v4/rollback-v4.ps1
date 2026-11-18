#Requires -Version 5.1
<#
.SYNOPSIS  Transactional rollback for proxy_v4.
.EXAMPLE   .\rollback-v4.ps1 -List
           .\rollback-v4.ps1
           .\rollback-v4.ps1 -SnapshotDir D:\claude防封\proxy_v4\backup\<stamp>
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

try {
    try {
        $settings = Get-V4Settings
        $mixedPort = [int]$settings.mixedPort
    }
    catch { }

    $all = @()
    if (Test-Path $script:BackupDir) {
        $all = Get-ChildItem $script:BackupDir -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'manifest.json') } | Sort-Object LastWriteTime -Descending
    }
    if ($List) {
        if (-not $all) { Write-V4Log 'no snapshots' -Level WARN; return }
        $all | ForEach-Object {
            $m = Get-Content (Join-Path $_.FullName 'manifest.json') -Raw | ConvertFrom-Json
            '{0}  created={1}  reason={2}  files={3}' -f $_.Name, $m.createdAt, $m.reason, @($m.files).Count
        }
        return
    }
    if (-not $SnapshotDir) {
        if (-not $all) { throw 'no snapshot available' }
        $SnapshotDir = $all[0].FullName
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
        Write-V4Log ("rollback -> {0}" -f (Split-Path $SnapshotDir -Leaf)) -Level STEP
        $restoreAttempted = $false
        try {
            # Verify the manifest before considering the app "possibly stopped".
            Test-V4SnapshotManifest -SnapshotDir $SnapshotDir | Out-Null
            $restoreAttempted = $true
            $m = Restore-V4Snapshot -SnapshotDir $SnapshotDir -Port $mixedPort
            Write-V4Log 'files restored and hash-verified' -Level OK
            if (-not (Clear-V4Journal)) { Write-V4Log 'files restored but config\transaction.json could not be cleared' -Level WARN }

            if (-not $KeepSystemProxy -and $m.systemProxy) {
                $want = if ($m.systemProxy.enabled) { $m.systemProxy.server } else { 'off' }
                if ($m.systemProxy.enabled) { Set-V4SystemProxy -Server $m.systemProxy.server } else { Clear-V4SystemProxy }
                $px = Get-V4SystemProxy
                $have = if ($px.enabled) { $px.server } else { 'off' }
                if ($have -ne $want) { Write-V4Log ("system proxy want {0} have {1}" -f $want, $have) -Level ERROR; $exit = 41 }
                else { Write-V4Log ("system proxy = {0}" -f $have) -Level OK }
            }
            if (Start-V4Clash -TimeoutSec 40 -Port $mixedPort) { Write-V4Log 'clash restarted' -Level OK }
            else { Write-V4Log 'clash did not come back' -Level WARN }
            # A restarted Clash Verge may reassert its saved system-proxy=on state.
            # Rollback to an "off" snapshot must win, and if it cannot, fail closed.
            if (-not $KeepSystemProxy -and $m.systemProxy -and -not $m.systemProxy.enabled) {
                Clear-V4SystemProxy
                $px = Get-V4SystemProxy
                if ($px.enabled) { Write-V4Log ('proxy reasserted after restart: ' + $px.server) -Level ERROR; $exit = 41 }
                else { Write-V4Log 'system proxy held off after restart' -Level OK }
            }
            if (-not $KeepSystemProxy -and $m.systemProxy -and $m.systemProxy.enabled) {
                $px = Get-V4SystemProxy
                if ($px.server -ne $m.systemProxy.server) {
                    Write-V4Log ("proxy taken by the app after start ({0}); snapshot wanted {1}" -f $px.server, $m.systemProxy.server) -Level ERROR
                    $exit = 41
                }
            }
            Set-V4Owner -Owner 'rollback' -SystemProxy ((Get-V4SystemProxy).server) -Note ('snapshot=' + (Split-Path $SnapshotDir -Leaf))
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
