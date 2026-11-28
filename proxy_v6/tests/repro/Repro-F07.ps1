param([string]$Only = '*', [string]$OutFile = '')
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = (Resolve-Path (Join-Path $here '..\..\..')).Path
$bench = Join-Path $env:TEMP ('v4f07-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $bench 'lib') -Force | Out-Null
Copy-Item (Join-Path $repo 'proxy_v4\lib\V4.ps1') (Join-Path $bench 'lib\V4.ps1') -Force
. (Join-Path $bench 'lib\V4.ps1')
$LF = [string][char]10

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
function Get-Hash([string]$p) { if (Test-Path -LiteralPath $p) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash } else { 'ABSENT' } }
function Put([string]$p, [string]$c) { [System.IO.File]::WriteAllText($p, $c, (New-Object System.Text.UTF8Encoding($false))) }
function ReadText([string]$p) { if (Test-Path -LiteralPath $p) { [System.IO.File]::ReadAllText($p) } else { $null } }

$global:St = @{}
function Reset-Case([hashtable]$Overrides) {
    $root = Join-Path $bench ('case-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $profiles = Join-Path $root 'profiles.yaml'
    $managed = Join-Path $root 'v4-managed.yaml'
    $runtime = Join-Path $root 'clash-verge.yaml'
    Put $profiles ("current: SUB0002" + $LF + "- uid: SUB0002" + $LF + "  type: remote" + $LF + "  name: Other" + $LF + "  file: other.yaml" + $LF + "  updated: 222222" + $LF)
    Put $runtime 'original-runtime'
    $global:St = @{
        root=$root; profiles=$profiles; managed=$managed; runtime=$runtime
        running=$true; wasRunning=$true; proxyEnabled=$true; proxyServer='old:8080'
        writeCalls=0; restoreCalls=0; startCalls=0; ownerCalls=0; logCalls=0
        failSnapshot=$false; failAt=0; failRestore=$false; failStart=$false; failLog=$false
        failOwner=$false; failAcl=$false; exitIp='203.0.113.10'; snapFiles=@(); snapAbsent=@()
        stopCalls=0; journal=$false; ownerText='old-owner'; ownerRestores=0; useBuilder=$false; lastProfilesContent=''; snap=''
    }
    foreach ($k in $Overrides.Keys) { $global:St[$k] = $Overrides[$k] }
}
function Op-Snapshot([string]$reason) {
    $s = $global:St
    $s.wasRunning = $s.running
    $s.running = $false
    $s.snap = Join-Path $s.root 'snap'
    New-Item -ItemType Directory -Path $s.snap -Force | Out-Null
    $s.snapFiles = @(); $s.snapAbsent = @()
    foreach ($f in @($s.profiles,$s.managed,$s.runtime)) {
        $name = Split-Path $f -Leaf
        if (Test-Path -LiteralPath $f) {
            Copy-Item -LiteralPath $f (Join-Path $s.snap $name) -Force
            $s.snapFiles += $name
        } else { $s.snapAbsent += $name }
    }
    if ($s.failSnapshot) { throw 'snapshot failed after stop' }
    return $s.snap
}
function Op-Restore([string]$snap) {
    $s = $global:St
    $s.restoreCalls++
    if ($s.failRestore) { throw 'restore failed' }
    foreach ($name in $s.snapFiles) { Copy-Item -LiteralPath (Join-Path $snap $name) (Join-Path $s.root $name) -Force }
    foreach ($name in $s.snapAbsent) { $t = Join-Path $s.root $name; if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Force } }
    return @{ ok=$true }
}
function Op-WriteAtomic([string]$target, [string]$content, $validator) {
    $s = $global:St
    $s.writeCalls++
    if ($s.failAt -gt 0 -and $s.writeCalls -eq $s.failAt) { throw ('injected write failure at ' + $s.writeCalls) }
    if ($target -eq $s.profiles) { $s.lastProfilesContent = $content }
    Put $target $content
}
function Op-StopApp([int]$port) { $global:St.stopCalls++; $global:St.running = $false }
function Op-StartApp([int]$timeout, [int]$port) {
    $s = $global:St
    $s.startCalls++
    if ($s.failStart) { throw 'start failed' }
    $s.running = $true
    return $true
}
function Op-GetExitIp([string]$proxy) { return $global:St.exitIp }
function Op-SetSystemProxy([string]$server) { $global:St.proxyEnabled = $true; $global:St.proxyServer = $server }
function Op-GetSystemProxy { return [pscustomobject]@{ enabled=$global:St.proxyEnabled; server=$global:St.proxyServer } }
function Op-GetOwnerText { return $global:St.ownerText }
function Op-RestoreOwner([object]$text) { $global:St.ownerText = $text; $global:St.ownerRestores++ }
function Op-SetOwner([string]$server, [string]$note) { if ($global:St.failOwner) { throw 'owner write failed' }; $global:St.ownerCalls++; $global:St.ownerText = 'clash' }
function Op-ProtectAcl([string]$path) { if ($global:St.failAcl) { throw 'ACL hardening failed' }; return $true }
function Op-WriteJournal([string]$snap, [string]$reason) { $global:St.journal = $true }
function Op-ClearJournal { $global:St.journal = $false; return $true }
function Op-Log([string]$msg, [string]$level) { $global:St.logCalls++; if ($global:St.failLog) { throw 'log blocked' } }

