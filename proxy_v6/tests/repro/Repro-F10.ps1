param([string]$Only = '*', [string]$OutFile = '')
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = (Resolve-Path (Join-Path $here '..\..\..')).Path
$bench = Join-Path $env:TEMP ('v4f10-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $bench 'lib') -Force | Out-Null
Copy-Item (Join-Path $repo 'proxy_v4\lib\V4.ps1') (Join-Path $bench 'lib\V4.ps1') -Force
. (Join-Path $bench 'lib\V4.ps1')

$script:Results = New-Object System.Collections.ArrayList
function Check([string]$id, [string]$name, [scriptblock]$body) {
    if ($id -notlike $Only) { return }
    try {
        $detail = & $body
        [void]$script:Results.Add([pscustomobject]@{ id=$id; name=$name; pass=$true; detail=$detail })
        Write-Host ("  [PASS] {0} {1}" -f $id, $name) -ForegroundColor Green
    } catch {
        [void]$script:Results.Add([pscustomobject]@{ id=$id; name=$name; pass=$false; detail=$_.Exception.Message })
        Write-Host ("  [FAIL] {0} {1}: {2}" -f $id, $name, $_.Exception.Message) -ForegroundColor Red
    }
}
function AssertTrue($cond, $msg) { if (-not $cond) { throw $msg } }

Check 'F10-01' 'restore fails and logging fails: return 40, no throw' {
    $called = @{ restore=0; start=0; stop=0; proxy=0 }
    $log = { param($m,$l) throw 'log target blocked' }
    $stop = { $called.stop++; 'stopped' }
    $restore = { param($s) $called.restore++; throw 'restore broke' }
    $proxy = { $called.proxy++; 'proxy' }
    $start = { $called.start++; 'started' }
    $code = Invoke-V4Recovery -SnapshotDir 'X' -Code 31 -AppWasRunning $true -StopApp $stop -Restore $restore -RestoreProxy $proxy -StartApp $start -Log $log
    AssertTrue ($code -eq 40) ('code=' + $code)
    AssertTrue ($called.restore -eq 1 -and $called.proxy -eq 1 -and $called.start -eq 1) 'recovery steps were skipped'
    'returned 40 after all steps'
}

Check 'F10-02' 'restore ok, start fails, logging fails: return 40, no throw' {
    $log = { param($m,$l) throw 'log target blocked' }
    $stop = { 'stopped' }
    $restore = { param($s) 'restored' }
    $proxy = { 'proxy' }
    $start = { throw 'start broke' }
    $code = Invoke-V4Recovery -SnapshotDir 'X' -Code 30 -AppWasRunning $true -StopApp $stop -Restore $restore -RestoreProxy $proxy -StartApp $start -Log $log
    AssertTrue ($code -eq 40) ('code=' + $code)
    'returned 40'
}

Check 'F10-03' 'restore+start ok, logging fails: original code kept' {
    $log = { param($m,$l) throw 'log target blocked' }
    $stop = { 'stopped' }
    $restore = { param($s) 'restored' }
    $proxy = { 'proxy' }
    $start = { 'started' }
    $code = Invoke-V4Recovery -SnapshotDir 'X' -Code 31 -AppWasRunning $true -StopApp $stop -Restore $restore -RestoreProxy $proxy -StartApp $start -Log $log
    AssertTrue ($code -eq 31) ('code=' + $code)
    'returned 31'
}

Check 'F10-04' 'restore fails, logging works: return 40' {
    $log = { param($m,$l) }
    $stop = { 'stopped' }
    $restore = { param($s) throw 'restore broke' }
    $proxy = { 'proxy' }
    $start = { 'started' }
    $code = Invoke-V4Recovery -SnapshotDir 'X' -Code 31 -AppWasRunning $true -StopApp $stop -Restore $restore -RestoreProxy $proxy -StartApp $start -Log $log
    AssertTrue ($code -eq 40) ('code=' + $code)
    'returned 40'
}

Check 'F10-05' 'restore fails: process reconciliation still attempted' {
    $called = @{ start=0 }
    $log = { param($m,$l) }
    $stop = { 'stopped' }
    $restore = { param($s) throw 'restore broke' }
    $proxy = { 'proxy' }
    $start = { $called.start++; 'started' }
    $code = Invoke-V4Recovery -SnapshotDir 'X' -Code 31 -AppWasRunning $true -StopApp $stop -Restore $restore -RestoreProxy $proxy -StartApp $start -Log $log | Out-Null
    AssertTrue ($called.start -ge 1) 'process reconciliation was skipped after restore failure'
    'start attempted after restore failure'
}

Check 'F10-06' 'all succeed: original code preserved' {
    $log = { param($m,$l) }
    $stop = { 'stopped' }
    $restore = { param($s) 'restored' }
    $proxy = { 'proxy' }
    $start = { 'started' }
    $code = Invoke-V4Recovery -SnapshotDir 'X' -Code 32 -AppWasRunning $true -StopApp $stop -Restore $restore -RestoreProxy $proxy -StartApp $start -Log $log
    AssertTrue ($code -eq 32) ('code=' + $code)
    'returned 32'
}

Check 'F10-07' 'app was not running: recovery must stop, not start' {
    $called = @{ start=0; stop=0 }
    $log = { param($m,$l) }
    $stop = { $called.stop++; 'stopped' }
    $restore = { param($s) 'restored' }
    $proxy = { 'proxy' }
    $start = { $called.start++; 'started' }
    $code = Invoke-V4Recovery -SnapshotDir 'X' -Code 31 -AppWasRunning $false -StopApp $stop -Restore $restore -RestoreProxy $proxy -StartApp $start -Log $log
    AssertTrue ($code -eq 31) ('code=' + $code)
    AssertTrue ($called.start -eq 0) 'started an app that was not running before'
    AssertTrue ($called.stop -ge 2) 'did not stop the app before and after restore'
    'stopped only'
}

Check 'F10-08' 'proxy restore fails: return 40 even if files restore' {
    $log = { param($m,$l) }
    $stop = { 'stopped' }
    $restore = { param($s) 'restored' }
    $proxy = { throw 'proxy restore broke' }
    $start = { 'started' }
    $code = Invoke-V4Recovery -SnapshotDir 'X' -Code 31 -AppWasRunning $true -StopApp $stop -Restore $restore -RestoreProxy $proxy -StartApp $start -Log $log
    AssertTrue ($code -eq 40) ('code=' + $code)
    'returned 40'
}

Check 'F10-09' 'unknown process state with a snapshot: cannot claim success' {
    $log = { param($m,$l) }
    $stop = { 'stopped' }
    $restore = { param($s) 'restored' }
    $proxy = { 'proxy' }
    $start = { 'started' }
    $code = Invoke-V4Recovery -SnapshotDir 'X' -Code 31 -AppWasRunning $null -StopApp $stop -Restore $restore -RestoreProxy $proxy -StartApp $start -Log $log
    AssertTrue ($code -eq 40) ('code=' + $code)
    'returned 40'
}

Check 'F10-10' 'owner restore fails: return 40' {
    $log = { param($m,$l) }
    $stop = { 'stopped' }
    $restore = { param($s) 'restored' }
    $proxy = { 'proxy' }
    $owner = { throw 'owner restore broke' }
    $start = { 'started' }
    $code = Invoke-V4Recovery -SnapshotDir 'X' -Code 31 -AppWasRunning $true -StopApp $stop -Restore $restore -RestoreProxy $proxy -RestoreOwner $owner -StartApp $start -Log $log
    AssertTrue ($code -eq 40) ('code=' + $code)
    'returned 40'
}

$passed = @($script:Results | Where-Object { $_.pass }).Count
if ($OutFile) {
    $payload = [ordered]@{ ts = (Get-Date).ToString('s'); only = $Only; passed = $passed; total = $script:Results.Count; cases = @($script:Results) }
    [System.IO.File]::WriteAllText($OutFile, ($payload | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
}
Write-Host ''
Write-Host ("RESULT {0}/{1}" -f $passed, $script:Results.Count)
Remove-Item $bench -Recurse -Force -ErrorAction SilentlyContinue
if ($script:Results.Count -gt 0 -and $passed -eq $script:Results.Count) { exit 0 } else { exit 1 }
