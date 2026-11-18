#Requires -Version 5.1
<#
  Run-InfraCase.ps1 - one isolated infrastructure/lifecycle check per process.
  Invoked by cases/60-infra.tests.ps1. The caller owns the temp root cleanup.
  ASCII-only source (PowerShell 5.1).
#>
param(
    [Parameter(Mandatory = $true)][string]$Case,
    [Parameter(Mandatory = $true)][string]$OutFile
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = [System.IO.Path]::GetFullPath((Join-Path $here '..\..\..\..'))
$root = Join-Path $env:TEMP ('v6infra-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $root 'lib') -Force | Out-Null
Copy-Item (Join-Path $repo 'proxy_v4\lib\V4.ps1') (Join-Path $root 'lib\V4.ps1') -Force
$env:V4_TEST_MODE = '1'
$env:V4_TEST_ROOT = $root
. (Join-Path $root 'lib\V4.ps1')
$LF = [string][char]10
$CRLF = [string][char]13 + [string][char]10
$script:Actual = ''
$script:CasePass = $false
$script:CaseDetail = ''

function Assert-Infra {
    param($Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Put-Text {
    param([string]$Path, [string]$Content)
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}
function Get-Text {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) }
    return $null
}
function Get-Sha {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 'ABSENT' }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}
function New-TestAppData {
    $app = Join-Path $root 'appdata'
    New-Item -ItemType Directory -Path (Join-Path $app 'profiles') -Force | Out-Null
    Put-Text (Join-Path $app 'profiles.yaml') ('current: SUB0002' + $LF + '- uid: SUB0002' + $LF + '  type: remote' + $LF + '  name: Other' + $LF + '  file: other.yaml' + $LF + '  updated: 222222' + $LF)
    Put-Text (Join-Path $app 'clash-verge.yaml') ('mixed-port: 7897' + $LF + 'external-controller-pipe: \\.\pipe\v6-test' + $LF + 'secret: v6-test' + $LF + 'dialer-proxy: STAR-FIRSTHOP' + $LF)
    return $app
}
function New-SnapshotFixture {
    $app = New-TestAppData
    $snap = Join-Path $root ('snap-' + [guid]::NewGuid().ToString('N').Substring(0,6))
    $r = New-V4SnapshotFiles -AppData $app -ProfilesDir (Join-Path $app 'profiles') -Dir $snap -SystemProxy ([pscustomobject]@{ enabled = $true; server = 'old:8080' }) -ClashRunningBefore $false -Reason 'infra'
    return [pscustomobject]@{ app = $app; snap = $snap; result = $r }
}
function Test-AclHasSid {
    param([string]$Path, [string]$Sid)
    foreach ($r in @((Get-Acl -LiteralPath $Path).Access)) {
        try { if ($r.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value -eq $Sid) { return $true } } catch { }
    }
    return $false
}
function Assert-FaultCode {
    param([scriptblock]$Action, [int]$Code, [string]$Message)
    $threw = $false
    $got = 0
    try { & $Action | Out-Null } catch { $threw = $true; if ($_.TargetObject -and $_.TargetObject.code) { $got = [int]$_.TargetObject.code } }
    Assert-Infra $threw ($Message + ': expected an exception')
    Assert-Infra ($got -eq $Code) ($Message + ': expected code ' + $Code + ', got ' + $got)
}
function Start-FakeHop {
    param([int]$Port, [string]$ReadyFile)
    $scriptPath = Join-Path $root 'fake-hop.ps1'
    $body = @'
param([int]$Port, [string]$Ready)
$crlf = [string][char]13 + [string][char]10
$l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
$l.Start()
[System.IO.File]::WriteAllText($Ready, 'ready')
for ($n = 0; $n -lt 6; $n++) {
    $c = $null
    try {
        $c = $l.AcceptTcpClient()
        $s = $c.GetStream()
        $resp = [System.Text.Encoding]::ASCII.GetBytes('HTTP/1.1 200 Connection Established' + $crlf + $crlf)
        $s.Write($resp, 0, $resp.Length)
        $s.Flush()
        Start-Sleep -Milliseconds 150
    }
    catch { }
    finally { if ($c) { try { $c.Close() } catch { } } }
}
$l.Stop()
'@
    Put-Text $scriptPath $body
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath, '-Port', [string]$Port, '-Ready', $ReadyFile) -PassThru -WindowStyle Hidden
    $deadline = (Get-Date).AddSeconds(8)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $ReadyFile) { return $p }
        Start-Sleep -Milliseconds 100
    }
    try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { }
    throw 'fake first hop did not become ready'
}
function Stop-FakeHop {
    param($Process)
    if ($Process) { try { if (-not $Process.HasExited) { Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue } } catch { } }
}
function Get-FreePort {
    $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $l.Start()
    $port = ([System.Net.IPEndPoint]$l.LocalEndpoint).Port
    $l.Stop()
    return $port
}