function New-Context {
    $s = $global:St
    $pt = "current: V4Mngd0001" + $LF + "- uid: V4Mngd0001" + $LF + "  updated: 999999" + $LF
    return [pscustomobject]@{
        Reason='test'
        Mode='strict'
        Settings=[pscustomobject]@{ host='203.0.113.10'; mixedPort=7897 }
        Paths=[pscustomobject]@{ ProfilesFile=$s.profiles; ProfileFile=$s.managed; RuntimeFile=$s.runtime }
        ProfileText=$pt
        ProfileYaml='managed-profile'
        RuntimeYaml='new-runtime'
        ProfileValidator=$null
        RuntimeValidator=$null
        Redact={ param($m) $m }
        Ops=[pscustomobject]@{
            IsAppRunning={ $global:St.running }
            Snapshot={ param($r) Op-Snapshot $r }
            Restore={ param($d) Op-Restore $d }
            WriteAtomic={ param($t,$c,$v) Op-WriteAtomic $t $c $v }
            StopApp={ param($port) Op-StopApp $port }
            StartApp={ param($to,$port) Op-StartApp $to $port }
            GetExitIp={ param($p) Op-GetExitIp $p }
            SetSystemProxy={ param($srv) Op-SetSystemProxy $srv }
            ClearSystemProxy={ $global:St.proxyEnabled=$false; $global:St.proxyServer='' }
            GetSystemProxy={ Op-GetSystemProxy }
            SetOwner={ param($srv,$n) Op-SetOwner $srv $n }
            GetOwnerText={ Op-GetOwnerText }
            RestoreOwner={ param($text) Op-RestoreOwner $text }
            ProtectAcl={ param($p) Op-ProtectAcl $p }
            WriteJournal={ param($snap,$reason) Op-WriteJournal $snap $reason }
            ClearJournal={ Op-ClearJournal }
            Log={ param($m,$l) Op-Log $m $l }
        }
    }
}

Check 'F07-01' 'snapshot fails after stopping app: app state must be restored' {
    Reset-Case @{ failSnapshot=$true }
    $before = Get-Hash $global:St.profiles
    $res = Invoke-V4ApplyTransaction -Context (New-Context)
    AssertTrue (-not $res.ok) 'transaction reported success'
    AssertTrue ($global:St.running -eq $true) 'app was left stopped after snapshot failure'
    AssertTrue ((Get-Hash $global:St.profiles) -eq $before) 'profiles.yaml changed'
    'state restored, files intact'
}

Check 'F07-02' 'first live write fails: files unchanged, app restored' {
    Reset-Case @{ failAt=1 }
    $before = Get-Hash $global:St.profiles
    $res = Invoke-V4ApplyTransaction -Context (New-Context)
    AssertTrue (-not $res.ok) 'transaction reported success'
    AssertTrue ((Get-Hash $global:St.profiles) -eq $before) 'profiles.yaml changed'
    AssertTrue ($global:St.restoreCalls -ge 1) 'restore was not attempted'
    AssertTrue ($global:St.running -eq $true) 'app not restarted'
    'first write rejected, state restored'
}

