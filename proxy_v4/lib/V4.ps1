#Requires -Version 5.1
<#
  V4.ps1 - proxy_v4 engine (PowerShell 5.1, non-elevated, ASCII-only source).

  Design decisions that close the V3 review findings:
    * settings are JSON (native parser) -> no hand-written YAML parsing (M5/M6)
    * the proxy password is DPAPI-encrypted at rest in our own store
    * a single lock file serialises apply/rollback (M9)
    * "stopped" means verified absence of process + free port (M10)
    * snapshots are taken with the app stopped and are hashed from the COPIES (M3)
    * an owner record makes system-proxy ownership explicit (H4)
    * generated configs carry a marker so an overwrite is detectable (M8)
#>

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$script:Root        = Split-Path -Parent $PSScriptRoot
$script:ConfigDir   = Join-Path $script:Root 'config'
$script:BackupDir   = Join-Path $script:Root 'backup'
$script:SettingsPath = Join-Path $script:ConfigDir 'settings.json'
$script:OwnerPath    = Join-Path $script:ConfigDir 'owner.json'
$script:LockPath     = Join-Path $script:ConfigDir '.lock'
$script:Marker       = '# proxy_v4 managed - do not edit by hand'
$script:Secrets      = New-Object System.Collections.Generic.List[string]
$script:LogFile      = $null

foreach ($d in @($script:ConfigDir, $script:BackupDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ------------------------------------------------------------------ logging --
function Register-V4Secret { param([string]$Value) if ($Value -and -not $script:Secrets.Contains($Value)) { $script:Secrets.Add($Value) } }

function Get-V4Redacted {
    param([string]$Text)
    if (-not $Text) { return $Text }
    foreach ($s in $script:Secrets) { if ($s -and $s.Length -ge 4) { $Text = $Text.Replace($s, '***') } }
    $Text = [regex]::Replace($Text, '(?i)(password\s*[:=]\s*)"?[^\s",\}]+', '$1"***"')
    $Text = [regex]::Replace($Text, '(?i)(Basic\s+)([A-Za-z0-9+/=]{8,})', '$1***')
    return $Text
}

function Write-V4Log {
    param([string]$Message, [ValidateSet('INFO','OK','WARN','ERROR','STEP')][string]$Level = 'INFO')
    $m = Get-V4Redacted $Message
    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $m
    $color = switch ($Level) { 'OK' {'Green'} 'WARN' {'Yellow'} 'ERROR' {'Red'} 'STEP' {'Cyan'} default {'Gray'} }
    Write-Host $line -ForegroundColor $color
    if ($script:LogFile) { try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch { } }
}

function Start-V4Log {
    param([string]$Name)
    $dir = Join-Path $script:Root 'evidence'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $script:LogFile = Join-Path $dir ('{0}-{1}.log' -f $Name, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Add-Content -LiteralPath $script:LogFile -Value ("# proxy_v4 {0}" -f (Get-Date -Format 's')) -Encoding UTF8
}

# --------------------------------------------------------------- primitives --
function Write-V4File { param([string]$Path, [string]$Content) [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false))) }
function Read-V4File  { param([string]$Path) if (Test-Path -LiteralPath $Path) { return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) } return $null }

function Protect-V4Secret {
    param([string]$Plain)
    $s = ConvertTo-SecureString -String $Plain -AsPlainText -Force
    return (ConvertFrom-SecureString -SecureString $s)
}

