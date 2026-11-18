#Requires -Version 5.1
<#
.SYNOPSIS  Apply the managed proxy config transactionally (proxy_v4).
.DESCRIPTION
  -Init          migrate the current Clash profile into config\settings.json (once)
  -Mode          resilient (default) | strict
  -DryRun        generate + validate only, change nothing
  Exit: 0 ok, 11 settings, 20 first hop, 30 start timeout, 31 chain verify,
        32 system proxy, 33 lock busy, 40 restore failed.
#>
[CmdletBinding()]
param(
    [switch]$Init,
    [ValidateSet('resilient','strict')][string]$Mode = 'strict',
    [switch]$DryRun,
    [switch]$Repair,
    [string]$StaticHost, [int]$StaticPort = 0, [string]$StaticUser, [string]$StaticPass,
    [string]$HopHost = '127.0.0.1', [int]$HopPort = 11119, [int]$MixedPort = 7897
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\V4.ps1')
Start-V4Log 'apply'
$exit = 0
$snap = $null
$applied = $false

function Fail([int]$c, [string]$m) { throw [pscustomobject]@{ code = $c; msg = $m } }

try {
    Write-V4Log ("mode={0} dryRun={1} init={2}" -f $Mode, [bool]$DryRun, [bool]$Init) -Level STEP

    # ---------- INIT: one-time migration into the JSON store ----------
    if ($Init) {
        if ($StaticHost -and $StaticUser -and $StaticPass) {
            Save-V4Settings -Host_ $StaticHost -Port $(if($StaticPort){$StaticPort}else{9506}) -Username $StaticUser -Password $StaticPass -HopHost $HopHost -HopPort $HopPort -MixedPort $MixedPort
            Write-V4Log 'settings created from explicit parameters' -Level OK
            $Init = $false
        }
        else {
            $p = Get-V4Paths
            if (-not $p.RuntimeFile -or -not (Test-Path $p.RuntimeFile)) { Fail 11 'no clash runtime config to migrate from' }
            $t = Read-V4File $p.RuntimeFile
            # strict, single-purpose extraction of exactly one socks5 node
            $blocks = [regex]::Matches($t, '(?ms)^-\s+name:\s*(?<name>[^\r\n]+)(?<body>.*?)(?=^-\s+name:|\z)')
            $cands = @()
            foreach ($b in $blocks) {
                $body = $b.Groups['body'].Value
                if ($body -notmatch '(?m)^\s*type:\s*socks5\s*$') { continue }
                $get = { param($k) if ($body -match ('(?m)^\s*' + $k + ':\s*(?<v>[^\r\n#]+)')) { return $Matches['v'].Trim().Trim('"').Trim("'") } return $null }
                $cands += [pscustomobject]@{
                    host = (& $get 'server'); port = (& $get 'port')
                    user = (& $get 'username'); pass = (& $get 'password')
                }
            }
            if ($cands.Count -ne 1) { Fail 11 ("expected exactly 1 socks5 node, found {0}; pass -StaticHost/-StaticUser/-StaticPass explicitly" -f $cands.Count) }
            $c = $cands[0]
            if ($c.host -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { Fail 11 ("server is not IPv4: {0}" -f $c.host) }
            if (-not $c.port -or [int]$c.port -lt 1 -or [int]$c.port -gt 65535) { Fail 11 'port invalid' }
            if (-not $c.user -or -not $c.pass) { Fail 11 'credentials missing in profile' }
            Save-V4Settings -Host_ $c.host -Port ([int]$c.port) -Username $c.user -Password $c.pass -HopHost $HopHost -HopPort $HopPort -MixedPort $MixedPort
            Write-V4Log ("migrated target {0}:{1} (credentials length-verified only)" -f $c.host, $c.port) -Level OK
            $Init = $false
        }
    }

    if (-not (Test-Path $script:SettingsPath)) { Fail 11 'config\settings.json missing; run with -Init first' }
    if (-not (Enter-V4Lock)) { Fail 33 'another apply/rollback holds the lock' }
    try {
        $s = Get-V4Settings
        $p = Get-V4Paths
        if (-not $p.AppData -or -not $p.Core) { Fail 10 'clash paths not found' }

        # ---------- first hop must really proxy ----------
        $hop = Test-V4FirstHop -Port $s.hopPort
        if (-not $hop.ok) { Fail 20 ("first hop not usable: " + $hop.detail) }
        Write-V4Log ("first hop verified: " + $hop.detail) -Level OK

        # Repair: re-assert system-proxy ownership without touching configs or restarting.
        if ($Repair) {
            $prev = Get-V4SystemProxy
            $prevVal = if ($prev.enabled) { $prev.server } else { 'off' }
            Write-V4Log ("repair: observed system proxy = {0}" -f $prevVal) -Level WARN
            $got = Get-V4ExitIp -Proxy ('socks5h://127.0.0.1:' + $s.mixedPort)
            if ($got -ne $s.host) { Fail 31 ("chain unhealthy before repair: exit {0}" -f $got) }
            Set-V4SystemProxy -Server ('127.0.0.1:' + $s.mixedPort)
            $px = Get-V4SystemProxy
            if (-not $px.enabled -or $px.server -ne ('127.0.0.1:' + $s.mixedPort)) { Fail 32 'repair could not set system proxy' }
            Set-V4Owner -Owner 'clash' -SystemProxy $px.server -Note ("repair; previous=" + $prevVal)
            Write-V4Log ("REPAIR OK: {0} -> {1}; exit {2}" -f $prevVal, $px.server, $got) -Level OK
            return
        }
        $ctrl = Get-V4Controller
        if (-not $ctrl.pipe) { Fail 10 'external-controller-pipe not discoverable; start Clash Verge once' }

        $profYaml = Build-V4Profile -S $s -Mode $Mode
        $rtYaml   = Build-V4Runtime -S $s -Mode $Mode -Pipe $ctrl.pipe -Secret $ctrl.secret

        # ---------- validate BEFORE touching live files ----------
        $stage = Join-Path $env:TEMP ('v4-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        try {
            Write-V4File -Path (Join-Path $stage 'p.yaml') -Content $profYaml
            Write-V4File -Path (Join-Path $stage 'r.yaml') -Content $rtYaml
            Test-V4MihomoConfig -ConfigPath (Join-Path $stage 'p.yaml') -WorkDir $p.AppData | Out-Null
            Test-V4MihomoConfig -ConfigPath (Join-Path $stage 'r.yaml') -WorkDir $p.AppData | Out-Null
        }
        finally { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
        Write-V4Log 'staged configs pass mihomo -t' -Level OK

        if ($DryRun) { Write-V4Log 'DRY RUN: nothing replaced' -Level OK; return }

        # ---------- snapshot (stops the app first => consistent state) ----------
        $snap = New-V4Snapshot -Reason ('apply-' + $Mode)
        Write-V4Log ("snapshot -> {0}" -f $snap) -Level OK

        $profTarget = Join-Path $p.ProfilesDir 'v4-managed.yaml'
        # M8: register a DEDICATED local profile instead of overwriting the subscription file
        $uid = 'V4Mngd0001'
        $pfile = Join-Path $p.AppData 'profiles.yaml'
        $pt = Read-V4File $pfile
        if (-not $pt) { Fail 10 'profiles.yaml unreadable' }
        if ($pt -notmatch ('uid:\s*' + $uid)) {
            $epoch = [int](New-TimeSpan -Start ([datetime]'1970-01-01') -End (Get-Date)).TotalSeconds
            $pt = $pt.TrimEnd() + "`n- uid: $uid`n  type: local`n  name: V4-Managed`n  file: v4-managed.yaml`n  updated: $epoch`n"
        }
        $pt = [regex]::Replace($pt, '(?m)^current:\s*\S+', ('current: ' + $uid))
        Set-V4Atomic -TargetPath $pfile -Content $pt -Validator { param($f) if ((Read-V4File $f) -notmatch '(?m)^current:\s*\S+') { throw 'profiles.yaml has no current entry' } } | Out-Null
        Write-V4Log 'dedicated local profile registered; subscription profile untouched' -Level OK
        $val = { param($f) Test-V4MihomoConfig -ConfigPath $f -WorkDir $p.AppData | Out-Null }
        Set-V4Atomic -TargetPath $profTarget -Content $profYaml -Validator $val | Out-Null
        Set-V4Atomic -TargetPath $p.RuntimeFile -Content $rtYaml -Validator $val | Out-Null
        $applied = $true
        Write-V4Log 'configs replaced atomically (dedicated v4-managed profile)' -Level OK

        if (-not (Start-V4Clash -TimeoutSec 45 -Port $s.mixedPort)) { Fail 30 'Clash did not listen on the mixed port within 45s' }
        Write-V4Log ("core listening on {0}" -f $s.mixedPort) -Level OK

        $got = $null
        for ($i = 1; $i -le 3; $i++) {
            $got = Get-V4ExitIp -Proxy ('socks5h://127.0.0.1:' + $s.mixedPort)
            if ($got -eq $s.host) { break }
            Start-Sleep -Seconds 2
        }
        if ($got -ne $s.host) { Fail 31 ("chain exit {0} != {1}" -f $got, $s.host) }
        Write-V4Log ("chain verified: exit {0}" -f $got) -Level OK

        Set-V4SystemProxy -Server ('127.0.0.1:' + $s.mixedPort)
        $px = Get-V4SystemProxy
        if (-not $px.enabled -or $px.server -ne ('127.0.0.1:' + $s.mixedPort)) { Fail 32 ('system proxy not set: ' + $px.server) }
        Set-V4Owner -Owner 'clash' -SystemProxy ('127.0.0.1:' + $s.mixedPort) -Note ('mode=' + $Mode)
        Protect-V4Acl -Path $profTarget | Out-Null
        Protect-V4Acl -Path $p.RuntimeFile | Out-Null
        Write-V4Log ("DONE exit={0} snapshot={1}" -f $got, $snap) -Level OK
    }
    finally { Exit-V4Lock }
}
catch {
    $tc = $_.TargetObject
    if ($tc -and $tc.code) { $exit = [int]$tc.code; Write-V4Log $tc.msg -Level ERROR }
    else { $exit = 1; Write-V4Log ('unexpected: ' + (Get-V4Redacted $_.Exception.Message)) -Level ERROR }
    if ($applied -and $snap) {
        Write-V4Log 'mid-transaction failure; restoring snapshot' -Level WARN
        try { Restore-V4Snapshot -SnapshotDir $snap | Out-Null; Start-V4Clash -TimeoutSec 30 | Out-Null }
        catch { Write-V4Log ('restore failed: ' + (Get-V4Redacted $_.Exception.Message)) -Level ERROR; $exit = 40 }
    }
}
finally { exit $exit }