try {
    switch ($Case) {
        'INF-ACL-01' {
            $d = Join-Path $root 'acl'
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            $r1 = Protect-V4Acl -Path $d
            Assert-Infra $r1 'first Protect-V4Acl failed'
            & icacls $d /grant '*S-1-1-0:(R)' | Out-Null
            Assert-Infra (Test-AclHasSid $d 'S-1-1-0') 'fixture failed to add Everyone'
            $r2 = Protect-V4Acl -Path $d
            Assert-Infra $r2 'second Protect-V4Acl did not report success'
            Assert-Infra (-not (Test-AclHasSid $d 'S-1-1-0')) 'Everyone ACE survived the second hardening pass'
            $script:Actual = 'Everyone ACE removed; second pass returned true'
        }
        'INF-LOG-01' {
            $ev = Join-Path $root 'evidence'
            New-Item -ItemType File -Path $ev -Force | Out-Null
            $ok = Start-V4Log 'blocked'
            Assert-Infra (-not $ok) 'Start-V4Log reported success on a blocked path'
            Write-V4Log 'still alive'
            $script:Actual = 'blocked log path returned false; Write-V4Log continued'
        }
        'INF-LAZY-01' {
            Assert-Infra (-not (Test-Path -LiteralPath (Join-Path $root 'config'))) 'dot-source created config'
            Assert-Infra (-not (Test-Path -LiteralPath (Join-Path $root 'backup'))) 'dot-source created backup'
            $ok = Start-V4Log 'lazy'
            Assert-Infra $ok 'Start-V4Log failed on a clean root'
            Assert-Infra (Test-Path -LiteralPath (Join-Path $root 'evidence')) 'evidence directory missing'
            Assert-Infra (-not (Test-Path -LiteralPath (Join-Path $root 'config'))) 'Start-V4Log created config'
            Assert-Infra (-not (Test-Path -LiteralPath (Join-Path $root 'backup'))) 'Start-V4Log created backup'
            $script:Actual = 'no eager config/backup; only evidence created by Start-V4Log'
        }
        'INF-GUARD-01' {
            $blocked = 0
            foreach ($op in @({ Set-V4SystemProxy -Server '127.0.0.1:1' }, { Clear-V4SystemProxy }, { Start-V4Clash }, { Stop-V4Clash })) {
                try { & $op | Out-Null } catch { $blocked++ }
            }
            Assert-Infra ($blocked -eq 4) ('test-mode guard blocked ' + $blocked + '/4 operations')
            $p = Get-V4Paths
            Assert-Infra (-not $p.AppData) 'test mode fell back to the real appdata'
            Assert-Infra (-not $p.Exe) 'test mode fell back to the real executable'
            $script:Actual = '4/4 production operations blocked; paths did not fall back'
        }
        'INF-REDACT-01' {
            Register-V4Secret 'SuperSecret-123'
            $a = Get-V4Redacted 'password: SuperSecret-123'
            $b = Get-V4Redacted 'username: fixture-user'
            $c = Get-V4Redacted 'Proxy-Authorization: Basic YWJjOmRlZg=='
            $d = Get-V4Redacted 'socks5://user:pass@203.0.113.10:1080'
            Assert-Infra ($a -notmatch 'SuperSecret-123') 'password leaked'
            Assert-Infra ($b -notmatch 'fixture-user') 'username leaked'
            Assert-Infra ($c -notmatch 'YWJjOmRlZg==') 'Basic credential leaked'
            Assert-Infra ($d -notmatch 'user:pass') 'SOCKS userinfo leaked'
            $script:Actual = 'password/username/Basic/userinfo redacted'
        }
        'INF-DPAPI-01' {
            $plain = 'fixture-pass-123'
            $enc = Protect-V4Secret $plain
            Assert-Infra ($enc -notmatch [regex]::Escape($plain)) 'DPAPI ciphertext contains plaintext'
            $back = Unprotect-V4Secret $enc
            Assert-Infra ($back -eq $plain) 'DPAPI roundtrip mismatch'
            $script:Actual = 'DPAPI roundtrip ok; ciphertext does not contain plaintext'
        }
        'INF-SETTINGS-01' {
            Save-V4Settings -Host_ '203.0.113.10' -Port 1080 -Username 'fixture-user' -Password 'fixture-pass' -HopHost '127.0.0.1' -HopPort 11119 -MixedPort 7897
            $settingsPath = Join-Path $root 'config\settings.json'
            Assert-Infra (Test-Path -LiteralPath $settingsPath) 'settings.json missing'
            $raw = Get-Text $settingsPath
            Assert-Infra ($raw -notmatch [regex]::Escape('fixture-pass')) 'plaintext password in settings.json'
            Assert-Infra (-not (Test-AclHasSid $settingsPath 'S-1-1-0')) 'settings.json grants Everyone'
            $s = Get-V4Settings
            Assert-Infra ($s.host -eq '203.0.113.10') 'settings host mismatch'
            Assert-Infra ($s.password -eq 'fixture-pass') 'settings password roundtrip mismatch'
            $script:Actual = 'DPAPI at rest, no plaintext, ACL restricted, Get-V4Settings roundtrip'
        }
        'INF-SETTINGS-02' {
            New-Item -ItemType Directory -Path (Join-Path $root 'config') -Force | Out-Null
            Put-Text (Join-Path $root 'config\settings.json') '{ this is not json'
            Assert-FaultCode { Get-V4Settings } 11 'invalid settings JSON'
            $script:Actual = 'invalid settings rejected with code 11'
        }
        'INF-INIT-01' {
            $rt = Join-Path $root 'runtime.yaml'
            Put-Text $rt ('proxies:' + $LF + '  - name: node1' + $LF + '    type: socks5' + $LF + '    server: 203.0.113.10' + $LF + '    port: 1080' + $LF + '    username: "fixture-user"' + $LF + '    password: "fixture-pass"' + $LF)
            $global:InitSaved = $null
            $save = { param($h, $pt, $u, $pw, $hh, $hp, $mp) $global:InitSaved = [pscustomobject]@{ host=$h; port=$pt; user=$u; pass=$pw; hopPort=$hp; mixedPort=$mp } }
            $r = Invoke-V4Init -Paths ([pscustomobject]@{ RuntimeFile = $rt }) -Explicit @{} -Save $save -Log $null
            Assert-Infra ($global:InitSaved -ne $null) 'init did not call the settings writer'
            Assert-Infra ($global:InitSaved.host -eq '203.0.113.10') 'migrated host mismatch'
            Assert-Infra ($global:InitSaved.port -eq 1080) 'migrated port mismatch'
            Assert-Infra ($r.source -eq 'runtime profile migration') 'unexpected init source'
            $script:Actual = 'one socks5 node migrated through the injected writer'
        }
        'INF-INIT-02' {
            $rt = Join-Path $root 'runtime2.yaml'
            Put-Text $rt ('proxies:' + $LF + '  - name: node1' + $LF + '    type: socks5' + $LF + '    server: 203.0.113.10' + $LF + '    port: 1080' + $LF + '  - name: node2' + $LF + '    type: socks5' + $LF + '    server: 203.0.113.11' + $LF + '    port: 1081' + $LF)
            $global:InitSaved = $null
            $save = { param($h, $pt, $u, $pw, $hh, $hp, $mp) $global:InitSaved = $true }
            Assert-FaultCode { Invoke-V4Init -Paths ([pscustomobject]@{ RuntimeFile = $rt }) -Explicit @{} -Save $save -Log $null } 11 'ambiguous runtime profile'
            Assert-Infra ($null -eq $global:InitSaved) 'writer was called for an ambiguous profile'
            $script:Actual = 'two socks5 nodes rejected; writer not called'
        }
        'INF-INIT-03' {
            $global:InitSaved = $null
            $save = { param($h, $pt, $u, $pw, $hh, $hp, $mp) $global:InitSaved = $true }
            Assert-FaultCode { Invoke-V4Init -Paths $null -Explicit @{ host='203.0.113.10'; user='u' } -Save $save -Log $null } 11 'explicit init missing password'
            Assert-Infra ($null -eq $global:InitSaved) 'writer was called with incomplete credentials'
            $script:Actual = 'incomplete explicit credentials rejected; writer not called'
        }
        'INF-LOCK-01' {
            Ensure-V4Dir (Join-Path $root 'config')
            $lp = Join-Path $root 'config\.lock'
            Put-Text $lp '{"pid":999999,"token":"dead","processStart":"gone"}'
            $l = Enter-V4Lock -TimeoutSec 2
            Assert-Infra ($null -ne $l) 'stale lock was not reclaimed'
            Assert-Infra (Exit-V4Lock $l) 'fresh lock could not be released'
            Assert-Infra (-not (Test-Path -LiteralPath $lp)) 'lock file left behind'
            $script:Actual = 'dead-holder lock reclaimed and released'
        }
        'INF-LOCK-02' {
            $l = Enter-V4Lock -TimeoutSec 2
            Assert-Infra ($null -ne $l) 'could not acquire lock'
            $lp = Join-Path $root 'config\.lock'
            Assert-Infra (-not (Exit-V4Lock 'wrong-token')) 'wrong token deleted the lock'
            Assert-Infra (Test-Path -LiteralPath $lp) 'lock file disappeared after wrong-token exit'
            Assert-Infra (Exit-V4Lock $l) 'correct token could not release the lock'
            $script:Actual = 'wrong token did not delete the winner lock'
        }
        'INF-LOCK-03' {
            Ensure-V4Dir (Join-Path $root 'config')
            $lp = Join-Path $root 'config\.lock'
            Put-Text $lp ('{"pid":' + $PID + ',"token":"reuse","processStart":"different-start"}')
            $l = Enter-V4Lock -TimeoutSec 2
            Assert-Infra ($null -ne $l) 'PID-reuse lock was not treated as stale'
            Assert-Infra (Exit-V4Lock $l) 'lock release failed'
            $script:Actual = 'PID reuse detected by process start time'
        }
        'INF-START-01' {
            $global:LaunchCount = 0
            $ok = Start-V4ClashCore -TimeoutSec 2 -Port 1 -IsListening { $true } -IsRunning { $true } -Launch { $global:LaunchCount++ } -Sleep { param($ms) }
            Assert-Infra $ok 'already-listening start returned false'
            Assert-Infra ($global:LaunchCount -eq 0) 'already-listening start launched a duplicate'
            $script:Actual = 'already-listening path did not launch a duplicate'
        }
        'INF-START-02' {
            $global:LaunchCount = 0
            $global:Probe = 0
            $ok = Start-V4ClashCore -TimeoutSec 3 -Port 1 -IsListening { $global:Probe++; return ($global:Probe -ge 2) } -IsRunning { $true } -Launch { $global:LaunchCount++ } -Sleep { param($ms) }
            Assert-Infra $ok 'delayed-listening start returned false'
            Assert-Infra ($global:LaunchCount -eq 0) 'already-running process was launched again'
            $script:Actual = 'running-but-not-yet-listening path waited without duplicate launch'
        }
        'INF-START-03' {
            $global:LaunchCount = 0
            $ok = Start-V4ClashCore -TimeoutSec 1 -Port 1 -IsListening { $false } -IsRunning { $false } -Launch { $global:LaunchCount++ } -Sleep { param($ms) }
            Assert-Infra (-not $ok) 'timeout path returned true'
            Assert-Infra ($global:LaunchCount -eq 1) 'timeout path did not launch exactly once'
            $script:Actual = 'timeout returned false after one launch'
        }
        'INF-STATE-CORE-01' {
            $settings = [pscustomobject]@{ host='203.0.113.10'; mixedPort=7897; hopPort=11119 }
            $proxyOk = [pscustomobject]@{ enabled=$true; server='127.0.0.1:7897' }
            $proxyBad = [pscustomobject]@{ enabled=$true; server='127.0.0.1:9999' }
            $hopOk = [pscustomobject]@{ ok=$true; detail='200' }
            $hopBad = [pscustomobject]@{ ok=$false; detail='down' }
            $exitOk = { param($p) '203.0.113.10' }
            $exitBad = { param($p) '198.51.100.9' }
            $exitNone = { param($p) $null }
            $a = Get-V4StateCore -Settings $null -Owner $null -SystemProxy $proxyOk -AppPids @() -MixedPortOpen $false -FirstHop $hopOk -GetExitIp $exitOk -SettingsError ''
            Assert-Infra ($a.state -eq 'FAILED') 'missing settings not FAILED'
            $b = Get-V4StateCore -Settings $settings -Owner $null -SystemProxy $proxyOk -AppPids @() -MixedPortOpen $false -FirstHop $hopOk -GetExitIp $exitOk -SettingsError ''
            Assert-Infra ($b.state -eq 'FAILED' -and $b.mode -eq 'RAW') 'not-running state wrong'
            $c = Get-V4StateCore -Settings $settings -Owner $null -SystemProxy $proxyOk -AppPids @(1) -MixedPortOpen $false -FirstHop $hopOk -GetExitIp $exitOk -SettingsError ''
            Assert-Infra ($c.state -eq 'FAILED' -and $c.mode -eq 'NEXIP') 'not-listening state wrong'
            $d = Get-V4StateCore -Settings $settings -Owner $null -SystemProxy $proxyBad -AppPids @(1) -MixedPortOpen $true -FirstHop $hopOk -GetExitIp $exitOk -SettingsError ''
            Assert-Infra ($d.state -eq 'DEGRADED') 'proxy mismatch not DEGRADED'
            $e = Get-V4StateCore -Settings $settings -Owner $null -SystemProxy $proxyOk -AppPids @(1) -MixedPortOpen $true -FirstHop $hopBad -GetExitIp $exitOk -SettingsError ''
            Assert-Infra ($e.state -eq 'DEGRADED') 'first-hop down not DEGRADED'
            $f = Get-V4StateCore -Settings $settings -Owner $null -SystemProxy $proxyOk -AppPids @(1) -MixedPortOpen $true -FirstHop $hopOk -GetExitIp $exitBad -SettingsError ''
            Assert-Infra ($f.state -eq 'DEGRADED') 'exit mismatch not DEGRADED'
            $g = Get-V4StateCore -Settings $settings -Owner $null -SystemProxy $proxyOk -AppPids @(1) -MixedPortOpen $true -FirstHop $hopOk -GetExitIp $exitNone -SettingsError ''
            Assert-Infra ($g.state -eq 'FAILED') 'no exit IP not FAILED'
            $h = Get-V4StateCore -Settings $settings -Owner $null -SystemProxy $proxyOk -AppPids @(1) -MixedPortOpen $true -FirstHop $hopOk -GetExitIp $exitOk -SettingsError ''
            Assert-Infra ($h.state -eq 'HEALTHY') 'healthy state wrong'
            $i = Get-V4StateCore -Settings $settings -Owner $null -SystemProxy $proxyOk -AppPids @(1) -MixedPortOpen $true -FirstHop $hopOk -GetExitIp $exitOk -SettingsError 'bad settings'
            Assert-Infra ($i.state -eq 'FAILED' -and ($i.reasons -join ' ') -match 'settings invalid') 'settings error not reported'
            $script:Actual = '9 state-core branches matched'
        }
        'INF-INTEGRITY-01' {
            $app = New-TestAppData
            $prof = Join-Path $app 'profiles\v4-managed.yaml'
            Put-Text $prof ($script:Marker + $LF + 'mixed-port: 7897' + $LF)
            $paths = [pscustomobject]@{ ProfilesDir = (Join-Path $app 'profiles'); RuntimeFile = (Join-Path $app 'clash-verge.yaml') }
            $r = Get-V4Integrity -Paths $paths
            Assert-Infra $r.profileExists 'profile not detected'
            Assert-Infra $r.markerOk 'marker not detected'
            Assert-Infra $r.runtimeMarkerOk 'runtime chain signature not detected'
            Put-Text $prof ('tampered' + $LF)
            $r2 = Get-V4Integrity -Paths $paths
            Assert-Infra (-not $r2.markerOk) 'tampered profile still reports marker'
            $script:Actual = 'marker and runtime chain detection work; tamper detected'
        }
        'INF-SNAP-01' {
            $fx = New-SnapshotFixture
            $app = $fx.app
            $profiles = Join-Path $app 'profiles.yaml'
            $managed = Join-Path $app 'profiles\v4-managed.yaml'
            $before = Get-Sha $profiles
            Put-Text $managed 'new-managed'
            Put-Text $profiles 'changed'
            $res = Restore-V4Files -SnapshotDir $fx.snap -AppData $app -ProfilesDir (Join-Path $app 'profiles')
            Assert-Infra $res.ok ('restore failed: ' + (($res.failures | ForEach-Object { $_.name + ':' + $_.error }) -join '; '))
            Assert-Infra (-not (Test-Path -LiteralPath $managed)) 'restore did not remove a file that was absent at snapshot time'
            Assert-Infra ((Get-Sha $profiles) -eq $before) 'profiles.yaml hash not restored'
            Assert-Infra (-not (Test-AclHasSid $fx.snap 'S-1-1-0')) 'snapshot directory grants Everyone'
            $script:Actual = 'absent managed profile deleted; profiles.yaml hash restored; snapshot ACL restricted'
        }
        'INF-SNAP-02' {
            $fx = New-SnapshotFixture
            $app = $fx.app
            $runtime = Join-Path $app 'clash-verge.yaml'
            $before = Get-Sha $runtime
            Put-Text (Join-Path $fx.snap 'clash-verge.yaml') 'tampered-snapshot'
            $threw = $false
            try { Restore-V4Files -SnapshotDir $fx.snap -AppData $app -ProfilesDir (Join-Path $app 'profiles') | Out-Null } catch { $threw = $true }
            Assert-Infra $threw 'tampered snapshot was accepted'
            Assert-Infra ((Get-Sha $runtime) -eq $before) 'live runtime changed despite a refused snapshot'
            $script:Actual = 'hash mismatch refused before any live write'
        }
        'INF-SNAP-03' {
            $fx = New-SnapshotFixture
            $app = $fx.app
            $mp = Join-Path $fx.snap 'manifest.json'
            $m = Get-Content -LiteralPath $mp -Raw -Encoding UTF8 | ConvertFrom-Json
            $m.absent = @('..\evil.yaml')
            Put-Text $mp ($m | ConvertTo-Json -Depth 7)
            $threw = $false
            try { Restore-V4Files -SnapshotDir $fx.snap -AppData $app -ProfilesDir (Join-Path $app 'profiles') | Out-Null } catch { $threw = $true }
            Assert-Infra $threw 'path traversal in manifest was accepted'
            $script:Actual = 'unsafe snapshot path refused'
        }
        'INF-SNAP-04' {
            $fx = New-SnapshotFixture
            $app = $fx.app
            $runtime = Join-Path $app 'clash-verge.yaml'
            $profiles = Join-Path $app 'profiles.yaml'
            $snapProfiles = Join-Path $fx.snap 'profiles.yaml'
            $expected = Get-Sha $snapProfiles
            Put-Text $profiles 'changed-before-restore'
            $h = [System.IO.File]::Open($runtime, 'Open', 'ReadWrite', 'None')
            try {
                $res = Restore-V4Files -SnapshotDir $fx.snap -AppData $app -ProfilesDir (Join-Path $app 'profiles')
            }
            finally { $h.Close() }
            Assert-Infra (-not $res.ok) 'locked target did not produce a restore failure'
            Assert-Infra (@($res.failures).Count -ge 1) 'failure list is empty'
            Assert-Infra ((Get-Sha $profiles) -eq $expected) 'other files were not restored after one failure'
            $script:Actual = 'partial restore reported failure and still restored the unlocked file'
        }
        'INF-ATOMIC-01' {
            $tf = Join-Path $root 'atomic.txt'
            Put-Text $tf 'A'
            Set-V4Atomic -TargetPath $tf -Content 'B' | Out-Null
            Assert-Infra ((Get-Text $tf) -eq 'B') 'atomic replace did not commit'
            $left = @(Get-ChildItem -LiteralPath $root -File -Force | Where-Object { $_.Name -like '.v4stage-*' -or $_.Name -like '*.bak' })
            Assert-Infra ($left.Count -eq 0) ('atomic replace left ' + $left.Count + ' staging/backup file(s)')
            $script:Actual = 'replace committed; staging and backup cleaned'
        }
        'INF-ATOMIC-02' {
            $tf = Join-Path $root 'atomic2.txt'
            Put-Text $tf 'A'
            $threw = $false
            try { Set-V4Atomic -TargetPath $tf -Content 'C' -Validator { param($f) throw 'validator says no' } | Out-Null } catch { $threw = $true }
            Assert-Infra $threw 'validator rejection did not throw'
            Assert-Infra ((Get-Text $tf) -eq 'A') 'target changed after validator rejection'
            $left = @(Get-ChildItem -LiteralPath $root -File -Force | Where-Object { $_.Name -like '.v4stage-*' -or $_.Name -like '*.bak' })
            Assert-Infra ($left.Count -eq 0) 'validator rejection left staging/backup files'
            $script:Actual = 'validator rejection left the target intact and cleaned staging'
        }
        'INF-ATOMIC-03' {
            $tf = Join-Path $root 'atomic3.txt'
            Put-Text $tf 'A'
            $h = [System.IO.File]::Open($tf, 'Open', 'ReadWrite', 'None')
            $threw = $false
            try { Set-V4Atomic -TargetPath $tf -Content 'B' | Out-Null } catch { $threw = $true }
            finally { $h.Close() }
            Assert-Infra $threw 'locked target did not throw'
            Assert-Infra ((Get-Text $tf) -eq 'A') 'locked target was modified'
            $left = @(Get-ChildItem -LiteralPath $root -File -Force | Where-Object { $_.Name -like '.v4stage-*' -or $_.Name -like '*.bak' })
            Assert-Infra ($left.Count -eq 0) 'locked target failure left staging/backup files'
            $script:Actual = 'locked target refused, intact, staging cleaned'
        }
        'INF-LOG-02' {
            $ok = Start-V4Log 'normal'
            Assert-Infra $ok 'normal Start-V4Log failed'
            Assert-Infra (-not (Test-AclHasSid (Join-Path $root 'evidence') 'S-1-1-0')) 'evidence directory grants Everyone'
            $script:LogFile = Join-Path $root 'no-such-dir\x.log'
            Write-V4Log 'must not throw'
            $script:Actual = 'unwritable log file did not interrupt Write-V4Log; evidence ACL restricted'
        }
        'INF-SETTINGS-03' {
            Assert-FaultCode { Get-V4Settings } 11 'missing settings'
            $script:Actual = 'missing settings rejected with code 11'
        }
        'INF-PARAM-01' {
            $apply = Join-Path $repo 'proxy_v4\apply-v4.ps1'
            $o1 = & powershell -NoProfile -ExecutionPolicy Bypass -File $apply -Repair -DryRun 2>&1
            $c1 = $LASTEXITCODE
            $o2 = & powershell -NoProfile -ExecutionPolicy Bypass -File $apply -Init -Repair 2>&1
            $c2 = $LASTEXITCODE
            Assert-Infra ($c1 -eq 11) ('Repair+DryRun exit=' + $c1)
            Assert-Infra ($c2 -eq 11) ('Init+Repair exit=' + $c2)
            Assert-Infra (-not (Test-Path -LiteralPath (Join-Path $root 'config\settings.json'))) 'illegal combination wrote settings'
            $script:Actual = 'Repair+DryRun and Init+Repair both exit 11 without settings'
        }
        'INF-PARAM-02' {
            $apply = Join-Path $repo 'proxy_v4\apply-v4.ps1'
            $prevEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try { & powershell -NoProfile -ExecutionPolicy Bypass -File $apply -DryRun -Mode bogus 2>&1 | Out-Null }
            finally { $ErrorActionPreference = $prevEap }
            $c = $LASTEXITCODE
            Assert-Infra ($c -ne 0) 'invalid Mode was accepted'
            Assert-Infra (-not (Test-Path -LiteralPath (Join-Path $root 'config\settings.json'))) 'invalid Mode wrote settings'
            $script:Actual = 'invalid Mode refused with exit ' + $c
        }
        'INF-APPLY-INIT-01' {
            $apply = Join-Path $repo 'proxy_v4\apply-v4.ps1'
            $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $apply -Init -StaticHost '203.0.113.10' -StaticPort 1080 -StaticUser 'fixture-user' -StaticPass 'fixture-pass' -HopPort 11119 -MixedPort 7897 2>&1
            $c = $LASTEXITCODE
            Assert-Infra ($c -eq 10) ('Init with no appdata should stop at paths, exit=' + $c)
            $settingsPath = Join-Path $root 'config\settings.json'
            Assert-Infra (Test-Path -LiteralPath $settingsPath) 'Init did not write settings'
            $raw = Get-Text $settingsPath
            Assert-Infra ($raw -notmatch [regex]::Escape('fixture-pass')) 'plaintext password in settings.json'
            $s = Get-V4Settings
            Assert-Infra ($s.host -eq '203.0.113.10') 'Init host mismatch'
            Assert-Infra ($s.password -eq 'fixture-pass') 'Init credential roundtrip mismatch'
            Assert-Infra (-not (Test-Path -LiteralPath (Join-Path $root 'config\.lock'))) 'lock left behind after Init failure'
            $script:Actual = 'Init wrote DPAPI settings under the lock, then failed closed at missing paths (exit 10)'
        }
        'INF-DRYRUN-01' {
            $app = New-TestAppData
            $core = Join-Path $root 'fake-core.cmd'
            Put-Text $core ('@echo off' + $CRLF + 'exit /b 0' + $CRLF)
            $port = Get-FreePort
            $ready = Join-Path $root 'hop.ready'
            $hop = Start-FakeHop -Port $port -ReadyFile $ready
            try {
                Save-V4Settings -Host_ '203.0.113.10' -Port 1080 -Username 'fixture-user' -Password 'fixture-pass' -HopHost '127.0.0.1' -HopPort $port -MixedPort 65532
                $env:V4_TEST_APPDATA = $app
                $env:V4_TEST_CORE = $core
                $settingsPath = Join-Path $root 'config\settings.json'
                $beforeProfiles = Get-Sha (Join-Path $app 'profiles.yaml')
                $beforeRuntime = Get-Sha (Join-Path $app 'clash-verge.yaml')
                $beforeSettings = Get-Sha $settingsPath
                $apply = Join-Path $repo 'proxy_v4\apply-v4.ps1'
                $prevEap = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                try { $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $apply -DryRun 2>&1 }
                finally { $ErrorActionPreference = $prevEap }
                $c = $LASTEXITCODE
                Assert-Infra ($c -eq 0) ('DryRun exit=' + $c + ' output=' + (($out | Select-Object -Last 8) -join ' | '))
                Assert-Infra ((Get-Sha (Join-Path $app 'profiles.yaml')) -eq $beforeProfiles) 'DryRun changed profiles.yaml'
                Assert-Infra ((Get-Sha (Join-Path $app 'clash-verge.yaml')) -eq $beforeRuntime) 'DryRun changed runtime config'
                Assert-Infra ((Get-Sha $settingsPath) -eq $beforeSettings) 'DryRun changed settings.json'
                Assert-Infra (-not (Test-Path -LiteralPath (Join-Path $root 'backup'))) 'DryRun created a snapshot'
                Assert-Infra (-not (Test-Path -LiteralPath (Join-Path $root 'config\.lock'))) 'DryRun left the lock behind'
                $script:Actual = 'real apply -DryRun reached validation and changed no config/settings/appdata'
            }
            finally {
                Stop-FakeHop $hop
                Remove-Item Env:V4_TEST_APPDATA -ErrorAction SilentlyContinue
                Remove-Item Env:V4_TEST_CORE -ErrorAction SilentlyContinue
            }
        }
        'INF-STATE-SCRIPT-01' {
            New-Item -ItemType Directory -Path (Join-Path $root 'config') -Force | Out-Null
            Put-Text (Join-Path $root 'config\settings.json') '{ not json'
            $state = Join-Path $repo 'proxy_v4\state-v4.ps1'
            $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $state -Json 2>&1
            $c = $LASTEXITCODE
            Assert-Infra ($c -eq 3) ('state script exit=' + $c)
            $text = ($out -join [Environment]::NewLine)
            $j = $text | ConvertFrom-Json
            Assert-Infra ($j.state -eq 'FAILED') ('state=' + $j.state)
            Assert-Infra (($j.reasons -join ' ') -match 'settings') 'state reasons do not mention settings'
            $script:Actual = 'state script emitted FAILED JSON and exit 3 for corrupt settings'
        }
        'INF-INIT-04' {
            $rt = Join-Path $root 'runtime4.yaml'
            Put-Text $rt ('proxies:' + $LF + '  - name: node' + $LF + '    type: socks5' + $LF + '    server: 203.0.113.10' + $LF + '    port: 1080' + $LF + '    username: "fixture-user"' + $LF + '    password: "p#ss\"quoted"' + $LF)
            $global:InitSaved = $null
            $save = { param($h, $pt, $u, $pw, $hh, $hp, $mp) $global:InitSaved = [pscustomobject]@{ host=$h; port=$pt; user=$u; pass=$pw } }
            $r = Invoke-V4Init -Paths ([pscustomobject]@{ RuntimeFile = $rt }) -Explicit @{} -Save $save -Log $null
            Assert-Infra ($global:InitSaved -ne $null) 'init did not call the writer'
            Assert-Infra ($global:InitSaved.pass -eq 'p#ss"quoted') ('quoted password parsed as [' + $global:InitSaved.pass + ']')
            $script:Actual = 'quoted # and escaped quote preserved by the init scalar parser'
        }
        'INF-LOCK-05' {
            Ensure-V4Dir (Join-Path $root 'config')
            $lp = Join-Path $root 'config\.lock'
            Put-Text $lp ''
            (Get-Item -LiteralPath $lp).LastWriteTime = (Get-Date).AddSeconds(-10)
            $l = Enter-V4Lock -TimeoutSec 2
            Assert-Infra ($null -ne $l) 'zero-byte stale lock was never reclaimed'
            Assert-Infra (Exit-V4Lock $l) 'lock release failed'
            $script:Actual = 'zero-byte stale lock reclaimed after the grace period'
        }
        'INF-JOURNAL-01' {
            $snap = Join-Path $root 'journal-snap'
            Ensure-V4Dir $snap
            Write-V4Journal -SnapshotDir $snap -Reason 'infra'
            $j = Get-V4Journal
            Assert-Infra ($null -ne $j -and -not $j.corrupt) 'journal was not readable'
            Assert-Infra ([string]$j.data.snapshot -eq $snap) 'journal snapshot mismatch'
            $apply = Join-Path $repo 'proxy_v4\apply-v4.ps1'
            $prevEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try { $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $apply -DryRun 2>&1 }
            finally { $ErrorActionPreference = $prevEap }
            $c = $LASTEXITCODE
            Assert-Infra ($c -eq 34) ('pending journal did not block apply, exit=' + $c)
            Assert-Infra (Test-Path -LiteralPath (Join-Path $root 'config\transaction.json')) 'journal disappeared after a refused apply'
            Assert-Infra (Clear-V4Journal) 'journal could not be cleared'
            Assert-Infra ($null -eq (Get-V4Journal)) 'journal still present after clear'
            $script:Actual = 'journal roundtrip; pending journal blocked apply with exit 34; clear verified'
        }
        'INF-YAML-01' {
            $s = [pscustomobject]@{ host='203.0.113.10'; port=1080; username=('u"ser'); password=('p"a#ss' + $LF + 'udp: true'); hopHost='127.0.0.1'; hopPort=11119; mixedPort=7897 }
            $yaml = Build-V4Profile -S $s -Mode 'strict'
            Assert-Infra ($yaml.Contains('username: "u\"ser"')) 'username quote was not escaped'
            Assert-Infra ($yaml.Contains('password: "p\"a#ss\nudp: true"')) 'password quote/newline was not escaped'
            $injected = @([regex]::Matches($yaml, '(?m)^\s*udp: true\s*$')).Count
            Assert-Infra ($injected -eq 0) 'password injected a top-level udp: true line'
            $rt = Build-V4Runtime -S $s -Mode 'strict' -Pipe ('C:\x pipe') -Secret ('s"e' + $LF + 'x')
            Assert-Infra ($rt.Contains('external-controller-pipe: "C:\\x pipe"')) 'controller pipe was not escaped'
            Assert-Infra ($rt.Contains('secret: "s\"e\nx"')) 'runtime secret was not escaped'
            $script:Actual = 'quotes/newlines/backslashes escaped; no YAML line injection'
        }
        'INF-SNAP-05' {
            $app = New-TestAppData
            $profDir = Join-Path $app 'profiles'
            $sub = Join-Path $profDir 'sub.yaml'
            Put-Text $sub ('mixed-port: 7897' + $LF)
            $snap = Join-Path $root 'snap-existing'
            $r = New-V4SnapshotFiles -AppData $app -ProfilesDir $profDir -Dir $snap -SystemProxy ([pscustomobject]@{ enabled=$true; server='old:8080' }) -ClashRunningBefore $false -Reason 'infra'
            $manifest = Get-Content -LiteralPath (Join-Path $snap 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $names = @($manifest.files | ForEach-Object { [string]$_.name })
            Assert-Infra ($names -contains 'profiles\sub.yaml') ('existing profile was not recorded with a separator: ' + ($names -join ','))
            $before = Get-Sha $sub
            Put-Text $sub 'changed'
            $res = Restore-V4Files -SnapshotDir $snap -AppData $app -ProfilesDir $profDir
            Assert-Infra $res.ok ('restore failed: ' + (($res.failures | ForEach-Object { $_.name + ':' + $_.error }) -join '; '))
            Assert-Infra ((Get-Sha $sub) -eq $before) 'existing profile was not restored'
            $script:Actual = 'existing profiles/*.yaml recorded with a separator and restored'
        }
        'INF-REDACT-02' {
            $checks = @(
                @{ text='password: hello world'; forbidden='hello world' },
                @{ text='pass: abc'; forbidden='abc' },
                @{ text='secret=xyz'; forbidden='xyz' },
                @{ text='Authorization: Bearer abcdefgh'; forbidden='abcdefgh' },
                @{ text='Proxy-Authorization: Basic YWJj'; forbidden='YWJj' },
                @{ text='https://user:pass@example.com/x'; forbidden='user:pass' },
                @{ text='username: fixture-user'; forbidden='fixture-user' }
            )
            foreach ($c in $checks) {
                $out = Get-V4Redacted $c.text
                Assert-Infra ($out -notmatch [regex]::Escape($c.forbidden)) ('leaked: ' + $c.forbidden + ' in ' + $out)
            }
            $script:Actual = 'quoted/pass/secret/Bearer/short-Basic/URL/user fields redacted'
        }
        default { throw ('unknown infra case: ' + $Case) }
    }
    $script:CasePass = $true
}
catch {
    $script:CasePass = $false
    $script:CaseDetail = $_.Exception.Message
    if (-not $script:Actual) { $script:Actual = 'exception: ' + $script:CaseDetail }
}
$payload = [ordered]@{
    id = $Case
    pass = $script:CasePass
    detail = $script:CaseDetail
    actual = $script:Actual
    ts = (Get-Date).ToString('s')
}
[System.IO.File]::WriteAllText($OutFile, ($payload | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
if ($script:CasePass) { exit 0 } else { exit 1 }