function Unprotect-V4Secret {
    param([string]$Enc)
    $s = ConvertTo-SecureString -String $Enc
    $b = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

function Get-V4Paths {
    $r = @{ InstallDir=$null; Exe=$null; Core=$null; AppData=$null; ProfilesDir=$null; RuntimeFile=$null; ProfileFile=$null }
    foreach ($c in @("$env:ProgramFiles\Clash Verge", "${env:ProgramFiles(x86)}\Clash Verge")) {
        if (Test-Path (Join-Path $c 'clash-verge.exe')) { $r.InstallDir = $c; break }
    }
    $app = Get-Process -Name 'clash-verge' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($app -and $app.Path) { $r.InstallDir = Split-Path -Parent $app.Path }
    if ($r.InstallDir) {
        $r.Exe = Join-Path $r.InstallDir 'clash-verge.exe'
        foreach ($n in @('verge-mihomo.exe','mihomo.exe')) { if (Test-Path (Join-Path $r.InstallDir $n)) { $r.Core = Join-Path $r.InstallDir $n; break } }
    }
    $ad = Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev'
    if (Test-Path (Join-Path $ad 'profiles.yaml')) { $r.AppData = $ad; $r.ProfilesDir = Join-Path $ad 'profiles'; $r.RuntimeFile = Join-Path $ad 'clash-verge.yaml' }
    return $r
}

# ------------------------------------------------------------------- settings --
function Get-V4Settings {
    if (-not (Test-Path $script:SettingsPath)) { throw "settings.json not found - run: apply-v4.ps1 -Init" }
    $j = Get-Content $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $pw = Unprotect-V4Secret $j.staticProxy.passwordDpapi
    Register-V4Secret $pw
    Register-V4Secret $j.staticProxy.username
    return [pscustomobject]@{
        host = $j.staticProxy.host; port = [int]$j.staticProxy.port
        username = $j.staticProxy.username; password = $pw
        hopHost = $j.firstHop.host; hopPort = [int]$j.firstHop.port
        mixedPort = [int]$j.mixedPort
    }
}

function Save-V4Settings {
    param([string]$Host_, [int]$Port, [string]$Username, [string]$Password, [string]$HopHost, [int]$HopPort, [int]$MixedPort)
    $obj = [ordered]@{
        schema = 1
        generatedBy = 'proxy_v4'
        staticProxy = [ordered]@{ host = $Host_; port = $Port; username = $Username; passwordDpapi = (Protect-V4Secret $Password) }
        firstHop = [ordered]@{ host = $HopHost; port = $HopPort }
        mixedPort = $MixedPort
    }
    Write-V4File -Path $script:SettingsPath -Content ($obj | ConvertTo-Json -Depth 5)
    Protect-V4Acl -Path $script:ConfigDir
    Write-V4Log ("settings written (credential stored DPAPI-encrypted)") -Level OK
}

# ------------------------------------------------------------------------ ACL --
function Protect-V4Acl {
    param([string]$Path)
    try {
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $isDir = Test-Path -LiteralPath $Path -PathType Container
        $inherit = if ($isDir) { [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit' } else { [System.Security.AccessControl.InheritanceFlags]'None' }
        $acl = Get-Acl -LiteralPath $Path
        $hasMe = $acl.Access | Where-Object { $_.IdentityReference.Value -eq $me }
        if ($acl.AreAccessRulesProtected -and $hasMe) { return $true }   # idempotent
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($r in @($acl.Access)) { [void]$acl.RemoveAccessRule($r) }
        $ownerAdded = $false
        foreach ($id in @($me, 'NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators')) {
            try {
                $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($id, 'FullControl', $inherit, 'None', 'Allow')
                [void]$acl.AddAccessRule($rule)
                if ($id -eq $me) { $ownerAdded = $true }
            } catch { }
        }
        if (-not $ownerAdded) { return $false }     # never persist a DACL that locks us out
        Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
        return $true
    }
    catch { return $false }
}

# ----------------------------------------------------------------------- lock --
function Enter-V4Lock {
    param([int]$TimeoutSec = 20)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $fs = [System.IO.File]::Open($script:LockPath, 'CreateNew', 'Write', 'None')
            $w = New-Object System.IO.StreamWriter($fs)
            $w.WriteLine(('pid={0};ts={1}' -f $PID, (Get-Date).ToString('s')))
            $w.Close()
            return $true
        }
        catch {
            $txt = Read-V4File $script:LockPath
            if ($txt -and $txt -match 'pid=(\d+)') {
                $opid = [int]$Matches[1]
                if (-not (Get-Process -Id $opid -ErrorAction SilentlyContinue)) {
                    Remove-Item $script:LockPath -Force -ErrorAction SilentlyContinue
                    continue
                }
            }
            Start-Sleep -Milliseconds 400
        }
    }
    return $false
}

function Exit-V4Lock { Remove-Item $script:LockPath -Force -ErrorAction SilentlyContinue }

# ------------------------------------------------------------- process control --
function Get-V4AppPids { @(Get-Process -Name 'clash-verge','verge-mihomo' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id) }

function Stop-V4Clash {
    param([int]$TimeoutSec = 25, [int]$Port = 7897)
    $pids = Get-V4AppPids
    if ($pids.Count -eq 0 -and -not (Test-Path 'HKLM:\')) { }
    if ($pids.Count -gt 0) {
        Write-V4Log ("stopping clash processes: " + ($pids -join ','))
        foreach ($p in $pids) { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue }
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        while ((Get-Date) -lt $deadline) {
            if ((Get-V4AppPids).Count -eq 0) { break }
            Start-Sleep -Milliseconds 300
        }
    }
    # M10: verify absence, do not assume
    $left = Get-V4AppPids
    if ($left.Count -gt 0) { throw ("processes still alive after {0}s: {1}" -f $TimeoutSec, ($left -join ',')) }
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-V4Port -Port $Port)) { return $true }
        Start-Sleep -Milliseconds 250
    }
    if (Test-V4Port -Port $Port) { throw "port $Port still listening after stopping the app" }
    return $true
}

