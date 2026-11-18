#Requires -Version 5.1
<#
.SYNOPSIS  Apply the managed proxy config transactionally (proxy_v4).
.DESCRIPTION
  -Init          migrate the current Clash profile into config\settings.json (once, under the lock)
  -Mode          strict (default) | resilient
  -DryRun        generate + validate only, change nothing
  -Repair        re-assert system-proxy ownership without touching configs
  Exit: 0 ok, 10 paths, 11 settings, 12 ACL, 20 first hop, 30 start timeout,
        31 chain verify, 32 system proxy, 33 lock busy, 34 unfinished transaction,
        40 restore failed.
#>
[CmdletBinding()]
param(
    [switch]$Init,
    [ValidateSet('resilient','strict')][string]$Mode = 'strict',
    [switch]$DryRun,
    [switch]$Repair,
    [string]$StaticHost, [int]$StaticPort = 0, [string]$StaticUser, [string]$CredentialFile,
    [string]$StaticPass, [string]$StaticPassFile,
    [string]$HopHost = '127.0.0.1', [int]$HopPort = 11119, [int]$MixedPort = 7897
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\V4.ps1')
$null = Enable-V4ProductionWrites
$exit = 0
$lock = $null
$logOk = Start-V4Log 'apply'
if (-not $logOk) { Write-Host 'WARN: evidence log could not be opened; continuing' -ForegroundColor Yellow }

function Fail([int]$c, [string]$m) { throw [pscustomobject]@{ code = $c; msg = $m } }

try {
    Write-V4Log ('mode={0} dryRun={1} init={2}' -f $Mode, [bool]$DryRun, [bool]$Init) -Level STEP
    if ($Repair -and $DryRun) { Fail 11 '-Repair and -DryRun are mutually exclusive' }
    if ($Init -and $DryRun)   { Fail 11 '-Init and -DryRun are mutually exclusive' }
    if ($Init -and $Repair)   { Fail 11 '-Init and -Repair are mutually exclusive' }
    foreach ($legacyParam in @('StaticPass', 'StaticPassFile')) {
        if ($PSBoundParameters.ContainsKey($legacyParam)) { Fail 11 ('-' + $legacyParam + ' was removed; use -CredentialFile <protected file>') }
    }

    # F09: the lock is acquired BEFORE any settings write, including -Init.
    $lock = Enter-V4Lock
    if (-not $lock) { Fail 33 'another apply/rollback holds the lock' }

    # A-08: a previous process may have died after the first live write. Fail closed
    # instead of snapshotting a half-applied tree as the new baseline.
    $pending = Get-V4Journal
    if ($pending) {
        if ($pending.corrupt) { Fail 34 'config\transaction.json is corrupt; inspect it before retrying' }
        Fail 34 ('unfinished transaction; run rollback-v4.ps1 -SnapshotDir ' + [string]$pending.data.snapshot)
    }

    if ($Init) {
        $staticPass = $null
        if ($CredentialFile) {
            if (-not (Test-Path -LiteralPath $CredentialFile)) { Fail 11 'credential file not found' }
            if (-not (Test-V4AclHardened -Path $CredentialFile -Allowed (Get-V4AllowedSidSet))) { Fail 11 'credential file ACL is not hardened' }
            $staticPass = Read-V4File $CredentialFile
            if ($null -ne $staticPass) { $staticPass = $staticPass.TrimEnd([char[]]@([char]13, [char]10)) }
        }
        $explicit = @{
            host = $StaticHost; port = $StaticPort; user = $StaticUser; pass = $staticPass
            hopHost = $HopHost; hopPort = $HopPort; mixedPort = $MixedPort
        }
        $initPaths = Get-V4Paths
        $initResult = Invoke-V4Init -Paths $initPaths -Explicit $explicit -Save {
            param($h, $pt, $u, $pw, $hh, $hp, $mp)
            Save-V4Settings -Host_ $h -Port $pt -Username $u -Password $pw -HopHost $hh -HopPort $hp -MixedPort $mp
        } -Log { param($m, $l) Write-V4Log $m -Level $l }
        Write-V4Log ('init complete: source=' + $initResult.source) -Level OK
        $Init = $false
    }

    if (-not (Test-Path -LiteralPath $script:SettingsPath)) { Fail 11 'config\settings.json missing; run with -Init first' }
    $s = Get-V4Settings
    $p = Get-V4Paths
    if (-not $p.AppData -or -not $p.Core) { Fail 10 'clash paths not found' }

    # ---------- first hop must really proxy ----------
    $hop = Test-V4FirstHop -Port $s.hopPort
    if (-not $hop.ok) { Fail 20 ('first hop not usable: ' + $hop.detail) }
    Write-V4Log ('first hop verified: ' + $hop.detail) -Level OK

    # Repair: re-assert system-proxy ownership without touching configs or restarting.
    if ($Repair) {
        $prev = Get-V4SystemProxy
        $prevVal = if ($prev.enabled) { $prev.server } else { 'off' }
        Write-V4Log ('repair: observed system proxy = {0}' -f $prevVal) -Level WARN
        try {
            $got = Get-V4ExitIp -Proxy ('socks5h://127.0.0.1:' + $s.mixedPort)
            if ($got -ne $s.host) { Fail 31 ('chain unhealthy before repair: exit {0}' -f $got) }
            Set-V4SystemProxy -Server ('127.0.0.1:' + $s.mixedPort)
            $px = Get-V4SystemProxy
            if (-not $px.enabled -or $px.server -ne ('127.0.0.1:' + $s.mixedPort)) { Fail 32 'repair could not set system proxy' }
            try { Set-V4Owner -Owner 'clash' -SystemProxy $px.server -Note ('repair; previous=' + $prevVal) }
            catch { Write-V4Log ('repair: owner record failed (proxy is still correct): ' + (Get-V4Redacted $_.Exception.Message)) -Level WARN }
            Write-V4Log ('REPAIR OK: {0} -> {1}; exit {2}' -f $prevVal, $px.server, $got) -Level OK
            return
        }
        catch {
            try {
                if ($prev.enabled) { Set-V4SystemProxy -Server $prev.server } else { Clear-V4SystemProxy }
                Write-V4Log ('repair failed; restored previous system proxy = {0}' -f $prevVal) -Level WARN
            }
            catch { Write-V4Log ('repair failed AND previous proxy could not be restored: ' + (Get-V4Redacted $_.Exception.Message)) -Level ERROR }
            throw
        }
    }

    $ctrl = Get-V4Controller
    if (-not $ctrl.pipe) { Fail 10 'external-controller-pipe not discoverable; start Clash Verge once' }

    $profYaml = Build-V4Profile -S $s -Mode $Mode
    $rtYaml = Build-V4Runtime -S $s -Mode $Mode -Pipe $ctrl.pipe -Secret $ctrl.secret

    # ---------- validate BEFORE touching live files ----------
    $stage = Join-Path $env:TEMP ('v4-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    if (-not (Protect-V4Acl -Path $stage)) { Fail 12 'cannot harden staging directory ACL' }
    try {
        Write-V4File -Path (Join-Path $stage 'p.yaml') -Content $profYaml
        Write-V4File -Path (Join-Path $stage 'r.yaml') -Content $rtYaml
        Test-V4MihomoConfig -ConfigPath (Join-Path $stage 'p.yaml') -WorkDir $p.AppData | Out-Null
        Test-V4MihomoConfig -ConfigPath (Join-Path $stage 'r.yaml') -WorkDir $p.AppData | Out-Null
    }
    finally { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
    Write-V4Log 'staged configs pass mihomo -t' -Level OK

    if ($DryRun) { Write-V4Log 'DRY RUN: nothing replaced' -Level OK; return }

    # ---------- compute the registry text BEFORE stopping the app ----------
    $profTarget = Join-Path $p.ProfilesDir 'v4-managed.yaml'
    $uid = 'V4Mngd0001'
    $pfile = Join-Path $p.AppData 'profiles.yaml'
    $pt = Read-V4File $pfile
    if (-not $pt) { Fail 10 'profiles.yaml unreadable' }
    $epoch = [int]([datetime]::UtcNow - [datetime]'1970-01-01').TotalSeconds
    $pt = Update-V4ProfileText -Text $pt -Uid $uid -Epoch $epoch
    Test-V4ProfileText -Text $pt -Uid $uid | Out-Null
    $profileValidator = { param($f) Test-V4ProfileText -Text (Read-V4File $f) -Uid $uid | Out-Null }.GetNewClosure()
    $runtimeValidator = { param($f) Test-V4MihomoConfig -ConfigPath $f -WorkDir $p.AppData | Out-Null }.GetNewClosure()
    $profileTextBuilder = {
        $fresh = Read-V4File $pfile
        if (-not $fresh) { throw [pscustomobject]@{ code = 10; msg = 'profiles.yaml unreadable after snapshot' } }
        $freshEpoch = [int]([datetime]::UtcNow - [datetime]'1970-01-01').TotalSeconds
        $freshText = Update-V4ProfileText -Text $fresh -Uid $uid -Epoch $freshEpoch
        Test-V4ProfileText -Text $freshText -Uid $uid | Out-Null
        return $freshText
    }.GetNewClosure()

    $ops = [pscustomobject]@{
        Snapshot = ({ param($reason) New-V4Snapshot -Reason $reason -Port $s.mixedPort }).GetNewClosure()
        Restore = ({ param($d) Restore-V4Snapshot -SnapshotDir $d -NoProcessControl | Out-Null }).GetNewClosure()
        WriteAtomic = { param($t, $c, $v) Set-V4Atomic -TargetPath $t -Content $c -Validator $v | Out-Null }
        StartApp = ({ param($timeout, $port) Start-V4Clash -TimeoutSec $timeout -Port $port }).GetNewClosure()
        StopApp = ({ param($port) Stop-V4Clash -Port $port | Out-Null }).GetNewClosure()
        IsAppRunning = { (Get-V4AppPids).Count -gt 0 }
        GetExitIp = { param($proxy) Get-V4ExitIp -Proxy $proxy }
        SetSystemProxy = { param($server) Set-V4SystemProxy -Server $server }
        ClearSystemProxy = { Clear-V4SystemProxy }
        GetSystemProxy = { Get-V4SystemProxy }
        SetOwner = ({ param($server, $note) Set-V4Owner -Owner 'clash' -SystemProxy $server -Note $note }).GetNewClosure()
        GetOwnerText = { Get-V4OwnerText }
        RestoreOwner = { param($text) Restore-V4OwnerText -Text $text }
        ProtectAcl = { param($path) Protect-V4Acl -Path $path }
        WriteJournal = { param($snap, $reason) Write-V4Journal -SnapshotDir $snap -Reason $reason }
        ClearJournal = { Clear-V4Journal }
        Log = { param($m, $l) Write-V4Log $m -Level $l }
    }

    $ctx = [pscustomobject]@{
        Reason = ('apply-' + $Mode)
        Mode = $Mode
        Settings = $s
        Paths = [pscustomobject]@{ ProfilesFile = $pfile; ProfileFile = $profTarget; RuntimeFile = $p.RuntimeFile }
        ProfileText = $pt
        ProfileTextBuilder = $profileTextBuilder
        ProfileYaml = $profYaml
        RuntimeYaml = $rtYaml
        ProfileValidator = $profileValidator
        RuntimeValidator = $runtimeValidator
        Redact = { param($m) Get-V4Redacted $m }
        Ops = $ops
    }

    $res = Invoke-V4ApplyTransaction -Context $ctx
    if (-not $res.ok) {
        $exit = [int]$res.exitCode
        Write-V4Log ('FAILED {0}: {1}' -f $exit, $res.error) -Level ERROR
        return
    }
    $exit = 0
    Write-V4Log ('DONE exit={0} snapshot={1}' -f $s.host, $res.snapshot) -Level OK
}
catch {
    $tc = $_.TargetObject
    if ($tc -and $tc.code) { $exit = [int]$tc.code; Write-V4Log ([string]$tc.msg) -Level ERROR }
    else { $exit = 1; Write-V4Log ('unexpected: ' + (Get-V4Redacted $_.Exception.Message)) -Level ERROR }
}
finally {
    if ($lock) { $null = Exit-V4Lock $lock }
    exit $exit
}