Check 'F07-03' 'second write fails: first write rolled back' {
    Reset-Case @{ failAt=2 }
    $p0 = Get-Hash $global:St.profiles; $m0 = Get-Hash $global:St.managed
    $res = Invoke-V4ApplyTransaction -Context (New-Context)
    AssertTrue (-not $res.ok) 'transaction reported success'
    AssertTrue ((Get-Hash $global:St.profiles) -eq $p0) 'profiles.yaml not rolled back'
    AssertTrue ((Get-Hash $global:St.managed) -eq $m0) 'v4-managed.yaml existence not restored'
    'second write failure rolled back'
}

Check 'F07-04' 'third write fails: two writes rolled back' {
    Reset-Case @{ failAt=3 }
    $p0 = Get-Hash $global:St.profiles; $m0 = Get-Hash $global:St.managed; $r0 = Get-Hash $global:St.runtime
    $res = Invoke-V4ApplyTransaction -Context (New-Context)
    AssertTrue (-not $res.ok) 'transaction reported success'
    AssertTrue ((Get-Hash $global:St.profiles) -eq $p0) 'profiles.yaml not rolled back'
    AssertTrue ((Get-Hash $global:St.managed) -eq $m0) 'v4-managed.yaml not rolled back'
    AssertTrue ((Get-Hash $global:St.runtime) -eq $r0) 'runtime not rolled back'
    'third write failure rolled back'
}

Check 'F07-05' 'failure after proxy set (ACL): system proxy restored' {
    Reset-Case @{ failAcl=$true }
    $res = Invoke-V4ApplyTransaction -Context (New-Context)
    AssertTrue (-not $res.ok) 'transaction reported success'
    AssertTrue ($global:St.proxyServer -eq 'old:8080') ('system proxy left at ' + $global:St.proxyServer)
    'system proxy restored'
}

Check 'F07-06' 'restore fails while logging fails: return 40, no throw' {
    Reset-Case @{ failAt=2; failRestore=$true; failLog=$true }
    $threw = $false
    $res = $null
    try { $res = Invoke-V4ApplyTransaction -Context (New-Context) } catch { $threw = $true }
    AssertTrue (-not $threw) 'engine threw instead of reporting a recovery failure'
    AssertTrue ($res -and $res.exitCode -eq 40) ('exitCode=' + $(if($res){$res.exitCode}else{'null'}))
    'reported 40 without throwing'
}

Check 'F07-07' 'restore fails: app reconciliation still attempted' {
    Reset-Case @{ failAt=2; failRestore=$true }
    $res = Invoke-V4ApplyTransaction -Context (New-Context) | Out-Null
    AssertTrue ($global:St.startCalls -ge 1) 'app start was not attempted after restore failure'
    'start attempted'
}

Check 'F07-08' 'success writes all targets and owns proxy' {
    Reset-Case @{}
    $res = Invoke-V4ApplyTransaction -Context (New-Context)
    AssertTrue ($res.ok) ('not ok: ' + $res.error)
    AssertTrue ((ReadText $global:St.managed) -eq 'managed-profile') 'managed profile not written'
    AssertTrue ((ReadText $global:St.runtime) -eq 'new-runtime') 'runtime not written'
    AssertTrue ($global:St.proxyServer -eq '127.0.0.1:7897') 'proxy not set'
    AssertTrue ($global:St.ownerCalls -eq 1) 'owner not recorded'
    'all targets written'
}

Check 'F07-09' 'app was not running before: failure must not leave it running' {
    Reset-Case @{ failAt=2 }
    $global:St.running = $false
    $res = Invoke-V4ApplyTransaction -Context (New-Context) | Out-Null
    AssertTrue ($global:St.running -eq $false) 'engine started an app that was not running before'
    AssertTrue ($global:St.stopCalls -ge 1) 'recovery was skipped entirely (no stop attempt)'
    'pre-existing stopped state preserved; recovery attempted stop'
}

Check 'F07-10' 'failure after proxy set (owner write fails): proxy restored' {
    Reset-Case @{ failOwner=$true }
    $res = Invoke-V4ApplyTransaction -Context (New-Context)
    AssertTrue (-not $res.ok) 'transaction reported success'
    AssertTrue ($global:St.proxyServer -eq 'old:8080') ('proxy left at ' + $global:St.proxyServer)
    AssertTrue ($global:St.ownerText -eq 'old-owner') 'owner record was not restored'
    AssertTrue ($global:St.ownerRestores -ge 1) 'owner restore was not attempted'
    'proxy and owner restored on late failure'
}