function Test-V4Port {
    param([int]$Port, [string]$Target = '127.0.0.1', [int]$TimeoutMs = 1200)
    $c = New-Object System.Net.Sockets.TcpClient
    try { $t = $c.ConnectAsync($Target, $Port); if ($t.Wait($TimeoutMs) -and $c.Connected) { return $true }; return $false }
    catch { return $false }
    finally { $c.Close() }
}

function Start-V4Clash {
    param([int]$TimeoutSec = 45, [int]$Port = 7897)
    $p = Get-V4Paths
    if (-not $p.Exe) { throw 'clash-verge.exe not found' }
    Start-Process -FilePath $p.Exe | Out-Null
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 600
        if (Test-V4Port -Port $Port) { Start-Sleep -Seconds 2; return $true }
    }
    return $false
}

# ------------------------------------------------------------------- snapshot --
function New-V4Snapshot {
    param([string]$Reason = 'apply')
    $p = Get-V4Paths
    if (-not $p.AppData) { throw 'clash appdata not found' }
    # M3: consistency first - the app must be stopped before copying
    if ((Get-V4AppPids).Count -gt 0) { Stop-V4Clash | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $dir = Join-Path $script:BackupDir $stamp
    New-Item -ItemType Directory -Path (Join-Path $dir 'profiles') -Force | Out-Null
    $files = @()
    foreach ($f in @('clash-verge.yaml','config.yaml','verge.yaml','profiles.yaml')) {
        $src = Join-Path $p.AppData $f
        if (Test-Path $src) {
            $dst = Join-Path $dir $f
            Copy-Item $src $dst -Force
            $files += [pscustomobject]@{ name=$f; sha256=(Get-FileHash $dst -Algorithm SHA256).Hash; bytes=(Get-Item $dst).Length }
        }
    }
    $profDir = Join-Path $p.AppData 'profiles'
    if (Test-Path $profDir) {
        Get-ChildItem $profDir -File -Filter *.yaml | ForEach-Object {
            $dst = Join-Path $dir ('profiles\' + $_.Name)
            Copy-Item $_.FullName $dst -Force
            $files += [pscustomobject]@{ name=('profiles\' + $_.Name); sha256=(Get-FileHash $dst -Algorithm SHA256).Hash; bytes=(Get-Item $dst).Length }
        }
    }
    $manifest = [ordered]@{
        createdAt = (Get-Date).ToString('s'); reason = $reason
        systemProxy = (Get-V4SystemProxy); clashRunning = $false
        files = $files
    }
    Write-V4File -Path (Join-Path $dir 'manifest.json') -Content ($manifest | ConvertTo-Json -Depth 5)
    Protect-V4Acl -Path $dir | Out-Null
    return $dir
}

function Restore-V4Snapshot {
    param([string]$SnapshotDir)
    $p = Get-V4Paths
    $mp = Join-Path $SnapshotDir 'manifest.json'
    if (-not (Test-Path $mp)) { throw "snapshot manifest missing: $SnapshotDir" }
    $m = Get-Content $mp -Raw -Encoding UTF8 | ConvertFrom-Json
    # verify EVERYTHING before touching the live tree
    foreach ($e in @($m.files)) {
        $src = Join-Path $SnapshotDir $e.name
        if (-not (Test-Path $src)) { throw "snapshot incomplete: missing $($e.name)" }
        if ((Get-FileHash $src -Algorithm SHA256).Hash -ne $e.sha256) { throw "snapshot hash mismatch: $($e.name)" }
    }
    if ((Get-V4AppPids).Count -gt 0) { Stop-V4Clash | Out-Null }
    foreach ($f in @('clash-verge.yaml','config.yaml','verge.yaml','profiles.yaml')) {
        $src = Join-Path $SnapshotDir $f
        if (Test-Path $src) { Copy-Item $src (Join-Path $p.AppData $f) -Force }
    }
    $pd = Join-Path $SnapshotDir 'profiles'
    if (Test-Path $pd) { Get-ChildItem $pd -File | ForEach-Object { Copy-Item $_.FullName (Join-Path $p.ProfilesDir $_.Name) -Force } }
    return $m
}

# ---------------------------------------------------------------- atomic write --
function Set-V4Atomic {
    param([string]$TargetPath, [string]$Content, [scriptblock]$Validator)
    $dir = Split-Path -Parent $TargetPath
    $tmp = Join-Path $dir ('.v4stage-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.yaml')
    $bak = '{0}.{1}.bak' -f $TargetPath, [guid]::NewGuid().ToString('N').Substring(0,8)
    $madeBak = $false
    Write-V4File -Path $tmp -Content $Content
    try {
        if ($Validator) { & $Validator $tmp }
        if (Test-Path $TargetPath) { Copy-Item $TargetPath $bak -Force; $madeBak = $true }
        Move-Item -LiteralPath $tmp -Destination $TargetPath -Force
        if ($madeBak -and (Test-Path $bak)) { Remove-Item $bak -Force -ErrorAction SilentlyContinue }
        return $true
    }
    catch {
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        if ($madeBak -and (Test-Path $bak)) {
            Copy-Item $bak $TargetPath -Force -ErrorAction SilentlyContinue
            Remove-Item $bak -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Test-V4MihomoConfig {
    param([string]$ConfigPath, [string]$WorkDir)
    $p = Get-V4Paths
    if (-not $p.Core) { throw 'mihomo core not found' }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & $p.Core -t -f $ConfigPath -d $WorkDir 2>&1; $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prev }
    if ($code -ne 0) { throw ("mihomo -t failed (exit {0})" -f $code) }
    return $true
}

# -------------------------------------------------------------------- proxies --
function Get-V4SystemProxy {
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $v = Get-ItemProperty $k -ErrorAction SilentlyContinue
    return [pscustomobject]@{ enabled = [bool]$v.ProxyEnable; server = $v.ProxyServer }
}

function Set-V4SystemProxy {
    param([string]$Server)
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    Set-ItemProperty $k -Name ProxyServer -Value $Server
    Set-ItemProperty $k -Name ProxyEnable -Value 1
    Update-V4WinInet
}

function Clear-V4SystemProxy { Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxyEnable -Value 0; Update-V4WinInet }

function Update-V4WinInet {
    if (-not ('V4Inet.Refresh' -as [type])) {
        Add-Type -MemberDefinition '[DllImport("wininet.dll",SetLastError=true)]public static extern bool InternetSetOption(IntPtr h,int o,IntPtr b,int l);' -Name Refresh -Namespace V4Inet | Out-Null
    }
    [void][V4Inet.Refresh]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)
    [void][V4Inet.Refresh]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)
}

function Get-V4ExitIp {
    param([string]$Proxy = '', [int]$TimeoutSec = 20)
    foreach ($t in @('https://api.ipify.org','https://ifconfig.me/ip','https://icanhazip.com')) {
        $a = @('-sS','-m',"$TimeoutSec")
        if ($Proxy) { $a += @('-x',$Proxy) } else { $a += @('--noproxy','*') }
        $a += $t
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $out = & curl.exe @a 2>&1; $rc = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
        if ($rc -ne 0) { continue }
        $txt = ($out -join '').Trim()
        if ($txt -match '^\s*(\d{1,3}(\.\d{1,3}){3})\s*$') { return $Matches[1] }
    }
    return $null
}

function Test-V4FirstHop {
    param([int]$Port, [int]$TimeoutMs = 6000)
    if (-not (Test-V4Port -Port $Port)) { return [pscustomobject]@{ ok=$false; detail="port $Port not listening" } }
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $c.Connect('127.0.0.1', $Port); $c.ReceiveTimeout = $TimeoutMs
        $s = $c.GetStream()
        $b = [System.Text.Encoding]::ASCII.GetBytes("CONNECT api.ipify.org:443 HTTP/1.1`r`nHost: api.ipify.org:443`r`n`r`n")
        $s.Write($b, 0, $b.Length); $s.Flush()
        $buf = New-Object byte[] 256
        $n = $s.Read($buf, 0, $buf.Length)
        if ($n -le 0) { return [pscustomobject]@{ ok=$false; detail='closed without reply' } }
        $line = ([System.Text.Encoding]::ASCII.GetString($buf,0,$n) -split "`r`n")[0]
        if ($line -match '^HTTP/\d\.\d\s+200') { return [pscustomobject]@{ ok=$true; detail=$line } }
        return [pscustomobject]@{ ok=$false; detail=$line }
    }
    catch { return [pscustomobject]@{ ok=$false; detail=$_.Exception.Message } }
    finally { $c.Close() }
}

# --------------------------------------------------------------------- owner --
function Get-V4Owner {
    if (-not (Test-Path $script:OwnerPath)) { return $null }
    try { return (Get-Content $script:OwnerPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Set-V4Owner {
    param([string]$Owner, [string]$SystemProxy, [string]$Note = '')
    $o = [ordered]@{ owner = $Owner; systemProxy = $SystemProxy; note = $Note; pid = $PID; updatedAt = (Get-Date).ToString('s') }
    Write-V4File -Path $script:OwnerPath -Content ($o | ConvertTo-Json -Depth 4)
}

# ------------------------------------------------------------------ generation --
function Build-V4Profile {
    param([object]$S, [string]$Mode = 'resilient')
    $group = if ($Mode -eq 'resilient') {
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
    } else {
@"
proxy-groups:
  - name: "PROXY"
    type: select
    proxies:
      - "US-WA-SOCKS5"
      - "DIRECT"
"@
    }
@"
$($script:Marker)
# generated $(Get-Date -Format 's')
mixed-port: $($S.mixedPort)
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
    server: $($S.hopHost)
    port: $($S.hopPort)
  - name: "US-WA-SOCKS5"
    type: socks5
    server: $($S.host)
    port: $($S.port)
    username: "$($S.username)"
    password: "$($S.password)"
    udp: false
    dialer-proxy: "STAR-FIRSTHOP"

$group
rules:
  - MATCH,PROXY
"@
}

function Build-V4Runtime {
    param([object]$S, [string]$Mode = 'resilient', [string]$Pipe, [string]$Secret)
    $profile = Build-V4Profile -S $S -Mode $Mode
    # keep everything from `proxies:` onward (proxies + groups + rules); the runtime
    # header below replaces the profile-only preamble
    $idx = $profile.IndexOf('proxies:')
    if ($idx -lt 0) { throw 'generated profile has no proxies section' }
    $groupPart = $profile.Substring($idx)
    @"
$($script:Marker)
mode: rule
mixed-port: $($S.mixedPort)
allow-lan: false
log-level: info
ipv6: true
unified-delay: true
find-process-mode: "off"
tcp-concurrent: true
secret: $Secret
profile:
  store-selected: true
external-controller-pipe: $Pipe
tun:
  enable: false
  stack: mips
  auto-route: true
  strict-route: false
  auto-detect-interface: true
  dns-hijack:
  - any:53
$groupPart
"@
}

function Get-V4Controller {
    $p = Get-V4Paths
    $pipe = $null; $secret = $null
    $mih = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -in @('verge-mihomo.exe','mihomo.exe') } | Select-Object -First 1
    if ($mih -and $mih.CommandLine -match '-ext-ctl-pipe\s+"?([^"]+)"?') { $pipe = $Matches[1].Trim() }
    if ($p.RuntimeFile) {
        $t = Read-V4File $p.RuntimeFile
        if ($t) {
            if (-not $pipe -and $t -match '(?m)^external-controller-pipe:\s*(.+?)\s*$') { $pipe = $Matches[1] }
            if ($t -match '(?m)^secret:\s*(.+?)\s*$') { $secret = $Matches[1] }
        }
    }
    if (-not $secret) { $secret = 'set-your-secret' }
    Register-V4Secret $secret
    return [pscustomobject]@{ pipe = $pipe; secret = $secret }
}

# -------------------------------------------------------------------- state ----
function Get-V4State {
    $p = Get-V4Paths
    $s = Get-V4Settings -ErrorAction SilentlyContinue
    $owner = Get-V4Owner
    $px = Get-V4SystemProxy
    $out = [ordered]@{
        ts = (Get-Date).ToString('s')
        state = 'UNKNOWN'; mode = 'UNKNOWN'; reasons = @()
        clashRunning = ((Get-V4AppPids).Count -gt 0)
        mixedPort = (Test-V4Port -Port $(if ($s) { $s.mixedPort } else { 7897 }))
        systemProxy = $(if ($px.enabled) { $px.server } else { 'off' })
        owner = $(if ($owner) { $owner.owner } else { 'none' })
        firstHopOk = $false
        exitViaChain = $null
    }
    if (-not $s) { $out.reasons += 'settings.json missing'; return $out }
    $hop = Test-V4FirstHop -Port $s.hopPort
    $out.firstHopOk = $hop.ok
    if (-not $out.firstHopOk) { $out.reasons += ('first hop down: ' + $hop.detail) }

    if (-not $out.clashRunning) { $out.mode = 'RAW'; $out.state = 'FAILED'; $out.reasons += 'clash not running' }
    elseif (-not $out.mixedPort) { $out.mode = 'NEXIP'; $out.state = 'FAILED'; $out.reasons += 'core not listening' }
    else {
        $out.mode = 'NEXIP'
        if ($out.systemProxy -ne ('127.0.0.1:' + $s.mixedPort)) {
            $out.state = 'DEGRADED'; $out.reasons += ('system proxy owned by ' + $out.systemProxy)
        }
        elseif (-not $out.firstHopOk) { $out.state = 'DEGRADED' }
        else {
            $out.exitViaChain = Get-V4ExitIp -Proxy ('socks5h://127.0.0.1:' + $s.mixedPort)
            if ($out.exitViaChain -eq $s.host) { $out.state = 'HEALTHY' }
            elseif ($out.exitViaChain) { $out.state = 'DEGRADED'; $out.reasons += ('exit ' + $out.exitViaChain + ' != ' + $s.host) }
            else { $out.state = 'FAILED'; $out.reasons += 'no exit ip' }
        }
    }
    return $out
}
