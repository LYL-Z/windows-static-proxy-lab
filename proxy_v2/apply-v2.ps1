#Requires -Version 5.1
<#
.SYNOPSIS
  Apply one of the three network modes transactionally.

.DESCRIPTION
  Modes:
    NEXIP   : StarSky first hop + NexIP static proxy, via Mihomo dialer-proxy.
              Clash owns the system proxy (127.0.0.1:7897). Exit = static IP.
    STARSKY : Clash stopped, StarSky owns the system proxy. Exit = StarSky node.
    RAW     : Clash stopped, system proxy cleared. Exit = local ISP.

  Safety model:
    * snapshot -> stage in temp -> `mihomo -t` validate -> atomic replace
    * any post-change verification failure triggers automatic restore
    * the system proxy is only touched AFTER the chain is proven end-to-end
    * credentials are read from the existing profile and never printed

.PARAMETER Profile
  resilient (default): fallback group SOCKS5 -> DIRECT, so a dead first hop
  degrades to direct instead of black-holing traffic.
  strict: no automatic fallback; a dead hop fails loudly.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File apply-v2.ps1 -Mode NEXIP -AcknowledgeCredentialAccess
#>
[CmdletBinding()]
param(
    [ValidateSet('NEXIP', 'STARSKY', 'RAW')][string]$Mode = 'NEXIP',
    [ValidateSet('resilient', 'strict')][string]$Profile = 'resilient',
    [switch]$AcknowledgeCredentialAccess,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'lib\Common.ps1')

$root = $here
$results = Join-Path $root 'test-results'
Start-LogFile (Join-Path $results ("apply-{0}-{1}.log" -f $Mode, (Get-Date -Format 'yyyyMMdd-HHmmss')))

$MIXED_PORT = 7897
$SNAP = $null
$applied = $false
$exitCode = 0

function Fail([int]$code, [string]$msg) {
    Write-Log $msg -Level ERROR
    throw [pscustomobject]@{ AppExitCode = $code; Message = $msg }
}