Check 'F07-11' 'error code preserved when recovery succeeds' {
    Reset-Case @{ exitIp='198.51.100.9' }
    $res = Invoke-V4ApplyTransaction -Context (New-Context)
    AssertTrue ($res.exitCode -eq 31) ('exitCode=' + $res.exitCode)
    '31 preserved'
}

Check 'F07-16' 'profile text is read again after the app is stopped' {
    Reset-Case @{ useBuilder=$true }
    $global:St.profileTextAfterStop = 'after-stop-content'
    $ctx = New-Context
    $ctx | Add-Member -NotePropertyName ProfileTextBuilder -NotePropertyValue { $global:St.profileTextAfterStop } -Force
    $res = Invoke-V4ApplyTransaction -Context $ctx
    AssertTrue ($res.ok) ('not ok: ' + $res.error)
    AssertTrue ($global:St.lastProfilesContent -eq 'after-stop-content') 'stale pre-snapshot text was written'
    'post-stop profile text used'
}

Check 'F07-12' 'success clears the transaction journal' {
    Reset-Case @{}
    $res = Invoke-V4ApplyTransaction -Context (New-Context)
    AssertTrue ($res.ok) ('not ok: ' + $res.error)
    AssertTrue ($global:St.journal -eq $false) 'journal remained after a successful transaction'
    'journal cleared on success'
}

Check 'F07-13' 'recovery success clears the transaction journal' {
    Reset-Case @{ failAt=2 }
    $res = Invoke-V4ApplyTransaction -Context (New-Context)
    AssertTrue (-not $res.ok) 'transaction reported success'
    AssertTrue ($res.exitCode -ne 40) ('unexpected recovery exit ' + $res.exitCode)
    AssertTrue ($global:St.journal -eq $false) 'journal remained after a successful recovery'
    'journal cleared after recovery'
}

Check 'F07-14' 'recovery failure leaves the journal for the next run' {
    Reset-Case @{ failAt=2; failRestore=$true }
    $res = Invoke-V4ApplyTransaction -Context (New-Context)
    AssertTrue ($res.exitCode -eq 40) ('exitCode=' + $res.exitCode)
    AssertTrue ($global:St.journal -eq $true) 'journal was cleared despite a failed recovery'
    'journal retained after recovery failure'
}

Check 'F07-15' 'journal write failure aborts before the first live write' {
    Reset-Case @{}
    $global:St.failJournal = $false
    # Context ops are built by New-Context; swap in a throwing journal writer.
    $ctx = New-Context
    $ctx.Ops.WriteJournal = { param($snap,$reason) throw 'journal disk full' }
    $res = Invoke-V4ApplyTransaction -Context $ctx
    AssertTrue (-not $res.ok) 'transaction reported success'
    AssertTrue ($res.exitCode -eq 34) ('exitCode=' + $res.exitCode)
    AssertTrue ($global:St.writeCalls -eq 0) 'a live write happened before the journal was durable'
    'exit 34 before first write'
}

Check 'F07-17' 'post-start proxy drift makes recovery incomplete' {
    foreach ($drift in @(
        @{ enabled = $false; server = 'old:8080' },
        @{ enabled = $true; server = 'other:8081' }
    )) {
        Reset-Case @{ failAt = 2 }
        $ctx = New-Context
        $ctx.Ops.StartApp = {
            param($timeout, $port)
            $started = Op-StartApp $timeout $port
            $global:St.proxyEnabled = $drift.enabled
            $global:St.proxyServer = $drift.server
            return $started
        }.GetNewClosure()
        $res = Invoke-V4ApplyTransaction -Context $ctx
        AssertTrue ($global:St.startCalls -eq 1) 'did not exercise the recovery start'
        AssertTrue ($res.exitCode -eq 40 -and -not $res.restored -and $global:St.journal) (
            'drift incorrectly accepted: exit={0} restored={1} journal={2}' -f $res.exitCode, $res.restored, $global:St.journal)
    }
    'recovery detected enabled and server drift after startup, retained the journal and reported exit 40'
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
