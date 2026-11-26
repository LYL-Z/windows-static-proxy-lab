param([string]$Only = '*', [string]$OutFile = '')
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = (Resolve-Path (Join-Path $here '..\..\..')).Path
$bench = Join-Path $env:TEMP ('v4f09-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $bench -Force | Out-Null
$env:V4_TEST_MODE = '1'
$env:V4_TEST_ROOT = $bench
. (Join-Path $repo 'proxy_v4\lib\V4.ps1')

$results = New-Object System.Collections.ArrayList
function Check([string]$id, [string]$name, [scriptblock]$body) {
    if ($id -notlike $Only) { return }
    try {
        $detail = & $body
        [void]$results.Add([pscustomobject]@{ id=$id; name=$name; pass=$true; detail=$detail })
        Write-Host ("  [PASS] {0} {1}" -f $id, $name) -ForegroundColor Green
    } catch {
        [void]$results.Add([pscustomobject]@{ id=$id; name=$name; pass=$false; detail=$_.Exception.Message })
        Write-Host ("  [FAIL] {0} {1}: {2}" -f $id, $name, $_.Exception.Message) -ForegroundColor Red
    }
}
function AssertTrue($cond, $msg) { if (-not $cond) { throw $msg } }

$lock = Enter-V4Lock -TimeoutSec 3
if (-not $lock) { throw 'could not acquire test lock' }
$settings = Join-Path $bench 'config\settings.json'
$lockFile = Join-Path $bench 'config\.lock'
$apply = Join-Path $repo 'proxy_v4\apply-v4.ps1'
$passFile = Join-Path $bench 'fixture.pass'
[System.IO.File]::WriteAllText($passFile, 'fixture-pass', (New-Object System.Text.UTF8Encoding($false)))
$null = Protect-V4Acl -Path $passFile

Check 'F09-01' 'Init must not write settings while another process holds the lock' {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $apply -Init -StaticHost '203.0.113.10' -StaticPort 1080 -StaticUser 'fixture-user' -CredentialFile $passFile -HopPort 65531 -MixedPort 65532 2>&1
    $code = $LASTEXITCODE
    AssertTrue ($code -eq 33) ('child exit=' + $code + ' out=' + (($out | Select-Object -Last 4) -join ' | '))
    AssertTrue (-not (Test-Path $settings)) 'settings.json was written before the lock was acquired'
    'exit 33 and no settings write'
}

Check 'F09-02' 'a loser must not delete the winner lock on exit' {
    AssertTrue (Test-Path $lockFile) 'winner lock file was deleted by the losing process'
    'winner lock intact'
}

Check 'F09-03' 'Init + DryRun exits 11 before any settings write' {
    if (Test-Path $settings) { Remove-Item $settings -Force }
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $apply -Init -DryRun 2>&1
    $code = $LASTEXITCODE
    AssertTrue ($code -eq 11) ('child exit=' + $code)
    AssertTrue (-not (Test-Path $settings)) 'settings.json was written on an illegal Init+DryRun combination'
    'exit 11 and no settings write'
}

Exit-V4Lock $lock
$left = Test-Path $lockFile
Write-Host ''
Write-Host ("lock-after-release={0}" -f $left)
$passed = @($results | Where-Object { $_.pass }).Count
if ($OutFile) {
    $payload = [ordered]@{ ts = (Get-Date).ToString('s'); only = $Only; passed = $passed; total = $results.Count; cases = @($results) }
    [System.IO.File]::WriteAllText($OutFile, ($payload | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
}
Write-Host ''
Write-Host ("RESULT {0}/{1}" -f $passed, $results.Count)
Remove-Item $bench -Recurse -Force -ErrorAction SilentlyContinue
if ($results.Count -gt 0 -and $passed -eq $results.Count) { exit 0 } else { exit 1 }