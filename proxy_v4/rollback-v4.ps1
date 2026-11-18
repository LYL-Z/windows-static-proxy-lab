#Requires -Version 5.1
<#
.SYNOPSIS  Transactional rollback for proxy_v4.
.EXAMPLE   .\rollback-v4.ps1 -List
           .\rollback-v4.ps1
           .\rollback-v4.ps1 -SnapshotDir D:\claude防封\proxy_v4\backup\<stamp>
  Exit: 0 ok, 40 failed, 41 system proxy could not be held.
#>
[CmdletBinding()]
param([string]$SnapshotDir, [switch]$List, [switch]$KeepSystemProxy)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\V4.ps1')
Start-V4Log 'rollback'
$exit = 0

try {
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
    if (-not (Enter-V4Lock)) { throw 'another operation holds the lock' }
    try {
        Write-V4Log ("rollback -> {0}" -f (Split-Path $SnapshotDir -Leaf)) -Level STEP
        $m = Restore-V4Snapshot -SnapshotDir $SnapshotDir
        Write-V4Log 'files restored and hash-verified' -Level OK

        if (-not $KeepSystemProxy) {
            $want = if ($m.systemProxy.enabled) { $m.systemProxy.server } else { 'off' }
            if ($m.systemProxy.enabled) { Set-V4SystemProxy -Server $m.systemProxy.server } else { Clear-V4SystemProxy }
            $px = Get-V4SystemProxy
            $have = if ($px.enabled) { $px.server } else { 'off' }
            if ($have -ne $want) { Write-V4Log ("system proxy want {0} have {1}" -f $want, $have) -Level ERROR; $exit = 41 }
            else { Write-V4Log ("system proxy = {0}" -f $have) -Level OK }
        }
        if (Start-V4Clash -TimeoutSec 40) { Write-V4Log 'clash restarted' -Level OK }
        else { Write-V4Log 'clash did not come back' -Level WARN }
        # the app may re-take the proxy on start: verify once more and report honestly
        if (-not $KeepSystemProxy -and $m.systemProxy.enabled) {
            $px = Get-V4SystemProxy
            if ($px.server -ne $m.systemProxy.server) {
                Write-V4Log ("proxy taken by the app after start ({0}); snapshot wanted {1}" -f $px.server, $m.systemProxy.server) -Level ERROR
                $exit = 41
            }
        }
        Set-V4Owner -Owner 'rollback' -SystemProxy ((Get-V4SystemProxy).server) -Note ('snapshot=' + (Split-Path $SnapshotDir -Leaf))
    }
    finally { Exit-V4Lock }
}
catch {
    Write-V4Log ('rollback failed: ' + (Get-V4Redacted $_.Exception.Message)) -Level ERROR
    $exit = 40
}
finally { exit $exit }
