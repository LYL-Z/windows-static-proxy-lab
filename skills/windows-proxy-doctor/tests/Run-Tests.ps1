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
    Check 'pac-keeps-effective-selection-unknown' {
        $f = Get-Content (Join-Path $testDir 'fixtures\state-healthy.json') -Raw | ConvertFrom-Json
        $f | Add-Member -NotePropertyName pacConfigured -NotePropertyValue $true
        $path = Join-Path $tmp 'pac.json'
        $f | ConvertTo-Json | Set-Content -LiteralPath $path
        $j = & (Join-Path $root 'scripts\Get-ProxyDoctorSnapshot.ps1') -TestFixture $path -IncludeWriterEvidence -Json | ConvertFrom-Json
        Assert-True ($j.state -eq 'UNKNOWN' -and $j.pacConfigured) 'PAC was promoted to verified manual routing'
        Assert-True ($j.writerEvidence.status -eq 'not_queried_in_fixture') 'fixture writer query was attempted'
        $j | ConvertTo-Json | Set-Content -LiteralPath $path
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\Test-ProxyConsistency.ps1') -SnapshotFile $path -Json
        Assert-True ($LASTEXITCODE -eq 3) ('exit=' + $LASTEXITCODE)
        Assert-True ($null -eq ($out | ConvertFrom-Json).consistent) 'PAC consistency was reported as verified'
    }
    Check 'registry-writer-evidence-scope-and-redaction' {
        . (Join-Path $root 'scripts\ProxyRegistryEvents.ps1')
        $sid = 'S-1-5-21-100-200-300-1001'
        $key = "$sid\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
        $security = [xml]@"
<Event xmlns="http://schemas.microsoft.com/win/2004/08/events/event"><System><Provider Name="Microsoft-Windows-Security-Auditing"/><EventID>4657</EventID><TimeCreated SystemTime="2026-01-01T01:00:00Z"/></System><EventData><Data Name="ObjectName">\REGISTRY\USER\$key</Data><Data Name="ObjectValueName">AutoConfigURL</Data><Data Name="ProcessName">X:\Example\Private\writer.exe</Data><Data Name="NewValue">https://configuration.invalid/example</Data></EventData></Event>
"@
        $sysmon = [xml]@"
<Event xmlns="http://schemas.microsoft.com/win/2004/08/events/event"><System><Provider Name="Microsoft-Windows-Sysmon"/><EventID>13</EventID><TimeCreated SystemTime="2026-01-01T01:00:00Z"/></System><EventData><Data Name="TargetObject">HKU\$key\ProxyServer</Data><Data Name="Image">X:\Example\Private\service.exe</Data><Data Name="Details">hidden-proxy.invalid</Data></EventData></Event>
"@
        $written = @(ConvertFrom-ProxyDoctorRegistryEvent $security $sid; ConvertFrom-ProxyDoctorRegistryEvent $sysmon $sid)
        Assert-True ($written.Count -eq 2) 'expected both event formats to match'
        Assert-True ($written[0].field -eq 'AutoConfigURL' -and $written[0].process -eq 'writer.exe') 'wrong Security writer fields'
        Assert-True ($written[1].field -eq 'ProxyServer' -and $written[1].process -eq 'service.exe') 'wrong Sysmon writer fields'
        Assert-True (($written | ConvertTo-Json) -notmatch 'private|\.invalid|S-1-5') 'private event detail leaked'
        Assert-True ($null -eq (ConvertFrom-ProxyDoctorRegistryEvent $sysmon 'S-1-5-21-100-200-300-1002')) 'event matched a different user hive'
        ($sysmon.Event.EventData.Data | Where-Object Name -eq 'TargetObject').InnerText = "HKU\$key\Connections\ProxyServer"
        Assert-True ($null -eq (ConvertFrom-ProxyDoctorRegistryEvent $sysmon $sid)) 'event matched another registry key'
        $events = @(
            @{ timeUtc = '2026-01-01T00:59:59.900Z'; marker = 'before' }
            @{ timeUtc = '2026-01-01T01:00:00.150Z'; marker = 'during previous snapshot' }
            @{ timeUtc = '2026-01-01T01:00:05.100Z'; marker = 'after latest registry read' }
            @{ timeUtc = 'invalid'; marker = 'invalid' }
        )
        $selected = @(Select-ProxyDoctorRegistryEventsInWindow -Events $events -From '2026-01-01T01:00:00Z' -Through '2026-01-01T01:00:05Z')
        Assert-True ($selected.Count -eq 1 -and $selected[0].marker -eq 'during previous snapshot') 'writer window lost an event between the prior registry read and the prior snapshot completion'
    }
    Check 'https-layer-classification' {
        . (Join-Path $root 'scripts\NetworkPathResult.ps1')
        Assert-True ((ConvertFrom-ProxyDoctorCurlResult '200 200' 0).status -eq 'ok') 'valid HTTPS response failed'
        Assert-True ((ConvertFrom-ProxyDoctorCurlResult '502 200' 0).status -eq 'http_error') 'HTTP 502 counted as success'
        Assert-True ((ConvertFrom-ProxyDoctorCurlResult '000 502' 56).status -eq 'proxy_connect_error') 'CONNECT 502 conflated with origin 502'
        Assert-True ((ConvertFrom-ProxyDoctorCurlResult '000 200' 60).status -eq 'transport_error') 'TLS failure counted as success'
        Assert-True ((ConvertFrom-ProxyDoctorCurlResult '000 302' 56).failureStage -eq 'http_connect') 'CONNECT rejection misclassified'
        Assert-True ((ConvertFrom-ProxyDoctorCurlResult '502 200' 0).failureStage -eq 'http_response') 'origin response stage lost'
        Assert-True ((ConvertFrom-ProxyDoctorCurlResult '000 000' 97).failureStage -eq 'proxy_handshake') 'SOCKS handshake not identified'
        Assert-True ((ConvertFrom-ProxyDoctorCurlResult '000 000' 6).failureStage -eq 'destination_dns') 'destination DNS stage lost'
        Assert-True ((ConvertFrom-ProxyDoctorCurlResult '000 200' 60).failureStage -eq 'tls_certificate') 'TLS certificate stage lost'
        Assert-True ((ConvertFrom-ProxyDoctorCurlResult '000 200' 28).failureStage -eq 'timeout_stage_unknown') 'timeout stage was over-attributed'
    }
    Check 'socks-resolution-metadata' {
        $probe = Join-Path $root 'scripts\Test-NetworkPath.ps1'
        $local = & $probe -Proxy 'socks5://127.0.0.1:1' -IPv4 -Urls @() -DnsNames @() -Json | ConvertFrom-Json
        $remote = & $probe -Proxy 'socks5h://127.0.0.1:1' -IPv4 -Urls @() -DnsNames @() -Json | ConvertFrom-Json
        $direct = & $probe -Direct -Urls @() -DnsNames @() -Json | ConvertFrom-Json
        Assert-True ($local.socksDestinationResolution -eq 'client' -and $local.clientIPv4Requested -and $local.http.Count -eq 0) 'client-resolved invocation metadata incorrect'
        Assert-True ($remote.socksDestinationResolution -eq 'proxy' -and $remote.udp -eq 'not_probed') 'proxy-resolved invocation metadata incorrect'
        Assert-True ($null -eq $direct.socksDestinationResolution -and -not $direct.clientIPv4Requested) 'direct invocation incorrectly labeled SOCKS'
    }
    Check 'explicit-socks-overrides-bypass' {
        $probe = Join-Path $root 'scripts\Test-NetworkPath.ps1'
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $previous = [Environment]::GetEnvironmentVariable('NO_PROXY', 'Process')
        $listener.Start()
        try {
            [Environment]::SetEnvironmentVariable('NO_PROXY', 'no-match.invalid', 'Process')
            $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
            $listener.Stop()
            $out = & $probe -Proxy "socks5h://127.0.0.1:$port" -Urls @('https://no-match.invalid/') -DnsNames @() -Json | ConvertFrom-Json
            Assert-True ($out.http[0].curlExit -eq 7 -and $out.http[0].failureStage -eq 'connect') 'explicit proxy did not override the bypass list'
        }
        finally {
            $listener.Stop()
            [Environment]::SetEnvironmentVariable('NO_PROXY', $previous, 'Process')
        }
    }
    Check 'lifecycle-debounce-and-recovery-are-read-only' {
        $ready = @{ts='2026-01-01T00:00:00Z';source='fixture';uiEnabled=$true;proxyEnabled=$true
            proxyServer='127.0.0.1:7897';proxyTargetsMixedPort=$true;pacConfigured=$false;coreRunning=$true
            mixedPortOpen=$true;mixedIPv4CoreOwned=$true;firstHopOpen=$true;healthProbe=@{status='ok'}}
        $timeout = $ready.Clone(); $timeout.healthProbe = @{status='transport_error';failureStage='timeout_stage_unknown'}
        $hopDown = $ready.Clone(); $hopDown.firstHopOpen = $false; $hopDown.healthProbe = $null
        $drift = $ready.Clone(); $drift.proxyServer = '127.0.0.1:11119'; $drift.proxyTargetsMixedPort = $false
        $otherProxy = $drift.Clone(); $otherProxy.uiEnabled = $false
        $appDown = $ready.Clone(); $appDown.applicationProbe = @{status='http_error';code='503'}
        $fixturePath = Join-Path $tmp 'lifecycle.json'
        ConvertTo-Json -InputObject @($ready,$ready,$timeout,$ready,$hopDown,$hopDown,$appDown,$appDown,$drift,$drift,$otherProxy,$otherProxy,$ready,$ready) -Depth 5 |
            Set-Content -LiteralPath $fixturePath
        $monitor = Join-Path $root 'scripts\Watch-ProxyLifecycle.ps1'
        $records = @(& $monitor -FirstHopPort 11119 -TestFixture $fixturePath -Json | ForEach-Object { ConvertFrom-Json $_ })
        Assert-True ($records.Count -eq 14) 'monitor did not terminate after the fixture length'
        Assert-True ($records[2].level -eq 'sample' -and $records[2].confirmed -eq 'HTTPS_PROBE_OK') 'one timeout caused an alert'
        Assert-True ($records[5].transition.to -eq 'FIRST_HOP_LISTENER_MISSING' -and $records[7].transition.to -eq 'APPLICATION_PROBE_FAILED') 'listener return was treated as application recovery'
        Assert-True ($records[8].proxyChange.actor -eq 'unknown' -and $records[8].proxyChange.before.server -eq '127.0.0.1:7897' -and $records[9].level -eq 'warning') 'proxy drift evidence or alert missing'
        Assert-True ($records[11].confirmed -eq 'OTHER_PROXY_SELECTED' -and $records[11].level -eq 'info') 'alternative proxy selection elicited a repair warning'
        Assert-True ($records[13].transition.to -eq 'HTTPS_PROBE_OK') 'repeated successful measurements did not confirm recovery'
    }
    Check 'unavailable-listener-data-remains-unknown' {
        $snapshot = Get-Content -LiteralPath (Join-Path $testDir 'fixtures\state-healthy.json') -Raw | ConvertFrom-Json
        $snapshot.mixedPortOpen = $null
        $path = Join-Path $tmp 'unavailable-listener.json'
        $snapshot | ConvertTo-Json | Set-Content -LiteralPath $path
        $result = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\Test-ProxyConsistency.ps1') -SnapshotFile $path -Json
        Assert-True ($LASTEXITCODE -eq 3 -and $null -eq ($result | ConvertFrom-Json).consistent) 'unavailable listener state was promoted to a known result'
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
        $m.zipSha256 = '0' * 64
        $m | ConvertTo-Json | Set-Content -LiteralPath ($enc + '.json')
        $rejectedZip = Join-Path $tmp 'rejected.zip'
        $sentinel = $rejectedZip + '.tmp'
        Set-Content -LiteralPath $sentinel 'existing-file'
        $rejectedExit = & {
            $ErrorActionPreference = 'Continue'
            & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\Unprotect-Backup.ps1') -InFile $enc -OutFile $rejectedZip 2>$null | Out-Null
            $LASTEXITCODE
        }
        Assert-True ($rejectedExit -ne 0 -and -not (Test-Path -LiteralPath $rejectedZip)) 'invalid hash yielded plaintext output'
        Assert-True ((Get-Content -LiteralPath $sentinel) -eq 'existing-file') 'existing temporary file was overwritten or deleted'
    }
    Check 'recovery-verdict-fixtures' {
        . (Join-Path $root 'scripts\RecoveryVerdict.ps1')
        $fixture = Get-Content -LiteralPath (Join-Path $testDir 'fixtures\recovery-fixtures.json') -Raw | ConvertFrom-Json
        $required = @(
            'complete-success', 'exit-code-alone', 'decimal-32.5', 'string-true', 'missing-field',
            'extra-write-line', 'writesmatch-true-raw-differs', 'cancelled', 'timed-out',
            'illegal-expected-99', 'empty-object'
        )
        $seen = @{}
        foreach ($case in @($fixture.cases)) {
            $verdict = Test-ProxyDoctorRecoveryResult $case.result
            $seen[[string]$case.name] = $true
            $reasons = @($verdict.Reasons) -join ','
            Assert-True ($verdict.CompleteSuccess -eq [bool]$case.completeSuccess) ($case.name + ' CompleteSuccess expected ' + $case.completeSuccess + ' actual ' + $verdict.CompleteSuccess + ' reasons=' + $reasons)
            Assert-True ($verdict.EvidenceScope -eq 'LiveUnchanged compares the proxy selection at the start and end only.') ($case.name + ' LiveUnchanged text changed')
        }
        foreach ($name in $required) {
            Assert-True ($seen.ContainsKey($name)) ('fixture missing ' + $name)
        }
    }
}
finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ('COUNTS=' + $count + ' failures=' + $failures.Count)
if ($failures.Count) { $failures | ForEach-Object { Write-Host ('  - ' + $_) }; exit 1 }
if ($count -eq 0) { exit 2 }
exit 0
