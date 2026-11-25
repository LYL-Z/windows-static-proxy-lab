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
    param([int]$Port, [string]$ReadyFile, [string]$Reply = 'Complete')
    $scriptPath = Join-Path $root 'fake-hop.ps1'
    $body = @'
param([int]$Port, [string]$Ready, [string]$Reply)
$crlf = [string][char]13 + [string][char]10
$l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
$l.Start()
[System.IO.File]::WriteAllText($Ready, 'ready')
for ($n = 0; $n -lt 6; $n++) {
    $c = $null
    try {
        $c = $l.AcceptTcpClient()
        $s = $c.GetStream()
        if ($Reply -eq 'Stalled') { Start-Sleep -Milliseconds 700 }
        if ($Reply -eq 'Fragmented') {
            $prefix = [Text.Encoding]::ASCII.GetBytes('HTTP/1.1 2')
            $s.Write($prefix, 0, $prefix.Length)
            Start-Sleep -Milliseconds 75
        }
        $statusLine = switch ($Reply) {
            'Fragmented' { '00 Connection Established' }
            'Malformed' { 'HTTP/1.1 2000 invalid' }
            default { 'HTTP/1.1 200 Connection Established' }
        }
        $resp = [Text.Encoding]::ASCII.GetBytes($statusLine + $crlf + $crlf)
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
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath, '-Port', [string]$Port, '-Ready', $ReadyFile, '-Reply', $Reply) -PassThru -WindowStyle Hidden
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
            foreach ($op in @({ Set-V4SystemProxy -Server '127.0.0.1:1' }, { Clear-V4SystemProxy })) {
                try { & $op | Out-Null } catch { $blocked++ }
            }
            Assert-Infra ($blocked -eq 2) ('test-mode guard blocked ' + $blocked + '/2 registry operations')
            Assert-Infra (Start-V4Clash) 'test-mode Start-V4Clash was not a safe no-op'
            Assert-Infra (Stop-V4Clash) 'test-mode Stop-V4Clash was not a safe no-op'
            $p = Get-V4Paths
            Assert-Infra (-not $p.AppData) 'test mode fell back to the real appdata'
            Assert-Infra (-not $p.Exe) 'test mode fell back to the real executable'
            $script:Actual = 'registry writes blocked; process start/stop are safe no-ops; paths did not fall back'
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
            Save-V4Settings -Host_ '203.0.113.10' -Port 1080 -Username 'fixture-user' -Password 'fixture-pass' -HopHost '127.0.0.1' -HopPort 11119 -MixedPort 7897
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
        'INF-FIRSTHOP-01' {
            $port = Get-FreePort
            $down = Test-V4FirstHop -Port $port -TimeoutMs 900
            Assert-Infra (-not $down.ok -and $down.status -eq 'TCP_UNAVAILABLE') 'closed port was treated as ready'
            $expected = [ordered]@{ Fragmented = 'CONNECT_OK'; Malformed = 'INVALID_REPLY'; Stalled = 'CONNECT_TIMEOUT' }
            foreach ($reply in $expected.Keys) {
                $readyFile = Join-Path $root ($reply + '.ready')
                $hop = Start-FakeHop -Port $port -ReadyFile $readyFile -Reply $reply
                try {
                    $budget = if ($reply -eq 'Stalled') { 200 } else { 1500 }
                    $r = Test-V4FirstHop -Port $port -TimeoutMs $budget
                    Assert-Infra ($r.status -eq $expected[$reply] -and $r.ok -eq ($reply -eq 'Fragmented')) ('unexpected CONNECT result for ' + $reply + ': ' + $r.status)
                }
                finally { Stop-FakeHop $hop }
                $port = Get-FreePort
            }
            $script:Actual = 'loopback TCP, complete fragmented status, malformed line and timeout classified independently'
        }
        'INF-START-04' {
            $global:ReadyPolls = 0
            $global:LaunchCount = 0
            $ok = Start-V4ClashCore -TimeoutSec 1 -Port 1 -IsRunning { $true } -Launch { $global:LaunchCount++ } -Sleep { param($ms) Start-Sleep -Milliseconds 2 } -IsListening {
                $global:ReadyPolls++
                return ($global:ReadyPolls -eq 2)
            }
            Assert-Infra (-not $ok -and $global:ReadyPolls -ge 3 -and $global:LaunchCount -eq 0) ('transient listener accepted or duplicate process launched: ready=' + $ok + ', polls=' + $global:ReadyPolls + ', launches=' + $global:LaunchCount)
            $script:Actual = 'transient listener was rejected after the settle recheck without a duplicate launch'
        }
        'INF-START-05' {
            $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
            $listener.Start()
            try {
                $port = $listener.LocalEndpoint.Port
                $owner = (Get-Process -Id $PID -ErrorAction Stop).Path
                $other = Join-Path $env:WINDIR 'System32\cmd.exe'
                Assert-Infra (-not (Test-V4ClashListener -Port $port -ExpectedCore $other)) 'another owned socket was identified as the expected core'
                Assert-Infra (Test-V4ClashListener -Port $port -ExpectedCore $owner) 'listener using the expected executable was not identified'
            }
            finally { $listener.Stop() }
            $script:Actual = 'real loopback socket was matched to the expected owning executable'
        }
        'INF-STATE-CORE-02' {
            $settings = [pscustomobject]@{ host='203.0.113.10'; mixedPort=7897; hopPort=11119 }
            $proxy = [pscustomobject]@{ enabled=$true; server='127.0.0.1:7897' }
            $hop = [pscustomobject]@{ ok=$true; detail='200' }
            $r = Get-V4StateCore -Settings $settings -Owner $null -SystemProxy $proxy -AppPids $null -MixedPortOpen $true -FirstHop $hop -GetExitIp { throw 'unexpected probe without Clash PID' } -UiSystemProxy $true
            Assert-Infra (-not $r.clashRunning -and $r.mode -eq 'RAW' -and $r.chainStatus -eq 'NOT_PROBED') 'null process result was not classified as absent'
            $script:Actual = 'state reports no Clash PID and declines to probe an unrelated listener'
        }
        'INF-REPAIR-GUARD-01' {
            $app = New-TestAppData
            $core = Join-Path $root 'fake-core.cmd'
            Put-Text $core 'exit /b 0'
            $ui = Join-Path $app 'verge.yaml'
            $env:V4_TEST_APPDATA = $app
            $env:V4_TEST_CORE = $core
            $env:V4_TEST_UI_CONFIG = $ui
            try {
                Save-V4Settings -Host_ '203.0.113.10' -Port 1080 -Username 'fixture-user' -Password 'fixture-pass' -HopHost '127.0.0.1' -HopPort (Get-FreePort) -MixedPort (Get-FreePort)
                $apply = Join-Path $repo 'proxy_v4\apply-v4.ps1'
                foreach ($case in @(
                    @{ ui = 'false'; reason = 'disabled or unknown' }
                    @{ ui = 'true'; reason = 'marker could not be verified' }
                )) {
                    Put-Text $ui ('enable_system_proxy: ' + $case.ui)
                    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $apply -Repair 2>&1
                    $rc = $LASTEXITCODE
                    Assert-Infra ($rc -eq 32 -and ($out -join ' ') -match $case.reason) ('repair guard failed for ' + $case.reason + '; exit=' + $rc)
                    Assert-Infra (-not (Test-Path -LiteralPath (Join-Path $root 'config\owner.json'))) 'repair wrote an owner record'
                }
            }
            finally {
                Remove-Item Env:V4_TEST_APPDATA,Env:V4_TEST_CORE,Env:V4_TEST_UI_CONFIG -ErrorAction SilentlyContinue
            }
            $script:Actual = 'manual repair declined a saved disabled mode and unverified markers before first-hop probing'
        }
        'INF-REPAIR-GUARD-02' {
            $apply = Join-Path $root 'apply-v4.ps1'
            Copy-Item -LiteralPath (Join-Path $repo 'proxy_v4\apply-v4.ps1') -Destination $apply
            Put-Text (Join-Path $root 'config\settings.json') '{}'
            $fixtureLib = Join-Path $root 'lib\V4.ps1'
            Add-Content -LiteralPath $fixtureLib -Encoding ASCII -Value @'
if (-not $script:TestMode) { throw 'fixture requires test mode' }
$script:listenerReads = 0
$script:proxyValue = '127.0.0.1:19321'
function Get-V4Settings { [pscustomobject]@{host='203.0.113.10';hopPort=19321;mixedPort=19322} }
function Get-V4Paths { @{AppData=$script:Root;Core='fixture.exe'} }
function Get-V4UiSystemProxy { $true }
function Get-V4Integrity { @{markerOk=$true;runtimeMarkerOk=$true;profileHash='fixture'} }
function Get-V4AutomaticProxyStatus {
    if ($env:V68_CASE -eq 'Pac') { 'PRESENT' } else { 'NOT_OBSERVED' }
}
function Test-V4FirstHop { param($Port) @{ok=$true;detail='fixture'} }
function Get-V4SystemProxy { @{enabled=$true;server=$script:proxyValue} }
function Test-V4ClashListener {
    param($Port,$ExpectedCore)
    $script:listenerReads++
    switch ($env:V68_CASE) {
        'NoOwner' { return $false }
        'CoreChanged' { return ($script:listenerReads -lt 2) }
        'CoreLostAfterWrite' { return ($script:listenerReads -lt 3) }
        'RestoreFails' { return ($script:listenerReads -lt 3) }
        default { return $true }
    }
}
function Get-V4ExitIp {
    param($Proxy,$TimeoutSec)
    if ($env:V68_CASE -eq 'WrongExit') { '198.51.100.9' } else { '203.0.113.10' }
}
Set-V4TestRegistryWriter {
    param($Enabled,$Server)
    [IO.File]::AppendAllText($env:V68_WRITE_LOG, $Server + [Environment]::NewLine)
    if ($env:V68_CASE -eq 'RestoreFails' -and $Server -eq '127.0.0.1:19321') { throw 'fixture restore failure' }
    $script:proxyValue = $Server
}
'@
            $env:V68_WRITE_LOG = Join-Path $root 'writes.txt'
            try {
                foreach ($variant in @(
                    @{name='Pac';code=32;writes='';message='automatic proxy is present or unverified'},
                    @{name='NoOwner';code=32;writes='';message='listener could not be verified'},
                    @{name='CoreChanged';code=32;writes='';message='listener changed during the probe'},
                    @{name='WrongExit';code=31;writes='';message='nothing changed'},
                    @{name='CoreLostAfterWrite';code=32;writes='127.0.0.1:19322,127.0.0.1:19321';message='restored previous system proxy'},
                    @{name='RestoreFails';code=40;writes='127.0.0.1:19322,127.0.0.1:19321';message='restore of previous settings could not be verified'}
                )) {
                    $env:V68_CASE = $variant.name
                    [IO.File]::WriteAllText($env:V68_WRITE_LOG, '')
                    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $apply -Repair 2>&1
                    $rc = $LASTEXITCODE
                    $writes = (Get-Content -LiteralPath $env:V68_WRITE_LOG) -join ','
                    Assert-Infra ($rc -eq $variant.code -and ($out -join ' ') -match $variant.message) ($variant.name + ' unexpected exit or message: ' + $rc + ' ' + ($out -join ' '))
                    Assert-Infra ($writes -eq $variant.writes) ($variant.name + ' unexpected repair writes: ' + $writes)
                }
            } finally { Remove-Item Env:V68_CASE,Env:V68_WRITE_LOG -ErrorAction SilentlyContinue }
            $script:Actual = 'six isolated CLI variants distinguished repair refusal, verified rollback and failed restore'
        }
        'INF-F12-01' {
            $settings = [pscustomobject]@{ host='203.0.113.10'; mixedPort=7897; hopPort=11119 }
            $off = [pscustomobject]@{ enabled=$false; server='127.0.0.1:7897' }
            $on = [pscustomobject]@{ enabled=$true; server='127.0.0.1:7897' }
            $hopOk = [pscustomobject]@{ ok=$true; detail='200' }
            $hopBad = [pscustomobject]@{ ok=$false; detail='down' }
            $exitOk = { param($p) '203.0.113.10' }
            $a = Get-V4StateCore -Settings $settings -Owner $null -SystemProxy $off -AppPids @(1) -MixedPortOpen $true -FirstHop $hopOk -GetExitIp $exitOk -SettingsError '' -UiSystemProxy $true
            Assert-Infra ($a.state -eq 'DEGRADED') ('UI on / HKCU off reported ' + $a.state)
            Assert-Infra (($a.reasons -join ' ') -match 'UI reports system proxy enabled') 'UI-on/HKCU-off mismatch not reported'
            $b = Get-V4StateCore -Settings $settings -Owner $null -SystemProxy $on -AppPids @(1) -MixedPortOpen $true -FirstHop $hopOk -GetExitIp $exitOk -SettingsError '' -UiSystemProxy $false
            Assert-Infra ($b.state -eq 'DEGRADED') ('UI off / HKCU on reported ' + $b.state)
            Assert-Infra (($b.reasons -join ' ') -match 'UI reports system proxy disabled') 'UI-off/HKCU-on mismatch not reported'
            $c = Get-V4StateCore -Settings $settings -Owner $null -SystemProxy $on -AppPids @(1) -MixedPortOpen $true -FirstHop $hopBad -GetExitIp $exitOk -SettingsError '' -UiSystemProxy $true
            Assert-Infra ($c.state -eq 'DEGRADED') ('UI on + first hop down reported ' + $c.state)
            $unreadable = Get-V4StateCore -Settings $settings -SystemProxy $null -AppPids @(1) -MixedPortOpen $true -FirstHop $hopOk -GetExitIp $exitOk -UiSystemProxy $true
            Assert-Infra ($unreadable.systemProxy -eq 'unknown' -and -not $unreadable.windowsTargetsClash) 'unreadable proxy state was reported as off'
            $script:Actual = 'UI/actual proxy mismatch and first-hop failure are DEGRADED with reasons'
        }
        'INF-F12-02' {
            $off = [pscustomobject]@{ enabled=$false; server='127.0.0.1:7897' }
            $r = Get-V4StateCore -Settings $null -Owner $null -SystemProxy $off -AppPids @(1) -MixedPortOpen $true -FirstHop $null -GetExitIp $null -SettingsError '' -UiSystemProxy $true
            Assert-Infra ($r.state -eq 'FAILED') ('missing settings + UI mismatch reported ' + $r.state)
            $text = ($r.reasons -join ' ')
            Assert-Infra ($text -match 'settings.json missing') 'missing settings reason absent'
            Assert-Infra ($text -match 'UI reports system proxy enabled') 'UI mismatch reason absent when settings are missing'
            $script:Actual = 'missing settings reports FAILED and still includes the UI/HKCU mismatch reason'
        }
        'INF-F12-03' {
            $file = Join-Path $root 'verge.yaml'
            Put-Text $file ('enable_system_proxy: true' + $LF + 'proxy_host: 127.0.0.1' + $LF)
            $env:V4_TEST_UI_CONFIG = $file
            try {
                Assert-Infra ((Get-V4UiSystemProxy) -eq $true) 'UI true not parsed'
                Put-Text $file ('enable_system_proxy: false' + $LF)
                Assert-Infra ((Get-V4UiSystemProxy) -eq $false) 'UI false not parsed'
                Put-Text $file ('other: value' + $LF)
                Assert-Infra ($null -eq (Get-V4UiSystemProxy)) 'missing key not reported as unknown'
                Remove-Item $file -Force
                Assert-Infra ($null -eq (Get-V4UiSystemProxy)) 'missing file not reported as unknown'
            }
            finally { Remove-Item Env:V4_TEST_UI_CONFIG -ErrorAction SilentlyContinue }
            $script:Actual = 'verge.yaml enable_system_proxy true/false/missing parsed correctly'
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
            Assert-Infra ($d.chainStatus -eq 'EXPECTED_EXIT' -and -not $d.windowsTargetsClash) 'Windows target mismatch suppressed the independent chain probe'
            $e = Get-V4StateCore -Settings $settings -Owner $null -SystemProxy $proxyOk -AppPids @(1) -MixedPortOpen $true -FirstHop $hopBad -GetExitIp $exitOk -SettingsError ''
            Assert-Infra ($e.state -eq 'DEGRADED') 'first-hop down not DEGRADED'
            Assert-Infra ($e.chainStatus -eq 'NOT_PROBED') 'chain was promoted while dependency was down'
            $f = Get-V4StateCore -Settings $settings -Owner $null -SystemProxy $proxyOk -AppPids @(1) -MixedPortOpen $true -FirstHop $hopOk -GetExitIp $exitBad -SettingsError ''
            Assert-Infra ($f.state -eq 'DEGRADED') 'exit mismatch not DEGRADED'
            Assert-Infra ($f.chainStatus -eq 'UNEXPECTED_EXIT' -and $f.windowsTargetsClash) 'open listeners masked changed exit'
            $g = Get-V4StateCore -Settings $settings -Owner $null -SystemProxy $proxyOk -AppPids @(1) -MixedPortOpen $true -FirstHop $hopOk -GetExitIp $exitNone -SettingsError ''
            Assert-Infra ($g.state -eq 'FAILED') 'no exit IP not FAILED'
            $httpExit = {
                param($proxy)
                if ($proxy -ne 'http://127.0.0.1:7897') { throw 'state tested a different ingress from Windows HTTP(S)' }
                '203.0.113.10'
            }
            $h = Get-V4StateCore -Settings $settings -Owner $null -SystemProxy $proxyOk -AppPids @(1) -MixedPortOpen $true -FirstHop $hopOk -GetExitIp $httpExit -SettingsError '' -UiSystemProxy $true -AutomaticProxyStatus NOT_OBSERVED
            Assert-Infra ($h.state -eq 'CHAIN_VERIFIED' -and $h.applicationPath -eq 'NOT_TESTED') 'proxy sample was not separated from application acceptance'
            Assert-Infra ($h.chainStatus -eq 'EXPECTED_EXIT' -and $h.windowsTargetsClash) 'recovered dependency was not verified'
            $i = Get-V4StateCore -Settings $settings -Owner $null -SystemProxy $proxyOk -AppPids @(1) -MixedPortOpen $true -FirstHop $hopOk -GetExitIp $exitOk -SettingsError 'bad settings'
            Assert-Infra ($i.state -eq 'FAILED' -and ($i.reasons -join ' ') -match 'settings invalid') 'settings error not reported'
            $known = @{Settings=$settings; SystemProxy=$proxyOk; AppPids=@(1); MixedPortOpen=$true; FirstHop=$hopOk; GetExitIp=$httpExit; UiSystemProxy=$true }
            $withPac = Get-V4StateCore @known -AutomaticProxyStatus PRESENT
            Assert-Infra ($withPac.state -eq 'DEGRADED' -and 'AUTOMATIC_PROXY_UNVERIFIED' -in $withPac.faults) 'automatic proxy was ignored'
            $unreadablePac = Get-V4StateCore @known
            Assert-Infra ($unreadablePac.state -eq 'DEGRADED' -and 'AUTOMATIC_PROXY_UNVERIFIED' -in $unreadablePac.faults) 'unknown proxy selection was treated as verified'
            $known.GetExitIp = { throw 'fixture provider/chain failure' }
            $thrownExit = Get-V4StateCore @known -AutomaticProxyStatus NOT_OBSERVED
            Assert-Infra ($thrownExit.state -eq 'FAILED' -and 'CHAIN_EXIT_UNVERIFIED' -in $thrownExit.faults) 'an exit probe exception was suppressed'
            $known.GetExitIp = { '203.0.113.10'; '198.51.100.9' }
            $ambiguousExit = Get-V4StateCore @known -AutomaticProxyStatus NOT_OBSERVED
            Assert-Infra ($ambiguousExit.chainStatus -eq 'NO_EXIT') 'an ambiguous exit observation was accepted'
            $app = New-TestAppData
            $runtime = Join-Path $app 'clash-verge.yaml'
            $env:V4_TEST_APPDATA = $app
            try {
                $yaml = @(
                    'proxies:'
                    '- name: OtherProxy'
                    '  type: socks5'
                    '  udp: true'
                    '- name: "US-WA-SOCKS5"'
                    '  type: socks5'
                    '  dialer-proxy: "STAR-FIRSTHOP"'
                    '  udp: false'
                    'listeners:'
                    '- name: OtherListener'
                    '  udp: true'
                ) -join $LF
                Put-Text $runtime $yaml
                Assert-Infra ($false -eq (Get-V4UdpProxied)) 'an unrelated node or listener supplied the managed UDP flag'
                $enabled = $yaml.Replace('udp: false', 'udp: true')
                Put-Text $runtime $enabled
                Assert-Infra ($true -eq (Get-V4UdpProxied)) 'managed UDP flag true was not read'
                $udpState = Get-V4StateCore -Settings $settings -SystemProxy $proxyOk -AppPids @(1) -MixedPortOpen $true -FirstHop $hopOk -GetExitIp $httpExit -UdpProxied $true
                Assert-Infra ($udpState.udpDataPlane -eq 'not_probed') 'the configuration flag was promoted to UDP data-plane success'
                Put-Text $runtime ($enabled.Replace('STAR-FIRSTHOP', 'OtherHop'))
                Assert-Infra ($null -eq (Get-V4UdpProxied)) 'UDP reported a result for an unrecognized dialer'
            }
            finally { Remove-Item Env:V4_TEST_APPDATA -ErrorAction SilentlyContinue }
            $script:Actual = 'state branches and managed UDP evidence passed'
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
            $passFile = Join-Path $root 'fixture.pass'
            Put-Text $passFile 'fixture-pass'
            if (-not (Protect-V4Acl -Path $passFile)) { throw 'could not harden test credential file' }
            $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $apply -Init -StaticHost '203.0.113.10' -StaticPort 1080 -StaticUser 'fixture-user' -CredentialFile $passFile -HopPort 11119 -MixedPort 7897 2>&1
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
            Put-Text $core (@(
                '@echo off'
                'if not "%~4"=="-d" exit /b 20'
                'echo synthetic core cache > "%~5\dryrun-cache"'
                'exit /b 0'
            ) -join $CRLF)
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
                $beforeEvidence = @((Get-ChildItem -LiteralPath (Join-Path $root 'evidence') -File -ErrorAction SilentlyContinue).Name) -join '|'
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
                Assert-Infra (-not (Test-Path -LiteralPath (Join-Path $app 'dryrun-cache'))) 'DryRun gave the core the live work directory'
                $afterEvidence = @((Get-ChildItem -LiteralPath (Join-Path $root 'evidence') -File -ErrorAction SilentlyContinue).Name) -join '|'
                Assert-Infra ($beforeEvidence -eq $afterEvidence) 'DryRun wrote an evidence log'
                $script:Actual = 'real apply -DryRun reached validation and changed no config/settings/appdata'
            }
            finally {
                Stop-FakeHop $hop
                Remove-Item Env:V4_TEST_APPDATA -ErrorAction SilentlyContinue
                Remove-Item Env:V4_TEST_CORE -ErrorAction SilentlyContinue
            }
        }
        'INF-APPLY-INIT-02' {
            $apply = Join-Path $repo 'proxy_v4\apply-v4.ps1'
            $prevEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try { $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $apply -Init -StaticHost '203.0.113.10' -StaticPort 1080 -StaticUser 'fixture-user' -StaticPass 'fixture-pass' -HopPort 11119 -MixedPort 7897 2>&1 }
            finally { $ErrorActionPreference = $prevEap }
            $c = $LASTEXITCODE
            Assert-Infra ($c -eq 11) ('legacy -StaticPass exit=' + $c)
            Assert-Infra ((($out -join ' ') -match 'was removed')) 'legacy -StaticPass did not produce a removal error'
            Assert-Infra (-not (Test-Path -LiteralPath (Join-Path $root 'config\settings.json'))) 'removed -StaticPass wrote settings'
            $script:Actual = 'legacy -StaticPass is rejected with a removal message'
        }
        'INF-APPLY-INIT-03' {
            $apply = Join-Path $repo 'proxy_v4\apply-v4.ps1'
            $prevEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try { $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $apply -Init -StaticHost '203.0.113.10' -StaticPort 1080 -StaticUser 'fixture-user' -StaticPassFile (Join-Path $root 'x.pass') -HopPort 11119 -MixedPort 7897 2>&1 }
            finally { $ErrorActionPreference = $prevEap }
            $c = $LASTEXITCODE
            Assert-Infra ($c -eq 11) ('legacy -StaticPassFile exit=' + $c)
            Assert-Infra ((($out -join ' ') -match 'was removed')) 'legacy -StaticPassFile did not produce a removal error'
            Assert-Infra (-not (Test-Path -LiteralPath (Join-Path $root 'config\settings.json'))) 'removed -StaticPassFile wrote settings'
            $script:Actual = 'legacy -StaticPassFile is rejected with a removal message'
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
            Assert-Infra ($j.alert -eq 'PAUSE_APPLICATIONS' -and $j.coverage.applicationPath -eq 'NOT_TESTED') 'fault did not produce an explicit application warning'
            Assert-Infra ($j.recoveryAction -eq 'REVIEW_SETTINGS_OR_PROBE') 'corrupt settings did not prompt state review'
            Assert-Infra (($j.reasons -join ' ') -match 'settings') 'state reasons do not mention settings'
            Put-Text (Join-Path $root 'config\transaction.json') '{ not json'
            $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $state -Json 2>&1
            $c = $LASTEXITCODE
            $j = ($out -join [Environment]::NewLine) | ConvertFrom-Json
            Assert-Infra ($c -eq 3 -and $j.recoveryAction -eq 'REVIEW_PENDING_TRANSACTION') 'existing transaction did not take priority'
            $script:Actual = 'corrupt settings produce FAILED and exit 3; a remaining journal takes priority in recovery guidance'
        }
        'INF-STATE-SCRIPT-02' {
            $state = Join-Path $root 'state-v4.ps1'
            Copy-Item -LiteralPath (Join-Path $repo 'proxy_v4\state-v4.ps1') -Destination $state
            Add-Content -LiteralPath (Join-Path $root 'lib\V4.ps1') -Encoding ASCII -Value @'
if (-not $script:TestMode) { throw 'fixture requires test mode' }
$script:sampleIndex = 0
function Start-Sleep { param($Seconds) }
function Get-V4Integrity { @{markerOk=$true;runtimeMarkerOk=$true} }
function Get-V4State {
    $script:sampleIndex++
    $hop = if ($script:sampleIndex -lt 3) { @{ok=$false;detail='fixture stopped'} } else { @{ok=$true;detail='fixture returned'} }
    Get-V4StateCore -Settings @{host='203.0.113.10';mixedPort=19322} -AppPids @(1) -MixedPortOpen $true `
        -SystemProxy @{enabled=$true;server='127.0.0.1:19322'} -FirstHop ([pscustomobject]$hop) `
        -GetExitIp { '203.0.113.10' } -UiSystemProxy $true -AutomaticProxyStatus NOT_OBSERVED
}
'@
            $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $state -Json -Samples 3 2>&1
            $rc = $LASTEXITCODE
            $records = @($out | ForEach-Object { $_ | ConvertFrom-Json })
            Assert-Infra ($rc -eq 2 -and $records.Count -eq 3) 'chain recovery unexpectedly returned full success'
            $alerts = @($records | ForEach-Object alert) -join ','
            Assert-Infra ($alerts -eq 'PAUSE_APPLICATIONS,NONE,CHAIN_REVERIFIED_APPLICATION_PENDING') ('unexpected alert sequence: ' + $alerts)
            Assert-Infra ($records[2].coverage.applicationPath -eq 'NOT_TESTED') 'the CLI promoted chain recovery to application recovery'
            $script:Actual = $alerts
        }
        'INF-SETTINGS-04' {
            Save-V4Settings -Host_ '203.0.113.10' -Port 1080 -Username 'fixture-user' -Password 'fixture-pass' -HopHost '127.0.0.1' -HopPort 11119 -MixedPort 7897
            $sp = Join-Path $root 'config\settings.json'
            & icacls $sp /grant '*S-1-1-0:(R)' | Out-Null
            Assert-FaultCode { Get-V4Settings } 12 'settings with a widened ACL'
            $script:Actual = 'Get-V4Settings refuses a settings file whose ACL was widened'
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
        'INF-F06-01' {
            $s = [pscustomobject]@{ host='203.0.113.10'; port=1080; username='u'; password='p'; hopHost='127.0.0.1'; hopPort=11119; mixedPort=7897 }
            $strict = Build-V4Profile -S $s -Mode 'strict'
            $resilient = Build-V4Profile -S $s -Mode 'resilient'
            Assert-Infra (-not $strict.Contains('"DIRECT"')) 'strict profile contains DIRECT'
            Assert-Infra ($strict.Contains('type: select')) 'strict profile is not a select group'
            Assert-Infra ($resilient.Contains('"DIRECT"')) 'resilient profile lost DIRECT'
            Assert-Infra ($resilient.Contains('type: fallback')) 'resilient profile is not fallback'
            $script:Actual = 'strict=select without DIRECT; resilient=fallback with DIRECT'
        }
        'INF-ROLLBACK-01' {
            $fx = New-SnapshotFixture
            $snapProfiles = Join-Path $fx.snap 'profiles.yaml'
            $expected = Get-Sha $snapProfiles
            Write-V4Journal -SnapshotDir $fx.snap -Reason 'rollback-test'
            Put-Text (Join-Path $fx.app 'profiles.yaml') 'changed-live'
            Put-Text (Join-Path $fx.app 'clash-verge.yaml') 'changed-runtime'
            $newer = Join-Path $script:BackupDir 'newer-fallback'
            $null = New-V4SnapshotFiles -AppData $fx.app -ProfilesDir (Join-Path $fx.app 'profiles') -Dir $newer -SystemProxy $null -ClashRunningBefore $false -Reason 'test newer fallback'
            Assert-Infra ((Get-Sha (Join-Path $newer 'profiles.yaml')) -ne $expected) 'fallback fixture unexpectedly matches journal'
            $env:V4_TEST_APPDATA = $fx.app
            try {
                $rollback = Join-Path $repo 'proxy_v4\rollback-v4.ps1'
                $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $rollback -KeepSystemProxy 2>&1
                $c = $LASTEXITCODE
                Assert-Infra ($c -eq 0) ('rollback exit=' + $c + ' out=' + (($out | Select-Object -Last 5) -join ' | '))
                Assert-Infra ((Get-Sha (Join-Path $fx.app 'profiles.yaml')) -eq $expected) 'rollback did not restore profiles.yaml'
                Assert-Infra ($null -eq (Get-V4Journal)) 'rollback did not clear the journal'
                Assert-Infra (-not (Test-Path -LiteralPath (Join-Path $root 'config\.lock'))) 'rollback left the lock behind'
                $script:Actual = 'default rollback selected the journal snapshot over the newer valid fallback, restored files and cleared journal and lock'
            }
            finally { Remove-Item Env:V4_TEST_APPDATA -ErrorAction SilentlyContinue }
        }
        'INF-ROLLBACK-02' {
            $fx = New-SnapshotFixture
            $liveBefore = Get-Sha (Join-Path $fx.app 'profiles.yaml')
            Put-Text (Join-Path $fx.snap 'clash-verge.yaml') 'tampered'
            $env:V4_TEST_APPDATA = $fx.app
            try {
                $rollback = Join-Path $repo 'proxy_v4\rollback-v4.ps1'
                $prevEap = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                try { $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $rollback -SnapshotDir $fx.snap -KeepSystemProxy 2>&1 }
                finally { $ErrorActionPreference = $prevEap }
                $c = $LASTEXITCODE
                Assert-Infra ($c -eq 40) ('corrupt snapshot rollback exit=' + $c)
                Assert-Infra ((Get-Sha (Join-Path $fx.app 'profiles.yaml')) -eq $liveBefore) 'live files changed despite a refused snapshot'
                Assert-Infra (-not (Test-Path -LiteralPath (Join-Path $root 'config\.lock'))) 'failed rollback left the lock behind'
                $script:Actual = 'corrupt snapshot rollback exited 40, live files intact, lock released'
            }
            finally { Remove-Item Env:V4_TEST_APPDATA -ErrorAction SilentlyContinue }
        }
        'INF-ROLLBACK-03' {
            $l = Enter-V4Lock -TimeoutSec 2
            Assert-Infra ($null -ne $l) 'could not acquire the test lock'
            $log = Join-Path $root 'start.log'
            $env:V4_TEST_START_LOG = $log
            try {
                $rollback = Join-Path $repo 'proxy_v4\rollback-v4.ps1'
                $prevEap = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                try { $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $rollback -SnapshotDir (Join-Path $root 'missing') 2>&1 }
                finally { $ErrorActionPreference = $prevEap }
                $c = $LASTEXITCODE
                Assert-Infra ($c -eq 33) ('lock-busy rollback exit=' + $c)
                Assert-Infra (Test-Path -LiteralPath (Join-Path $root 'config\.lock')) 'loser deleted the winner lock'
                Assert-Infra (-not (Test-Path -LiteralPath $log) -or (Get-Content -LiteralPath $log -Raw).Trim().Length -eq 0) 'lock-busy rollback attempted to start Clash'
                $script:Actual = 'lock-busy rollback exited 33, left the lock and did not start Clash'
            }
            finally {
                Remove-Item Env:V4_TEST_START_LOG -ErrorAction SilentlyContinue
                $null = Exit-V4Lock $l
            }
        }
        'INF-ROLLBACK-04' {
            $fx = New-SnapshotFixture
            Save-V4Settings -Host_ '203.0.113.10' -Port 1080 -Username 'fixture-user' -Password 'fixture-pass' -HopHost '127.0.0.1' -HopPort 11119 -MixedPort 65532
            $env:V4_TEST_APPDATA = $fx.app
            $log = Join-Path $root 'start.log'
            $env:V4_TEST_START_LOG = $log
            try {
                $rollback = Join-Path $repo 'proxy_v4\rollback-v4.ps1'
                $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $rollback -SnapshotDir $fx.snap -KeepSystemProxy 2>&1
                $c = $LASTEXITCODE
                Assert-Infra ($c -eq 0) ('rollback exit=' + $c + ' out=' + (($out | Select-Object -Last 5) -join ' | '))
                $text = if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Raw } else { '' }
                Assert-Infra ($text -match '\|65532') ('rollback did not use settings.mixedPort: ' + $text)
                $script:Actual = 'rollback used settings.mixedPort 65532 for the restart'
            }
            finally {
                Remove-Item Env:V4_TEST_APPDATA -ErrorAction SilentlyContinue
                Remove-Item Env:V4_TEST_START_LOG -ErrorAction SilentlyContinue
            }
        }
        { $_ -in @('INF-ROLLBACK-05', 'INF-ROLLBACK-06', 'INF-ROLLBACK-07') } {
            $fx = New-SnapshotFixture
            Write-V4Journal -SnapshotDir $fx.snap -Reason 'rollback-test'
            Put-Text (Join-Path $fx.app 'profiles.yaml') 'changed-live'
            $env:V4_TEST_APPDATA = $fx.app
            $env:V4_FIXTURE_START_FAILURE = if ($Case -eq 'INF-ROLLBACK-05') { '1' } else { '0' }
            $keep = $Case -eq 'INF-ROLLBACK-07'
            $env:V4_TEST_PROXY_ENABLE = '1'
            $env:V4_TEST_PROXY_SERVER = 'old:8080'
            $env:V4_FIXTURE_PROXY_WRITE_LOG = Join-Path $root 'proxy-write.log'
            $rollback = Join-Path $root 'rollback-v4.ps1'
            Copy-Item -LiteralPath (Join-Path $repo 'proxy_v4\rollback-v4.ps1') -Destination $rollback
            $stubs = @'
if (-not $script:TestMode) { throw 'rollback fixture requires V4_TEST_MODE' }
Set-V4TestRegistryWriter {
    param($enabled, $server)
    Add-Content -LiteralPath $env:V4_FIXTURE_PROXY_WRITE_LOG -Value 'write'
    $env:V4_TEST_PROXY_ENABLE = if ($enabled) { '1' } else { '0' }
    $env:V4_TEST_PROXY_SERVER = $server
}
function Start-V4Clash {
    param($TimeoutSec, $Port)
    if ($env:V4_FIXTURE_START_FAILURE -eq '1') { return $false }
    $env:V4_TEST_PROXY_ENABLE = '0'
    return $true
}
'@
            Add-Content -LiteralPath (Join-Path $root 'lib\V4.ps1') -Value ($LF + $stubs)
            try {
                $savedPreference = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                $argsForRollback = @('-SnapshotDir', $fx.snap)
                if ($keep) { $argsForRollback += '-KeepSystemProxy' }
                try { $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $rollback @argsForRollback 2>&1 }
                finally { $ErrorActionPreference = $savedPreference }
                $code = $LASTEXITCODE
                $expected = if ($env:V4_FIXTURE_START_FAILURE -eq '1') { 40 } else { 41 }
                $journalRetained = $null -ne (Get-V4Journal)
                Assert-Infra ($code -eq $expected -and $journalRetained) (
                    'rollback exit={0}, expected={1}, journal retained={2}, out={3}' -f $code, $expected, $journalRetained, (($out | Select-Object -Last 4) -join ' | '))
                Assert-Infra ((Get-Sha (Join-Path $fx.app 'profiles.yaml')) -eq (Get-Sha (Join-Path $fx.snap 'profiles.yaml'))) 'rollback did not restore profiles.yaml'
                Assert-Infra (-not (Test-Path -LiteralPath (Join-Path $root 'config\.lock'))) 'rollback left the lock behind'
                if ($keep) {
                    Assert-Infra ((Get-V4Journal).data.keepSystemProxy -eq $true) 'pending rollback lost its keep-proxy intent'
                    $savedPreference = $ErrorActionPreference
                    $ErrorActionPreference = 'Continue'
                    try { $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $rollback 2>&1 }
                    finally { $ErrorActionPreference = $savedPreference }
                    Assert-Infra ($LASTEXITCODE -eq 41) 'resumed rollback failed to preserve and verify the original keep-proxy mode'
                    Assert-Infra (-not (Test-Path -LiteralPath $env:V4_FIXTURE_PROXY_WRITE_LOG)) 'initial or resumed rollback unexpectedly performed a proxy write'
                }
                $script:Actual = 'real rollback script reported incomplete recovery, retained the journal and released the lock'
            }
            finally { Remove-Item Env:V4_TEST_APPDATA,Env:V4_FIXTURE_START_FAILURE,Env:V4_FIXTURE_PROXY_WRITE_LOG,Env:V4_TEST_PROXY_ENABLE,Env:V4_TEST_PROXY_SERVER -ErrorAction SilentlyContinue }
        }
        'INF-ROLLBACK-08' {
            $fx = New-SnapshotFixture
            Put-Text (Join-Path $fx.app 'profiles.yaml') 'changed-live'
            $env:V4_TEST_APPDATA = $fx.app
            $env:V4_TEST_PROXY_ENABLE = '0'
            $env:V4_TEST_PROXY_SERVER = 'old:8080'
            $env:V4_FIXTURE_PROXY_WRITE_LOG = Join-Path $root 'proxy-write.log'
            $env:V4_TEST_EXIT_AFTER_JOURNAL = '1'
            $rollback = Join-Path $root 'rollback-v4.ps1'
            Copy-Item -LiteralPath (Join-Path $repo 'proxy_v4\rollback-v4.ps1') -Destination $rollback
            $stubs = @'
if (-not $script:TestMode) { throw 'rollback fixture requires V4_TEST_MODE' }
Set-V4TestRegistryWriter {
    param($enabled, $server)
    Add-Content -LiteralPath $env:V4_FIXTURE_PROXY_WRITE_LOG -Value ("enabled=" + [int][bool]$enabled + " server=" + $server)
    $env:V4_TEST_PROXY_ENABLE = if ($enabled) { '1' } else { '0' }
    $env:V4_TEST_PROXY_SERVER = $server
}
function Start-V4Clash {
    param($TimeoutSec, $Port)
    $env:V4_TEST_PROXY_ENABLE = '1'
    $env:V4_TEST_PROXY_SERVER = 'old:8080'
    return $true
}
'@
            Add-Content -LiteralPath (Join-Path $root 'lib\V4.ps1') -Value ($LF + $stubs)
            try {
                $savedPreference = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                try { $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $rollback -SnapshotDir $fx.snap 2>&1 }
                finally { $ErrorActionPreference = $savedPreference }
                Assert-Infra ($LASTEXITCODE -eq 41) ('interrupted rollback exit=' + $LASTEXITCODE + ' out=' + (($out | Select-Object -Last 4) -join ' | '))
                $pending = Get-V4Journal
                Assert-Infra ($pending -and $pending.data.preserveUserOff -eq $true) 'journal did not record the user-off decision'
                Assert-Infra (-not (Test-Path -LiteralPath $env:V4_FIXTURE_PROXY_WRITE_LOG)) 'interrupted rollback wrote the proxy'
                Remove-Item Env:V4_TEST_EXIT_AFTER_JOURNAL
                $ErrorActionPreference = 'Continue'
                try { $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $rollback 2>&1 }
                finally { $ErrorActionPreference = $savedPreference }
                $writes = if (Test-Path -LiteralPath $env:V4_FIXTURE_PROXY_WRITE_LOG) { Get-Content -LiteralPath $env:V4_FIXTURE_PROXY_WRITE_LOG -Raw } else { '' }
                Assert-Infra ($LASTEXITCODE -eq 32) ('resumed rollback exit=' + $LASTEXITCODE + ' out=' + (($out | Select-Object -Last 4) -join ' | '))
                Assert-Infra ($writes -match 'enabled=0' -and $writes -notmatch 'enabled=1') ('resumed rollback did not only disable: ' + $writes)
                Assert-Infra ($null -eq (Get-V4Journal)) 'successful user-off rollback left the journal'
                Assert-Infra ((Get-Sha (Join-Path $fx.app 'profiles.yaml')) -eq (Get-Sha (Join-Path $fx.snap 'profiles.yaml'))) 'files were not restored'
                Assert-Infra (-not (Test-Path -LiteralPath (Join-Path $root 'config\.lock'))) 'rollback left the lock behind'
                $script:Actual = 'interrupted and resumed rollback kept the user-disabled proxy off'
            }
            finally { Remove-Item Env:V4_TEST_APPDATA,Env:V4_FIXTURE_PROXY_WRITE_LOG,Env:V4_TEST_PROXY_ENABLE,Env:V4_TEST_PROXY_SERVER,Env:V4_TEST_EXIT_AFTER_JOURNAL -ErrorAction SilentlyContinue }
        }
        'INF-ROLLBACK-09' {
            $fx = New-SnapshotFixture
            $env:V4_TEST_APPDATA = $fx.app
            $env:V4_TEST_PROXY_ENABLE = '0'
            $env:V4_TEST_PROXY_SERVER = 'old:8080'
            $env:V4_FIXTURE_PROXY_WRITE_LOG = Join-Path $root 'proxy-write.log'
            $rollback = Join-Path $root 'rollback-v4.ps1'
            Copy-Item -LiteralPath (Join-Path $repo 'proxy_v4\rollback-v4.ps1') -Destination $rollback
            $stubs = @'
if (-not $script:TestMode) { throw 'rollback fixture requires V4_TEST_MODE' }
Set-V4TestRegistryWriter {
    param($enabled, $server)
    Add-Content -LiteralPath $env:V4_FIXTURE_PROXY_WRITE_LOG -Value ("enabled=" + [int][bool]$enabled + " server=" + $server)
    $env:V4_TEST_PROXY_ENABLE = if ($enabled) { '1' } else { '0' }
    $env:V4_TEST_PROXY_SERVER = $server
}
function Start-V4Clash {
    param($TimeoutSec, $Port)
    $env:V4_TEST_PROXY_ENABLE = '1'
    $env:V4_TEST_PROXY_SERVER = '127.0.0.1:9'
    return $true
}
'@
            Add-Content -LiteralPath (Join-Path $root 'lib\V4.ps1') -Value ($LF + $stubs)
            try {
                $savedPreference = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                try { $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $rollback -SnapshotDir $fx.snap 2>&1 }
                finally { $ErrorActionPreference = $savedPreference }
                $writes = if (Test-Path -LiteralPath $env:V4_FIXTURE_PROXY_WRITE_LOG) { Get-Content -LiteralPath $env:V4_FIXTURE_PROXY_WRITE_LOG -Raw } else { '' }
                Assert-Infra ($LASTEXITCODE -eq 41) ('different-target rollback exit=' + $LASTEXITCODE + ' out=' + (($out | Select-Object -Last 4) -join ' | '))
                Assert-Infra ([string]::IsNullOrEmpty($writes)) ('different-target rollback wrote the proxy: ' + $writes)
                Assert-Infra ($null -ne (Get-V4Journal)) 'different-target rollback cleared the journal'
                Assert-Infra (-not (Test-Path -LiteralPath (Join-Path $root 'config\.lock'))) 'rollback left the lock behind'
                $script:Actual = 'a different enabled proxy during rollback was left unchanged'
            }
            finally { Remove-Item Env:V4_TEST_APPDATA,Env:V4_FIXTURE_PROXY_WRITE_LOG,Env:V4_TEST_PROXY_ENABLE,Env:V4_TEST_PROXY_SERVER -ErrorAction SilentlyContinue }
        }
        'INF-SNAP-09' {
            $app = New-TestAppData
            $target = Join-Path $app 'profiles.yaml'
            $encoding = [Text.UTF8Encoding]::new($true)
            [IO.File]::WriteAllText($target, (Get-Text $target), $encoding)
            $initialSha = Get-Sha $target
            $snap = Join-Path $root 'bom-snapshot'
            $null = New-V4SnapshotFiles -AppData $app -ProfilesDir (Join-Path $app 'profiles') -Dir $snap -SystemProxy $null -ClashRunningBefore $false
            Put-Text $target 'modified'
            $restored = Restore-V4Files -SnapshotDir $snap -AppData $app -ProfilesDir (Join-Path $app 'profiles')
            Assert-Infra ($restored.ok -and (Get-Sha $target) -eq $initialSha) ('snapshot bytes changed when restored: ' + (($restored.failures | ForEach-Object { $_.error }) -join ', '))
            $script:Actual = 'UTF-8 BOM snapshot restored with exact SHA-256'
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
        'INF-LOCK-06' {
            Ensure-V4Dir (Join-Path $root 'config')
            $lp = Join-Path $root 'config\.lock'
            $held = [IO.File]::Open($lp, 'CreateNew', 'Write', 'None')
            try {
                $timer = [Diagnostics.Stopwatch]::StartNew()
                $l = Enter-V4Lock -TimeoutSec 1
                Assert-Infra ($null -eq $l) 'lock acquired while an exclusive file handle was held'
                Assert-Infra ($timer.Elapsed.TotalSeconds -lt 4) 'sharing violation exceeded the bounded wait'
                Assert-Infra (Test-Path -LiteralPath $lp) 'loser removed the held lock'
            }
            finally { $held.Dispose() }
            $script:Actual = 'exclusive lock creation was treated as bounded lock contention'
        }
        'INF-LOCK-07' {
            Ensure-V4Dir (Join-Path $root 'config')
            $lp = Join-Path $root 'config\.lock'
            Put-Text $lp ''
            (Get-Item -LiteralPath $lp).LastWriteTime = (Get-Date).AddSeconds(-10)
            $sha = [Security.Cryptography.SHA256]::Create()
            try {
                $pathBytes = [Text.Encoding]::UTF8.GetBytes($lp.ToUpperInvariant())
                $name = 'Global\V4LockReap-' + [BitConverter]::ToString($sha.ComputeHash($pathBytes)).Replace('-','')
            }
            finally { $sha.Dispose() }
            $mutex = New-Object Threading.Mutex($false, $name)
            $ownsMutex = $false
            try {
                $ownsMutex = $mutex.WaitOne(0)
                Assert-Infra $ownsMutex 'could not hold the synthetic reaper mutex'
                $child = @'
if ($env:V4_TEST_MODE -ne '1') { exit 3 }
. (Join-Path $env:V4_TEST_ROOT 'lib\V4.ps1')
$lock = Enter-V4Lock -TimeoutSec 1
if ($lock) {
    $null = Exit-V4Lock $lock
    exit 2
}
exit 0
'@
                $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($child))
                & powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded
                $rc = $LASTEXITCODE
                Assert-Infra ($rc -eq 0 -and (Test-Path -LiteralPath $lp)) (
                    'second process ignored the reaping mutex: exit=' + $rc)
            }
            finally {
                if ($ownsMutex) { $mutex.ReleaseMutex() }
                $mutex.Dispose()
            }
            $lock = Enter-V4Lock -TimeoutSec 2
            Assert-Infra ($null -ne $lock -and (Exit-V4Lock $lock)) 'released reaper did not allow normal stale lock recovery'
            $script:Actual = 'second process respected stale removal serialization; released reaper allowed reacquisition'
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
        'INF-SNAP-06' {
            $snap = Join-Path $root 'empty-snap'
            Ensure-V4Dir $snap
            $m = [ordered]@{ schema=2; files=@(); absent=@(); systemProxy=@{enabled=$false;server=''} }
            Put-Text (Join-Path $snap 'manifest.json') ($m | ConvertTo-Json -Depth 5)
            $threw = $false
            try { Restore-V4Files -SnapshotDir $snap -AppData (Join-Path $root 'app') -ProfilesDir (Join-Path $root 'app\profiles') | Out-Null } catch { $threw = $true }
            Assert-Infra $threw 'empty manifest was accepted as a successful restore'
            $script:Actual = 'zero-entry snapshot manifest refused'
        }
        'INF-SNAP-07' {
            $fx = New-SnapshotFixture
            $mp = Join-Path $fx.snap 'manifest.json'
            $m = Get-Content -LiteralPath $mp -Raw -Encoding UTF8 | ConvertFrom-Json
            $m.files = @($m.files | Where-Object { [string]$_.name -ne 'profiles.yaml' })
            $m.absent = @($m.absent | Where-Object { [string]$_ -ne 'profiles.yaml' })
            Put-Text $mp ($m | ConvertTo-Json -Depth 7)
            $threw = $false
            try { Restore-V4Files -SnapshotDir $fx.snap -AppData $fx.app -ProfilesDir (Join-Path $fx.app 'profiles') | Out-Null } catch { $threw = $true }
            Assert-Infra $threw 'manifest without profiles.yaml was accepted'
            $script:Actual = 'snapshot not covering profiles.yaml refused'
        }
        'INF-SNAP-08' {
            $fx = New-SnapshotFixture
            $runtime = Join-Path $fx.app 'clash-verge.yaml'
            Remove-Item -LiteralPath $runtime -Force
            $res = Restore-V4Files -SnapshotDir $fx.snap -AppData $fx.app -ProfilesDir (Join-Path $fx.app 'profiles')
            Assert-Infra $res.ok ('restore failed: ' + (($res.failures | ForEach-Object { $_.name + ':' + $_.error }) -join '; '))
            Assert-Infra (Test-V4AclHardened -Path $runtime -Allowed (Get-V4AllowedSidSet)) 'recreated runtime file is not ACL-hardened'
            $script:Actual = 'recreated credential-bearing file was ACL-hardened after restore'
        }
        'INF-REDACT-03' {
            $checks = @(
                @{ text='{"password":"json-secret","user":"json-user"}'; forbidden='json-secret' },
                @{ text='{"token":"tok-123"}'; forbidden='tok-123' },
                @{ text='user: a b'; forbidden='a b' },
                @{ text='socks5://user:pass@203.0.113.10:1080'; forbidden='user' },
                @{ text='X-Api-Key: test-key-placeholder'; forbidden='test-key-placeholder' },
                @{ text='Cookie: session=abc'; forbidden='session=abc' }
            )
            foreach ($c in $checks) {
                $out = Get-V4Redacted $c.text
                Assert-Infra ($out -notmatch [regex]::Escape($c.forbidden)) ('leaked: ' + $c.forbidden + ' in ' + $out)
            }
            $script:Actual = 'JSON keys, user with spaces, URL userinfo and Cookie redacted'
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
