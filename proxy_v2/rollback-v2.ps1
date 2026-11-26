#Requires -Version 5.1
<#
.SYNOPSIS
  Transactional rollback of every change made by apply-v2.ps1.

.DESCRIPTION
  Restores the snapshot (profile + runtime + app configs), restarts Clash Verge,
  and puts the system proxy back to the value recorded in the snapshot manifest.
  Use -List to see available snapshots.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File rollback-v2.ps1 -List
  powershell -ExecutionPolicy Bypass -File rollback-v2.ps1
  powershell -ExecutionPolicy Bypass -File rollback-v2.ps1 -SnapshotDir "C:\CAB-Lab\proxy_v2\backup\20261118-021500"
#>
[CmdletBinding()]
param(
    [string]$SnapshotDir,
    [switch]$List,
    [switch]$KeepSystemProxy
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'lib\Common.ps1')
Start-LogFile (Join-Path $here ('test-results\rollback-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss')))

$exitCode = 0
try {
    $backupRoot = Join-Path $here 'backup'
    $all = @()
    if (Test-Path $backupRoot) {
        $all = Get-ChildItem $backupRoot -Directory |
            Where-Object { Test-Path (Join-Path $_.FullName 'manifest.json') } |
            Sort-Object LastWriteTime -Descending
    }

    if ($List) {
        if (-not $all) { Write-Log 'no snapshots found' -Level WARN; exit 0 }
        $all | ForEach-Object {
            $m = Get-Content (Join-Path $_.FullName 'manifest.json') -Raw | ConvertFrom-Json
            '{0}  created={1}  files={2}  sysproxy={3}' -f `
                $_.Name, $m.createdAt, @($m.files).Count, ($(if ($m.systemProxy.Enabled) { $m.systemProxy.Server } else { 'off' }))
        }
        exit 0
    }

    if (-not $SnapshotDir) {
        if (-not $all) { throw 'no snapshot found under backup\' }
        $SnapshotDir = $all[0].FullName
    }
    if (-not (Test-Path (Join-Path $SnapshotDir 'manifest.json'))) { throw "not a snapshot dir: $SnapshotDir" }

    $manifest = Get-Content (Join-Path $SnapshotDir 'manifest.json') -Raw | ConvertFrom-Json
    Write-Log ("rolling back to {0} (created {1})" -f (Split-Path $SnapshotDir -Leaf), $manifest.createdAt) -Level STEP

    $p = Get-ClashPaths
    if (-not $p.AppDataDir) { throw 'Clash Verge config dir not found' }

    # stop the core so nothing rewrites files mid-restore
    Get-Process -Name 'verge-mihomo', 'clash-verge' -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    Restore-StateSnapshot -SnapshotDir $SnapshotDir | Out-Null
    foreach ($f in $manifest.files) { Write-Log ("restored {0}" -f $f.name) -Level OK }

    # system proxy
    if (-not $KeepSystemProxy) {
        if ($manifest.systemProxy.Enabled) {
            Set-SystemProxy -Server $manifest.systemProxy.Server
            Write-Log ("system proxy restored -> {0}" -f $manifest.systemProxy.Server) -Level OK
        }
        else {
            Clear-SystemProxy
            Write-Log 'system proxy restored -> disabled' -Level OK
        }
    }

    # integrity check against the manifest hashes
    $bad = 0
    foreach ($f in $manifest.files) {
        $live = if ($f.name -like 'profiles\*') { Join-Path $p.ProfilesDir (Split-Path $f.name -Leaf) } else { Join-Path $p.AppDataDir $f.name }
        if (Test-Path $live) {
            $h = (Get-FileHash $live -Algorithm SHA256).Hash
            if ($h -ne $f.sha256) { Write-Log ("HASH MISMATCH after restore: {0}" -f $f.name) -Level WARN; $bad++ }
        }
    }
    if ($bad -eq 0) { Write-Log 'hash verification passed for all restored files' -Level OK }

    if ($p.Exe) {
        $wasRunning = $true
        if ($manifest.PSObject.Properties.Name -contains 'clashRunning') { $wasRunning = [bool]$manifest.clashRunning }
        if ($wasRunning) {
            if (Restart-ClashVerge -TimeoutSec 40) { Write-Log 'Clash Verge restarted' -Level OK }
            else { Write-Log 'Clash Verge did not come back on 7897' -Level WARN }
            # H4: the app re-takes HKCU on start. A single re-assert was proven to lose
            # the race (see test-results\rollback-*.log), and the script still exited 0.
            # Poll, re-assert, then COMPARE the final value and fail loudly if it drifted.
            if (-not $KeepSystemProxy) {
                $want = if ($manifest.systemProxy.Enabled) { $manifest.systemProxy.Server } else { 'off' }
                $deadline = (Get-Date).AddSeconds(20)
                while ((Get-Date) -lt $deadline) {
                    $now = Get-SystemProxy
                    $have = if ($now.Enabled) { $now.Server } else { 'off' }
                    if ($have -eq $want) { break }
                    Write-Log ("system proxy drift ({0} != {1}); re-asserting" -f $have, $want) -Level WARN
                    if ($manifest.systemProxy.Enabled) { Set-SystemProxy -Server $manifest.systemProxy.Server } else { Clear-SystemProxy }
                    Start-Sleep -Seconds 2
                }
                $now = Get-SystemProxy
                $have = if ($now.Enabled) { $now.Server } else { 'off' }
                if ($have -ne $want) {
                    Write-Log ("could not hold the snapshot system proxy: want {0}, have {1}" -f $want, $have) -Level ERROR
                    $exitCode = 41
                }
                else { Write-Log ("system proxy held at {0}" -f $have) -Level OK }
            }
        }
        else {
            Write-Log 'Clash Verge was not running when the snapshot was taken; left stopped (prevents system-proxy takeover)' -Level OK
        }
    }

    $px = Get-SystemProxy
    Write-Log ("final: systemProxy={0} server={1}" -f $px.Enabled, $px.Server) -Level OK
    if ($exitCode -ne 41) { $exitCode = 0 }
}
catch {
    Write-Log ("rollback failed: " + (Get-Redacted $_.Exception.Message)) -Level ERROR
    $exitCode = 40
}
finally { exit $exitCode }
