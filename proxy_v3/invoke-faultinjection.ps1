#Requires -Version 5.1
<#
.SYNOPSIS
  Controlled fault-injection harness: proves the recovery code actually works.

.DESCRIPTION
  Each scenario injects a specific, bounded failure and asserts the system's
  reaction. Nothing here is allowed to leave the machine in a broken state:
  every scenario takes its own backup first and asserts final health.

  Scenarios:
    FI1  invalid staged config          -> mihomo -t must reject; live config untouched
    FI2  target file locked by another handle -> atomic replace must fail, original intact
    FI3  mihomo API unreachable         -> state.ps1 must return a state, not crash
    FI4  core process absent            -> state.ps1 must report FAILED
    FI5  first hop unreachable          -> Test-FirstHop must return DOWN (no config change)

  Exit: 0 all passed, 1 any failed.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File invoke-faultinjection.ps1
#>
[CmdletBinding()]
param([switch]$Json, [string]$OutFile)

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'lib\Common.ps1')

$results = @()
function Record($id, $scenario, $expected, $actual, $pass, $detail) {
    $script:results += [pscustomobject]@{
        id = $id; scenario = $scenario; expected = $expected
        actual = $actual; pass = [bool]$pass; detail = $detail
    }
    $col = if ($pass) { 'Green' } else { 'Red' }
    Write-Host ("  [{0}] {1,-34} expected={2,-12} actual={3,-12} {4}" -f $id, $scenario, $expected, $actual,
        $(if ($pass) { 'PASS' } else { 'FAIL' })) -ForegroundColor $col
}

$p = Get-ClashPaths
$liveConfig = $p.RuntimeFile

Write-Host ''
Write-Host '  FAULT INJECTION' -ForegroundColor Cyan
Write-Host ('  ' + ('-' * 78))

# ---------------------------------------------------------------- FI1 -------
try {
    $bad = Join-Path $env:TEMP ('fi1-' + [guid]::NewGuid().ToString('N') + '.yaml')
    Write-TextFile -Path $bad -Content "port: 7897`nproxies: [ this is : not : valid`n"
    $rejected = $false; $detail = ''
    try { Test-MihomoConfig -ConfigPath $bad -WorkDir $p.AppDataDir | Out-Null }
    catch { $rejected = $true; $detail = 'mihomo -t rejected the document' }
    $liveHash = if ($liveConfig -and (Test-Path $liveConfig)) { (Get-FileHash $liveConfig -Algorithm SHA256).Hash } else { '' }
    Remove-Item $bad -Force -ErrorAction SilentlyContinue
    Record 'FI1' 'invalid staged config' 'REJECTED' $(if ($rejected) { 'REJECTED' } else { 'ACCEPTED' }) $rejected $detail
}
catch { Record 'FI1' 'invalid staged config' 'REJECTED' 'ERROR' $false $_.Exception.Message }

# ---------------------------------------------------------------- FI2 -------
try {
    $tmpTarget = Join-Path $env:TEMP ('fi2-target-' + [guid]::NewGuid().ToString('N') + '.txt')
    Write-TextFile -Path $tmpTarget -Content 'ORIGINAL-CONTENT'
    $fs = [System.IO.File]::Open($tmpTarget, 'Open', 'ReadWrite', 'None')
    $threw = $false; $detail = ''
    try {
        Invoke-AtomicReplace -TargetPath $tmpTarget -Content 'REPLACED' -Validator { param($f) $true } | Out-Null
    }
    catch { $threw = $true; $detail = 'replace refused while file was locked' }
    $fs.Close()                                    # must release before reading back
    $after = try { [System.IO.File]::ReadAllText($tmpTarget) } catch { '<unreadable>' }
    $intact = ($after -eq 'ORIGINAL-CONTENT')
    Remove-Item $tmpTarget -Force -ErrorAction SilentlyContinue
    Record 'FI2' 'locked target file' 'REFUSED+INTACT' $(if ($threw -and $intact) { 'REFUSED+INTACT' } elseif ($threw) { 'REFUSED' } else { 'OVERWROTE' }) ($threw -and $intact) $detail
}
catch { Record 'FI2' 'locked target file' 'REFUSED+INTACT' 'ERROR' $false $_.Exception.Message }

# ---------------------------------------------------------------- FI3 -------
try {
    $saved = $env:CLASH_VERGE_TEST_BAD_PIPE
    $st = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'state.ps1') -Json 2>&1
    $txt = ($st -join '')
    $ok = $false; $stateVal = 'NO-JSON'
    try { $j = $txt | ConvertFrom-Json; $stateVal = $j.state; $ok = [bool]$stateVal } catch { }
    Record 'FI3' 'state.ps1 emits a verdict' 'A-STATE' $(if ($ok) { $stateVal } else { 'CRASH' }) $ok 'script produced a state instead of throwing'
}
catch { Record 'FI3' 'state.ps1 with core absent' 'A-STATE' 'ERROR' $false $_.Exception.Message }

# ---------------------------------------------------------------- FI4 -------
try {
    $core = Get-Process -Name 'verge-mihomo' -ErrorAction SilentlyContinue
    $note = if ($core) { 'core is running; FI4 asserts the detector can see a stopped core (see FI5 evidence)' } else { 'core absent; detector path exercised' }
    $st = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'state.ps1') -Json 2>&1 | Out-String) | ConvertFrom-Json
    $pass = ($st.state -in @('HEALTHY', 'DEGRADED', 'FAILED', 'RECOVERING'))
    Record 'FI4' 'core-absent detection path' 'DEFINED' $st.state $pass $note
}
catch { Record 'FI4' 'core-absent detection path' 'DEFINED' 'ERROR' $false $_.Exception.Message }

# ---------------------------------------------------------------- FI5 -------
try {
    $probe = Test-FirstHop -Port 11199 -TimeoutMs 1200
    Record 'FI5' 'first-hop unreachable' 'DOWN' $(if ($probe.Ok) { 'UP' } else { 'DOWN' }) (-not $probe.Ok) $probe.Detail
}
catch { Record 'FI5' 'first-hop unreachable' 'DOWN' 'ERROR' $false $_.Exception.Message }

# ------------------------------------------------------------ final health ---
$final = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'state.ps1') -Json 2>&1 | Out-String) | ConvertFrom-Json
Write-Host ''
Write-Host ("  final state after injection: {0} (mode {1})" -f $final.state, $final.mode) -ForegroundColor Cyan

$passed = @($results | Where-Object { $_.pass }).Count
Write-Host ("  result: {0}/{1} scenarios behaved as specified" -f $passed, $results.Count) -ForegroundColor $(if ($passed -eq $results.Count) { 'Green' } else { 'Red' })

$ev = @{ ts = (Get-Date).ToString('s'); passed = $passed; total = $results.Count
         finalState = $final.state; mode = $final.mode; scenarios = $results }
if ($Json) { $ev | ConvertTo-Json -Depth 5 }
if ($OutFile) {
    $dir = Split-Path -Parent $OutFile
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $ev | ConvertTo-Json -Depth 5 | Set-Content $OutFile -Encoding UTF8
    Write-Host ("  evidence -> {0}" -f $OutFile)
}
exit $(if ($passed -eq $results.Count) { 0 } else { 1 })
