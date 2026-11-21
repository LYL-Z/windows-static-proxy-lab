#Requires -Version 5.1
<#
.SYNOPSIS  Apply the managed proxy config transactionally (proxy_v4).
.DESCRIPTION
  -Init          migrate the current Clash profile into config\settings.json (once, under the lock)
  -Mode          strict (default) | resilient
  -DryRun        generate + validate in temporary storage; no project or client writes
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
    [string]$HopHost = '127.0.0.1', [int]$HopPort = 11119, [int]$MixedPort = 7897,
    [ValidateSet('KeepCurrent','RestorePrevious')][string]$ResolveRepair
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\V4.ps1')
$exit = 0
$lock = $null
$userLock = $null
if (-not $DryRun) {
    $null = Enable-V4ProductionWrites
    if (-not (Start-V4Log 'apply')) { Write-Host 'WARN: evidence log could not be opened; continuing' -ForegroundColor Yellow }
}

function Fail([int]$c, [string]$m) { throw [pscustomobject]@{ code = $c; msg = $m } }

try {
    Write-V4Log ('mode={0} dryRun={1} init={2}' -f $Mode, [bool]$DryRun, [bool]$Init) -Level STEP
    if ($ResolveRepair -and ($DryRun -or $Repair -or $Init)) { Fail 11 '-ResolveRepair must be used separately' }
    if ($Repair -and $DryRun) { Fail 11 '-Repair and -DryRun are mutually exclusive' }
    if ($Init -and $DryRun)   { Fail 11 '-Init and -DryRun are mutually exclusive' }
    if ($Init -and $Repair)   { Fail 11 '-Init and -Repair are mutually exclusive' }
    foreach ($legacyParam in @('StaticPass', 'StaticPassFile')) {
        if ($PSBoundParameters.ContainsKey($legacyParam)) { Fail 11 ('-' + $legacyParam + ' was removed; use -CredentialFile <protected file>') }
    }

    # F09: the lock is acquired BEFORE any settings write, including -Init.
    if (-not $DryRun) {
        $userLock = Enter-V4UserMutationLock
        if (-not $userLock) { Fail 33 'another operation holds the per-user mutation lock' }
        $lock = Enter-V4Lock
        if (-not $lock) { Fail 33 'another apply/rollback holds the lock' }
    }

    # A-08: a previous process may have died after the first live write. Fail closed
    # instead of snapshotting a half-applied tree as the new baseline.
    $pending = Get-V4Journal
    if ($pending) {
        if ($pending.corrupt) { Fail 34 'config\transaction.json is corrupt; inspect it before retrying' }
        Fail 34 ('unfinished transaction; run rollback-v4.ps1 -SnapshotDir ' + [string]$pending.data.snapshot)
    }

    $receipt = Get-V4RepairReceipt
    if ($receipt -and $receipt.invalid) { Fail 34 'unreadable or unsafe repair receipt; inspect its ACL and contents locally' }
    if ($ResolveRepair) {
        if (-not $receipt) { Fail 34 'no interrupted repair is recorded' }
        if ($ResolveRepair -eq 'RestorePrevious') {
            $active = Get-V4SystemProxy
            if (-not $active.enabled -or $active.server -notin @($receipt.target, $receipt.previous) -or
                (Get-V4AutomaticProxyStatus) -ne 'NOT_OBSERVED' -or (Get-V4UiSystemProxy) -ne $true) {
                Fail 32 'proxy selection changed; preserve it and decide whether to acknowledge with KeepCurrent'
            }
            if ($active.server -eq $receipt.target) {
                Set-V4RepairServer -ExpectedServer $receipt.target -NewServer $receipt.previous
            }
            $active = Get-V4SystemProxy
            if (-not $active.enabled -or $active.server -ne $receipt.previous) { Fail 40 'previous proxy target could not be confirmed; receipt retained' }
        }
        Complete-V4RepairReceipt $receipt
        Write-V4Log ('interrupted repair acknowledged: ' + $ResolveRepair + '; application paths remain untested') -Level OK
        return
    }
    if ($receipt) { Fail 34 'interrupted repair; review the current selection before using -ResolveRepair KeepCurrent or RestorePrevious' }

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
    $s = Get-V4Settings -StatusOnly:$Repair
    $p = Get-V4Paths
    if (-not $p.AppData -or -not $p.Core) { Fail 10 'clash paths not found' }

    if ($Repair) {
        if ((Get-V4UiSystemProxy) -ne $true) { Fail 32 'saved Clash system proxy is disabled or unknown; review the intended mode before repair' }
        if ((Get-V4AutomaticProxyStatus) -ne 'NOT_OBSERVED') { Fail 32 'automatic proxy is present or unverified; review Windows proxy selection before repair' }
        $integrity = Get-V4Integrity -Paths $p
        if (-not $integrity.markerOk -or -not $integrity.runtimeMarkerOk) {
            Fail 32 'managed profile or runtime marker could not be verified; review the active profile before repair'
        }
    }

    # ---------- first hop must really proxy ----------
    $hop = Test-V4FirstHop -Port $s.hopPort
    if (-not $hop.ok) { Fail 20 ('first hop not usable: ' + $hop.detail) }
    Write-V4Log ('first hop verified: ' + $hop.detail) -Level OK

    # Repair: re-assert system-proxy ownership without touching configs or restarting.
    if ($Repair) {
        $prev = Get-V4SystemProxy
        $target = '127.0.0.1:' + $s.mixedPort
        if (-not $prev.enabled) { Fail 32 'Windows proxy is disabled or unknown; preserve the current selection' }
        $prevVal = $prev.server
        if ($prevVal -notin @($target, ('127.0.0.1:' + $s.hopPort))) {
            Fail 32 'Windows selected another proxy; review the intended target manually'
        }
        if (-not (Test-V4ClashListener -Port $s.mixedPort -ExpectedCore $p.Core -RequireImagePath)) {
            Fail 32 'expected IPv4 Clash core listener could not be verified; nothing changed'
        }
        Write-V4Log ('repair: observed system proxy = {0}' -f $prevVal) -Level WARN
        $got = Get-V4ExitIp -Proxy ('http://' + $target) -TimeoutSec 5
        if ($got -isnot [string] -or $got -ne $s.host) { Fail 31 'chain HTTPS exit did not match the configured static IPv4; nothing changed' }
        $current = Get-V4SystemProxy
        if ((Get-V4UiSystemProxy) -ne $true -or (Get-V4AutomaticProxyStatus) -ne 'NOT_OBSERVED' -or
            $current.enabled -ne $prev.enabled -or $current.server -ne $prev.server) {
            Fail 32 'saved Clash mode or Windows proxy changed during the probe; review the current state before retrying'
        }
        if (-not (Test-V4ClashListener -Port $s.mixedPort -ExpectedCore $p.Core -RequireImagePath)) {
            Fail 32 'expected IPv4 Clash core listener changed during the probe; nothing changed'
        }
        $currentIntegrity = Get-V4Integrity -Paths $p
        if (-not $currentIntegrity.markerOk -or -not $currentIntegrity.runtimeMarkerOk -or $currentIntegrity.profileHash -ne $integrity.profileHash) {
            Fail 32 'managed profile changed or could not be verified after the probe; review the active profile before repair'
        }
        if ($current.enabled -and $current.server -eq $target) {
            Write-V4Log 'Windows proxy already targets the sampled Clash HTTPS path. Application paths are untested.' -Level OK
            return
        }
        $writeAttempted = $false
        $receipt = New-V4RepairReceipt -Previous $prevVal -Target $target
        try {
            Write-V4Log 'RECOVERING: one attempt to restore the selected local proxy target' -Level STEP
            Set-V4RepairServer -ExpectedServer $prevVal -NewServer $target -WriteAttempted ([ref]$writeAttempted)
            $afterExit = Get-V4ExitIp -Proxy ('http://' + $target) -TimeoutSec 5
            if ($afterExit -isnot [string] -or $afterExit -ne $s.host) {
                Fail 31 'post-write HTTPS exit did not match the configured IPv4'
            }
            $px = Get-V4SystemProxy
            if (-not $px.enabled -or $px.server -ne $target -or (Get-V4UiSystemProxy) -ne $true -or
                (Get-V4AutomaticProxyStatus) -ne 'NOT_OBSERVED' -or
                -not (Test-V4ClashListener -Port $s.mixedPort -ExpectedCore $p.Core -RequireImagePath)) {
                Fail 32 'Windows proxy selection or expected core could not be reverified after the write'
            }
            try { Set-V4Owner -Owner 'clash' -SystemProxy $px.server -Note ('repair; previous=' + $prevVal) }
            catch { Write-V4Log ('repair: owner record failed (proxy is still correct): ' + (Get-V4Redacted $_.Exception.Message)) -Level WARN }
            Complete-V4RepairReceipt $receipt
            Write-V4Log ('VERIFIED_PROXY_TARGET: {0} -> {1}; explicit IPv4 HTTPS matched. Application paths are untested.' -f $prevVal, $px.server) -Level OK
            return
        }
        catch {
            if (-not $writeAttempted) { Complete-V4RepairReceipt $receipt; throw }
            try {
                # A write can commit before the WinINet notification throws.
                # Inspect the resulting selection even on setter failure.
                $now = Get-V4SystemProxy
                if ($now.enabled -and $now.server -eq $target -and
                    (Get-V4UiSystemProxy) -eq $true -and (Get-V4AutomaticProxyStatus) -eq 'NOT_OBSERVED') {
                    Set-V4RepairServer -ExpectedServer $target -NewServer $prevVal
                    $restored = Get-V4SystemProxy
                    if ($restored.enabled -ne $prev.enabled -or $restored.server -ne $prev.server) {
                        throw 'previous Windows proxy values did not match after restore'
                    }
                    Write-V4Log ('repair failed; restored previous system proxy = {0}' -f $prevVal) -Level WARN
                } elseif ($now.enabled -ne $prev.enabled -or $now.server -ne $prevVal) {
                    Write-V4Log 'repair failed; Windows proxy changed independently and was left as observed' -Level WARN
                }
                Complete-V4RepairReceipt $receipt
            }
            catch {
                Write-V4Log ('repair failed and previous proxy could not be verified after restore: ' + (Get-V4Redacted $_.Exception.Message)) -Level ERROR
                Fail 40 'proxy repair failed, and restore of previous settings could not be verified'
            }
            throw
        }
    }

    $ctrl = Get-V4Controller
    if (-not $ctrl.pipe) { Fail 10 'external-controller-pipe not discoverable; start Clash Verge once' }

    $profYaml = Build-V4Profile -S $s -Mode $Mode
    $rtYaml = Build-V4Runtime -S $s -Mode $Mode -Pipe $ctrl.pipe -Secret $ctrl.secret

    # ---------- validate BEFORE touching live files ----------
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $stage = Join-Path $tempRoot ('v4-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage | Out-Null
    try {
        if (-not (Protect-V4Acl -Path $stage)) { Fail 12 'cannot harden staging directory ACL' }
        Write-V4File -Path (Join-Path $stage 'p.yaml') -Content $profYaml
        Write-V4File -Path (Join-Path $stage 'r.yaml') -Content $rtYaml
        $workDir = $p.AppData
        if ($DryRun) {
            $workDir = $stage
            foreach ($asset in @('geoip.dat', 'geosite.dat', 'Country.mmdb', 'ASN.mmdb')) {
                $source = Join-Path $p.AppData $asset
                if (Test-Path -LiteralPath $source -PathType Leaf) { Copy-Item -LiteralPath $source -Destination $stage }
            }
        }
        Test-V4MihomoConfig -ConfigPath (Join-Path $stage 'p.yaml') -WorkDir $workDir | Out-Null
        Test-V4MihomoConfig -ConfigPath (Join-Path $stage 'r.yaml') -WorkDir $workDir | Out-Null
    }
    finally {
        $resolvedStage = [IO.Path]::GetFullPath($stage)
        $tempPrefix = $tempRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        if ($resolvedStage.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedStage -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
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
    if ($userLock) { $userLock.ReleaseMutex(); $userLock.Dispose() }
    exit $exit
}