try {
    Write-Log ("mode={0} profile={1} dryRun={2}" -f $Mode, $Profile, [bool]$DryRun) -Level STEP

    # ---------------------------------------------------------- preflight ---
    $p = Get-ClashPaths
    if (-not $p.AppDataDir) { Fail 10 'Clash Verge config dir not found (is Clash Verge installed?)' }
    if (-not $p.Exe)       { Fail 10 'clash-verge.exe not found' }
    if (-not $p.Core)      { Fail 10 'mihomo core binary not found' }
    if (-not $p.ProfileFile -or -not (Test-Path $p.ProfileFile)) { Fail 10 'active profile YAML not found' }
    Write-Log ("install={0}" -f $p.InstallDir)
    Write-Log ("appdata={0}" -f $p.AppDataDir)
    Write-Log ("profile={0} (uid={1})" -f (Split-Path $p.ProfileFile -Leaf), $p.ProfileUid)

    # dynamic controller channel, preserved from the live/existing runtime config
    $ch = Get-MihomoChannel
    $pipe = $null; $secret = $null
    if ($ch -and $ch.Kind -eq 'pipe') { $pipe = $ch.Target; $secret = $ch.Secret }
    if (-not $pipe) { $pipe = Get-YamlScalar -Path $p.RuntimeFile -Key 'external-controller-pipe' }
    if (-not $secret) { $secret = Get-YamlScalar -Path $p.RuntimeFile -Key 'secret' }
    if (-not $secret) { $secret = 'set-your-secret' }
    Register-Secret $secret
    if (-not $pipe) {
        Fail 10 'mihomo external-controller-pipe not discoverable. Start Clash Verge once (any config), then re-run.'
    }
    Write-Log ("controller pipe detected (len={0})" -f $pipe.Length)

    # ---------------------------------------------------------- Mode: RAW ---
    if ($Mode -eq 'RAW' -or $Mode -eq 'STARSKY') {
        $SNAP = New-StateSnapshot -Root $root
        Write-Log ("snapshot -> {0}" -f $SNAP) -Level OK

        Get-Process -Name 'verge-mihomo', 'clash-verge' -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2

        if ($Mode -eq 'RAW') {
            Clear-SystemProxy
            $px = Get-SystemProxy
            if ($px.Enabled) { Fail 32 'failed to clear system proxy' }
            $exit = Get-NeutralIp -Proxy ''
            Write-Log ("RAW: system proxy cleared; direct egress = {0}" -f $exit) -Level OK
            Write-Log 'RAW: if StarSky tunnel is still up, click "停止加速" in StarSky to return to the local ISP.' -Level WARN
        }
        else {
            $hop = Get-FirstHopConfig -ProfilePath $p.ProfileFile
            if (-not $hop) { Fail 20 'first-hop node not configured in profile' }
            $probe = Test-FirstHop -Port $hop.Port
            if (-not $probe.Ok) { Fail 20 ("StarSky first hop not usable: " + $probe.Detail) }
            Set-SystemProxy -Server ("127.0.0.1:{0}" -f $hop.Port)
            $exit = Get-NeutralIp -Proxy ("http://127.0.0.1:{0}" -f $hop.Port)
            Write-Log ("STARSKY: system proxy -> 127.0.0.1:{0}; egress = {1}" -f $hop.Port, $exit) -Level OK
        }
        Write-Log ("snapshot kept for rollback: {0}" -f $SNAP)
        return
    }

    # --------------------------------------------------------- Mode: NEXIP ---
    if (-not $AcknowledgeCredentialAccess) {
        Fail 11 ('Refusing without -AcknowledgeCredentialAccess: this step reads the stored ' +
                 'static-proxy password from your Clash profile to rebuild the config. ' +
                 'The value is never printed, logged or exported.')
    }

    $cred = Get-ProfileCredential -ProfilePath $p.ProfileFile
    if (-not $cred) { Fail 12 'no username/password found in the active profile; configure the NexIP node first' }
    Write-Log ("credentials loaded from profile (user_len={0} pass_len={1})" -f $cred.Username.Length, $cred.Password.Length) -Level OK

    $hopCfg = Get-FirstHopConfig -ProfilePath $p.ProfileFile
    $hopPort = if ($hopCfg) { $hopCfg.Port } else { 11119 }
    $staticHost = Get-StaticTarget -ProfilePath $p.ProfileFile
    if (-not $staticHost) { Fail 12 'static proxy server/port not found in profile' }
    Write-Log ("static target {0}:{1}  first hop 127.0.0.1:{2}" -f $staticHost.Host, $staticHost.Port, $hopPort)

    # 1) first hop must actually proxy, not merely listen
    $probe = Test-FirstHop -Port $hopPort
    if (-not $probe.Ok) { Fail 20 ("first hop (StarSky 127.0.0.1:{0}) not usable: {1}. Open StarSky and start acceleration." -f $hopPort, $probe.Detail) }
    Write-Log ("first hop verified: {0}" -f $probe.Detail) -Level OK

    # 2) snapshot (never on a dry run)
    if (-not $DryRun) {
        $SNAP = New-StateSnapshot -Root $root
        Write-Log ("snapshot -> {0}" -f $SNAP) -Level OK
    }

    # 3) build content
    $groupYaml = if ($Profile -eq 'resilient') {
@"
proxy-groups:
  - name: "PROXY"
    type: fallback
    url: "http://www.gstatic.com/generate_204"
    interval: 300
    lazy: true
    timeout: 5000
    proxies:
      - "US-WA-SOCKS5"
      - "DIRECT"
"@
    }
    else {
@"
proxy-groups:
  - name: "PROXY"
    type: select
    proxies:
      - "US-WA-SOCKS5"
      - "DIRECT"
"@
    }

    $profileYaml = @"
# NexIP static proxy + StarSky first hop  (generated by apply-v2.ps1)
# mode=$Mode profile=$Profile  generated=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
mixed-port: $MIXED_PORT
allow-lan: false
mode: rule
log-level: info
ipv6: false
unified-delay: true
find-process-mode: "off"
tcp-concurrent: true

proxies:
  - name: "STAR-FIRSTHOP"
    type: http
    server: 127.0.0.1
    port: $hopPort
  - name: "US-WA-SOCKS5"
    type: socks5
    server: $($staticHost.Host)
    port: $($staticHost.Port)
    username: "$($cred.Username)"
    password: "$($cred.Password)"
    udp: false
    dialer-proxy: "STAR-FIRSTHOP"

$groupYaml
rules:
  - MATCH,PROXY
"@

    $runtimeYaml = @"
# Generated by Clash Verge (managed by apply-v2.ps1, profile=$Profile)
mode: rule
mixed-port: $MIXED_PORT
allow-lan: false
log-level: info
ipv6: true
unified-delay: true
find-process-mode: "off"
tcp-concurrent: true
secret: $secret
profile:
  store-selected: true
external-controller-pipe: $pipe
external-controller-cors:
  allow-private-network: true
  allow-origins:
  - tauri://localhost
  - http://tauri.localhost
  - https://yacd.metacubex.one
  - https://metacubex.github.io
  - https://board.zash.run.place
tun:
  enable: false
  stack: mips
  auto-route: true
  strict-route: false
  auto-detect-interface: true
  dns-hijack:
  - any:53
proxies:
- name: "STAR-FIRSTHOP"
  type: http
  server: 127.0.0.1
  port: $hopPort
- name: "US-WA-SOCKS5"
  type: socks5
  server: $($staticHost.Host)
  port: $($staticHost.Port)
  username: "$($cred.Username)"
  password: "$($cred.Password)"
  udp: false
  dialer-proxy: "STAR-FIRSTHOP"
$groupYaml
rules:
- MATCH,PROXY
"@

    if ($DryRun) {
        Write-Log 'DRY RUN: validation only, nothing replaced' -Level STEP
        $tmp1 = Join-Path $env:TEMP ('dry-profile-' + [guid]::NewGuid().ToString('N') + '.yaml')
        $tmp2 = Join-Path $env:TEMP ('dry-runtime-' + [guid]::NewGuid().ToString('N') + '.yaml')
        Write-TextFile -Path $tmp1 -Content $profileYaml
        Write-TextFile -Path $tmp2 -Content $runtimeYaml
        # M7: temp files hold the plaintext credential - always clean them up
        try {
            Test-MihomoConfig -ConfigPath $tmp1 -WorkDir $p.AppDataDir | Out-Null
            Test-MihomoConfig -ConfigPath $tmp2 -WorkDir $p.AppDataDir | Out-Null
        }
        finally {
            Remove-Item $tmp1, $tmp2 -Force -ErrorAction SilentlyContinue
        }
        Write-Log 'DRY RUN OK: both documents pass `mihomo -t`' -Level OK
        return
    }

    # 4) validate BEFORE touching live files
    $stageDir = Join-Path $env:TEMP ('pxv2-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stageDir -Force | Out-Null
    $stageProfile = Join-Path $stageDir 'profile.yaml'
    $stageRuntime = Join-Path $stageDir 'runtime.yaml'
    Write-TextFile -Path $stageProfile -Content $profileYaml
    Write-TextFile -Path $stageRuntime -Content $runtimeYaml
    try {
        Test-MihomoConfig -ConfigPath $stageProfile -WorkDir $p.AppDataDir | Out-Null
        Test-MihomoConfig -ConfigPath $stageRuntime -WorkDir $p.AppDataDir | Out-Null
        Write-Log 'staged configs pass mihomo -t' -Level OK
    }
    finally {
        Remove-Item $stageDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # 5) transactional replace
    Invoke-AtomicReplace -TargetPath $p.ProfileFile -Content $profileYaml -Validator {
        param($f) Test-MihomoConfig -ConfigPath $f -WorkDir $p.AppDataDir | Out-Null
    } | Out-Null
    Invoke-AtomicReplace -TargetPath $p.RuntimeFile -Content $runtimeYaml -Validator {
        param($f) Test-MihomoConfig -ConfigPath $f -WorkDir $p.AppDataDir | Out-Null
    } | Out-Null
    Write-Log 'configs replaced atomically' -Level OK
    $applied = $true

    # 6) restart + wait
    if (-not (Restart-ClashVerge -TimeoutSec 45 -Port $MIXED_PORT)) {
        Restore-StateSnapshot -SnapshotDir $SNAP | Out-Null
        Restart-ClashVerge -TimeoutSec 30 -Port $MIXED_PORT | Out-Null
        Fail 30 "Clash Verge did not listen on $MIXED_PORT within 45s; previous config restored"
    }
    Write-Log ("Clash Verge listening on {0}" -f $MIXED_PORT) -Level OK

    # 7) end-to-end verification BEFORE the system proxy is changed
    $expected = $staticHost.Host
    $got = $null
    for ($i = 1; $i -le 3; $i++) {
        $got = Get-NeutralIp -Proxy ("socks5h://127.0.0.1:{0}" -f $MIXED_PORT) -TimeoutSec 25
        if ($got -eq $expected) { break }
        $shown = if ($got) { $got } else { 'null' }
        Write-Log ("chain attempt {0}/3 -> {1}" -f $i, $shown) -Level WARN
        Start-Sleep -Seconds 2
    }
    if ($got -ne $expected) {
        Restore-StateSnapshot -SnapshotDir $SNAP | Out-Null
        Restart-ClashVerge -TimeoutSec 30 -Port $MIXED_PORT | Out-Null
        Fail 31 ("chain verification failed: exit {0}, expected {1}. Previous config restored." -f $got, $expected)
    }
    Write-Log ("chain verified: exit IP = {0}" -f $got) -Level OK

    # 8) only now take over the system proxy
    Set-SystemProxy -Server ("127.0.0.1:{0}" -f $MIXED_PORT)
    $px = Get-SystemProxy
    if (-not $px.Enabled -or $px.Server -ne ("127.0.0.1:{0}" -f $MIXED_PORT)) {
        Restore-StateSnapshot -SnapshotDir $SNAP | Out-Null
        Fail 32 ("system proxy could not be set (now: enabled={0} server={1})" -f $px.Enabled, $px.Server)
    }
    $viaSys = Get-NeutralIp -Proxy ("http://127.0.0.1:{0}" -f $MIXED_PORT)
    Write-Log ("system proxy -> {0}; egress via chain = {1}" -f $px.Server, $viaSys) -Level OK

    # 9) ACL hardening
    foreach ($t in @($p.ProfileFile, $p.RuntimeFile, $SNAP)) {
        if (Protect-PrivatePath -Path $t) { Write-Log ("ACL restricted: {0}" -f (Split-Path $t -Leaf)) }
        else { Write-Log ("ACL restriction skipped (needs ownership): {0}" -f (Split-Path $t -Leaf)) -Level WARN }
    }

    Write-Log ("DONE. mode=NEXIP profile={0} exit={1} snapshot={2}" -f $Profile, $got, $SNAP) -Level OK
    $exitCode = 0
}
catch {
    # H3: a failure between the two atomic replaces (or anywhere after them) used to
    # leave a half-applied config with no restore. Any post-replace failure restores.
    if ($applied -and $SNAP) {
        Write-Log 'mid-transaction failure after config replacement; restoring snapshot' -Level WARN
        try { Restore-StateSnapshot -SnapshotDir $SNAP | Out-Null } catch { Write-Log ('restore failed: ' + (Get-Redacted $_.Exception.Message)) -Level ERROR }
        try { Restart-ClashVerge -TimeoutSec 30 -Port $MIXED_PORT | Out-Null } catch { }
    }
    $ec = $_.TargetObject
    if ($ec -and $ec.AppExitCode) { $exitCode = [int]$ec.AppExitCode; Write-Log $ec.Message -Level ERROR }
    else { $exitCode = 1; Write-Log ("unexpected failure: " + (Get-Redacted $_.Exception.Message)) -Level ERROR }
}
finally {
    # helper functions appended by callers of this script
    exit $exitCode
}
