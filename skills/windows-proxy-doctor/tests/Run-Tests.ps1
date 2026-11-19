#Requires -Version 5.1
<#
Isolated tests. Uses a temporary root and synthetic fixtures only.
No real HKCU, WinHTTP, network, proxy client, or credentials are touched.
Exit: 0 pass, 1 failure, 2 zero tests.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$testDir = Split-Path -Parent $PSCommandPath
$root = Split-Path -Parent $testDir
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('wpdoctor-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$failures = New-Object System.Collections.Generic.List[string]
$count = 0
function Assert-True($cond, [string]$msg) { if (-not $cond) { throw $msg } }
function Check([string]$name, [scriptblock]$body) {
    $script:count++
    try { & $body; Write-Host ('PASS ' + $name) }
    catch { $script:failures.Add($name + ': ' + $_.Exception.Message); Write-Host ('FAIL ' + $name + ': ' + $_.Exception.Message) }
}
try {
    Check 'snapshot-healthy' {
        $j = & (Join-Path $root 'scripts\Get-ProxyDoctorSnapshot.ps1') -TestFixture (Join-Path $testDir 'fixtures\state-healthy.json') -Json | ConvertFrom-Json
        Assert-True ($j.state -eq 'HEALTHY') ('state=' + $j.state)
        Assert-True ($j.source -eq 'test-fixture') 'source not fixture'
    }
    Check 'snapshot-mismatch' {
        $j = & (Join-Path $root 'scripts\Get-ProxyDoctorSnapshot.ps1') -TestFixture (Join-Path $testDir 'fixtures\state-mismatch.json') -Json | ConvertFrom-Json
        Assert-True ($j.state -eq 'DEGRADED') ('state=' + $j.state)
        Assert-True (($j.reasons -join ' ') -match 'UI enable_system_proxy') 'UI mismatch reason missing'
    }
    Check 'snapshot-proxy-off' {
        $j = & (Join-Path $root 'scripts\Get-ProxyDoctorSnapshot.ps1') -TestFixture (Join-Path $testDir 'fixtures\state-proxy-off.json') -Json | ConvertFrom-Json
        Assert-True ($j.state -eq 'DEGRADED') ('state=' + $j.state)
    }
    Check 'wrong-target-with-both-toggles-on' {
        $f = Get-Content (Join-Path $testDir 'fixtures\state-healthy.json') -Raw | ConvertFrom-Json
        $f.proxyServer = '127.0.0.1:11119'
        $path = Join-Path $tmp 'wrong-target.json'
        $f | ConvertTo-Json | Set-Content -LiteralPath $path
        $j = & (Join-Path $root 'scripts\Get-ProxyDoctorSnapshot.ps1') -TestFixture $path -Json | ConvertFrom-Json
        Assert-True ($j.state -eq 'DEGRADED' -and $j.proxyTargetsMixedPort -eq $false) 'wrong target accepted'
        $j | ConvertTo-Json | Set-Content -LiteralPath $path
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\Test-ProxyConsistency.ps1') -SnapshotFile $path -Json
        Assert-True ($LASTEXITCODE -eq 2) ('exit=' + $LASTEXITCODE)
        Assert-True (($out -join ' ') -match 'points away') 'consistency missed target mismatch'
    }
    Check 'mapped-target-unverified-exit' {
        $f = Get-Content (Join-Path $testDir 'fixtures\state-healthy.json') -Raw | ConvertFrom-Json
        $f.proxyServer = 'http=127.0.0.1:7897; https=localhost:7897'
        $f.exitMatches = $null
        $path = Join-Path $tmp 'mapped-target.json'
        $f | ConvertTo-Json | Set-Content -LiteralPath $path
        $j = & (Join-Path $root 'scripts\Get-ProxyDoctorSnapshot.ps1') -TestFixture $path -Json | ConvertFrom-Json
        Assert-True ($j.proxyTargetsMixedPort -eq $true) 'mapped HTTP(S) target was not recognized'
        Assert-True ($j.state -eq 'UNKNOWN') 'unmeasured exit was promoted to healthy'
        Assert-True ($j.proxyServer -eq '[redacted]') 'raw mapping was emitted'
    }
    Check 'consistency-mismatch-exit2' {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\Test-ProxyConsistency.ps1') -SnapshotFile (Join-Path $testDir 'fixtures\state-mismatch.json') -Json 2>&1
        Assert-True ($LASTEXITCODE -eq 2) ('exit=' + $LASTEXITCODE)
        Assert-True (($out -join ' ') -match 'UI and HKCU') 'consistency issue missing'
    }
    Check 'https-layer-classification' {
        . (Join-Path $root 'scripts\NetworkPathResult.ps1')
        Assert-True ((ConvertFrom-ProxyDoctorCurlResult '200 200' 0).status -eq 'ok') 'valid HTTPS response failed'
        Assert-True ((ConvertFrom-ProxyDoctorCurlResult '502 200' 0).status -eq 'http_error') 'HTTP 502 counted as success'
        Assert-True ((ConvertFrom-ProxyDoctorCurlResult '000 502' 56).status -eq 'proxy_connect_error') 'CONNECT 502 conflated with origin 502'
        Assert-True ((ConvertFrom-ProxyDoctorCurlResult '000 200' 60).status -eq 'transport_error') 'TLS failure counted as success'
    }
    Check 'backup-roundtrip' {
        $src = Join-Path $tmp 'backup'; New-Item -ItemType Directory -Path (Join-Path $src 'snap') -Force | Out-Null
        Set-Content (Join-Path $src 'snap\manifest.json') '{"schema":2,"files":[]}' -Encoding UTF8
        $enc = Join-Path $tmp 'backup.zip.dpapi'; $zip = Join-Path $tmp 'out.zip'
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\Protect-Backup.ps1') -Path $src -OutFile $enc -Apply | Out-Null
        Assert-True ($LASTEXITCODE -eq 0) 'protect failed'
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\Unprotect-Backup.ps1') -InFile $enc -OutFile $zip | Out-Null
        Assert-True ($LASTEXITCODE -eq 0) 'unprotect failed'
        $m = Get-Content ($enc + '.json') -Raw | ConvertFrom-Json
        Assert-True ((Get-FileHash $zip -Algorithm SHA256).Hash -eq [string]$m.zipSha256) 'zip hash mismatch'
    }
}
finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ('COUNTS=' + $count + ' failures=' + $failures.Count)
if ($failures.Count) { $failures | ForEach-Object { Write-Host ('  - ' + $_) }; exit 1 }
if ($count -eq 0) { exit 2 }
exit 0
