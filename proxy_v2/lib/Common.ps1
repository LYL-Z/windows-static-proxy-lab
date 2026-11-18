#Requires -Version 5.1
<#
  Common.ps1  --  shared helpers for the proxy_v2 toolset
  Design rules:
    * never print, log or export credential values (redaction is enforced in Write-Log)
    * discover paths from the live system, never hardcode pipe names / install paths
    * every probe is read-only; every write goes through the transaction helpers
#>

Set-StrictMode -Version 1.0

# ---------------------------------------------------------------- logging ---
$script:SecretValues = New-Object System.Collections.Generic.List[string]
$script:LogFile = $null

function Register-Secret {
    param([string]$Value)
    if ($Value -and -not $script:SecretValues.Contains($Value)) { $script:SecretValues.Add($Value) }
}

function Get-Redacted {
    param([string]$Text)
    if (-not $Text) { return $Text }
    foreach ($s in $script:SecretValues) {
        if ($s -and $s.Length -ge 4) { $Text = $Text.Replace($s, '***REDACTED***') }
    }
    # generic guard: any basic-auth blob or password-ish key/value
    $Text = [regex]::Replace($Text, '(?i)(password\s*[:=]\s*)"?[^\s",\}]+', '$1"***"')
    $Text = [regex]::Replace($Text, '(?i)(Basic\s+)([A-Za-z0-9+/=]{8,})', '$1***')
    return $Text
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'STEP')][string]$Level = 'INFO'
    )
    $msg = Get-Redacted $Message
    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $msg
    $color = switch ($Level) {
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        'STEP'  { 'Cyan' }
        default { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
    if ($script:LogFile) {
        try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch { }
    }
}

function Start-LogFile {
    param([Parameter(Mandatory)][string]$Path)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $script:LogFile = $Path
    Add-Content -LiteralPath $Path -Value ("# proxy_v2 log {0}" -f (Get-Date -Format 's')) -Encoding UTF8
}

# --------------------------------------------------------------- encoding ---
function Get-Utf8NoBom { New-Object System.Text.UTF8Encoding($false) }

function Write-TextFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, (Get-Utf8NoBom))
}

function Read-TextFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

# -------------------------------------------------------------- discovery ---
function Get-ClashPaths {
    <#
      Returns a hashtable with:
        InstallDir, Exe, Core, AppDataDir, ProfilesDir, ProfileFile, ProfileUid,
        RuntimeFile, AppConfigFile, VergeConfigFile, MihomoPid
      Missing values stay $null; callers must check.
    #>
    $r = @{
        InstallDir = $null; Exe = $null; Core = $null
        AppDataDir = $null; ProfilesDir = $null; ProfileFile = $null; ProfileUid = $null
        RuntimeFile = $null; AppConfigFile = $null; VergeConfigFile = $null; MihomoPid = $null
    }

    # --- install dir: running process first ---
    $app = Get-Process -Name 'clash-verge' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($app -and $app.Path) {
        $r.Exe = $app.Path
        $r.InstallDir = Split-Path -Parent $app.Path
    }
    if (-not $r.Exe) {
        $keys = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
        foreach ($k in $keys) {
            $hit = Get-ItemProperty $k -ErrorAction SilentlyContinue |
                Where-Object {
                    ($_.PSObject.Properties.Name -contains 'DisplayName') -and
                    ($_.DisplayName -match 'Clash Verge') -and
                    ($_.PSObject.Properties.Name -contains 'InstallLocation') -and
                    $_.InstallLocation
                } | Select-Object -First 1
            if ($hit) {
                $loc = $hit.InstallLocation.Trim('"')
                if (Test-Path (Join-Path $loc 'clash-verge.exe')) {
                    $r.InstallDir = $loc
                    $r.Exe = Join-Path $loc 'clash-verge.exe'
                    break
                }
            }
        }
    }
    if (-not $r.Exe) {
        foreach ($c in @("$env:ProgramFiles\Clash Verge", "${env:ProgramFiles(x86)}\Clash Verge")) {
            if (Test-Path (Join-Path $c 'clash-verge.exe')) {
                $r.InstallDir = $c; $r.Exe = Join-Path $c 'clash-verge.exe'; break
            }
        }
    }
    if ($r.InstallDir) {
        foreach ($n in @('verge-mihomo.exe', 'mihomo.exe', 'clash-meta.exe', 'clash.exe')) {
            $p = Join-Path $r.InstallDir $n
            if (Test-Path $p) { $r.Core = $p; break }
        }
    }

    # --- app data dir ---
    $candidates = @(
        (Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev'),
        (Join-Path $env:APPDATA 'clash-verge')
    )
    foreach ($c in $candidates) {
        if (Test-Path (Join-Path $c 'profiles.yaml')) { $r.AppDataDir = $c; break }
    }
    if (-not $r.AppDataDir) {
        Get-ChildItem $env:APPDATA -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'clash-verge' -and (Test-Path (Join-Path $_.FullName 'profiles.yaml')) } |
            Select-Object -First 1 | ForEach-Object { $r.AppDataDir = $_.FullName }
    }
    if (-not $r.AppDataDir) { return $r }

    $r.ProfilesDir     = Join-Path $r.AppDataDir 'profiles'
    $r.VergeConfigFile = Join-Path $r.AppDataDir 'verge.yaml'
    $r.AppConfigFile   = Join-Path $r.AppDataDir 'config.yaml'
    $r.RuntimeFile     = Join-Path $r.AppDataDir 'clash-verge.yaml'

    # --- current profile from profiles.yaml ---
    $profilesYaml = Read-TextFile (Join-Path $r.AppDataDir 'profiles.yaml')
    if ($profilesYaml) {
        if ($profilesYaml -match '(?m)^current:\s*(\S+)\s*$') { $r.ProfileUid = $Matches[1] }
        if ($r.ProfileUid) {
            # find the item block for this uid and its file:
            $lines = $profilesYaml -split "`r?`n"
            $inBlock = $false
            foreach ($ln in $lines) {
                if ($ln -match '^\s*-\s*uid:\s*(\S+)\s*$') { $inBlock = ($Matches[1] -eq $r.ProfileUid); continue }
                if ($inBlock -and $ln -match '^\s*file:\s*(\S+)\s*$') {
                    $r.ProfileFile = Join-Path $r.ProfilesDir $Matches[1]
                    break
                }
            }
        }
        if (-not $r.ProfileFile) {
            # fallback: newest .yaml under profiles that looks like a proxy config
            $r.ProfileFile = Get-ChildItem $r.ProfilesDir -Filter *.yaml -ErrorAction SilentlyContinue |
                Where-Object { (Read-TextFile $_.FullName) -match '(?m)^proxies:' } |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
        }
    }

    # --- runtime file actually used by the core (from its cmdline) ---
    $mih = Get-CimInstance Win32_Process -Filter "Name='verge-mihomo.exe'" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $mih) { $mih = Get-CimInstance Win32_Process -Filter "Name='mihomo.exe'" -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if ($mih) {
        $r.MihomoPid = $mih.ProcessId
        if ($mih.CommandLine -match '-f\s+"?([^"]+\.ya?ml)') { $r.RuntimeFile = $Matches[1].Trim('"') }
    }
    return $r
}

function Get-YamlScalar {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Key)
    $t = Read-TextFile $Path
    if (-not $t) { return $null }
    if ($t -match ('(?m)^\s*' + [regex]::Escape($Key) + '\s*:\s*(.+?)\s*$')) {
        return $Matches[1].Trim().Trim('"').Trim("'")
    }
    return $null
}

function Get-MihomoChannel {
    <# returns @{ Kind='pipe'|'tcp'; Target=...; Secret=... } #>
    $p = Get-ClashPaths
    $secret = $null
    if ($p.RuntimeFile) { $secret = Get-YamlScalar -Path $p.RuntimeFile -Key 'secret' }

    $pipe = $null
    $mih = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in @('verge-mihomo.exe', 'mihomo.exe') } | Select-Object -First 1
    if ($mih -and $mih.CommandLine -match '-ext-ctl-pipe\s+"?([^"]+)"?') { $pipe = $Matches[1].Trim() }
    if (-not $pipe -and $p.RuntimeFile) { $pipe = Get-YamlScalar -Path $p.RuntimeFile -Key 'external-controller-pipe' }
    if ($pipe) { return @{ Kind = 'pipe'; Target = $pipe; Secret = $secret } }

    $tcp = $null
    if ($p.RuntimeFile) { $tcp = Get-YamlScalar -Path $p.RuntimeFile -Key 'external-controller' }
    if ($tcp -and $tcp -match '^\s*[\d\.]+:\d+') { return @{ Kind = 'tcp'; Target = $tcp.Trim(); Secret = $secret } }
    return $null
}

# ------------------------------------------------------------- mihomo API ---
function Invoke-MihomoApi {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Method = 'GET',
        [int]$TimeoutMs = 6000
    )
    $ch = Get-MihomoChannel
    if (-not $ch) { throw 'mihomo external controller not found (core not running?)' }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("$Method $Path HTTP/1.1`r`n")
    [void]$sb.Append("Host: localhost`r`n")
    if ($ch.Secret) { [void]$sb.Append("Authorization: Bearer $($ch.Secret)`r`n") }
    [void]$sb.Append("Accept: application/json`r`n")
    [void]$sb.Append("Connection: close`r`n`r`n")
    $head = [System.Text.Encoding]::ASCII.GetBytes($sb.ToString())

    if ($ch.Kind -eq 'pipe') {
        $name = ($ch.Target -split '\\')[-1]
        $c = New-Object System.IO.Pipes.NamedPipeClientStream(
            '.', $name, [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
        try { $c.Connect(2500) } catch { $c.Dispose(); throw "pipe connect failed: $($_.Exception.Message)" }
        $c.Write($head, 0, $head.Length); $c.Flush()
        $ms = New-Object System.IO.MemoryStream
        $buf = New-Object byte[] 65536
        $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
        while ([DateTime]::UtcNow -lt $deadline) {
            $task = $c.ReadAsync($buf, 0, $buf.Length)
            if (-not $task.Wait([Math]::Max(150, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))) { break }
            $n = $task.Result
            if ($n -le 0) { break }
            $ms.Write($buf, 0, $n)
        }
        $c.Dispose()
    }
    else {
        $parts = $ch.Target.Split(':'); $host2 = $parts[0]; $port = [int]$parts[1]
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect($host2, $port); $tcp.ReceiveTimeout = $TimeoutMs
        $stream = $tcp.GetStream()
        $stream.Write($head, 0, $head.Length); $stream.Flush()
        $ms = New-Object System.IO.MemoryStream
        $buf = New-Object byte[] 65536
        while ($true) {
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $ms.Write($buf, 0, $n)
        }
        $tcp.Close()
    }

    $all = $ms.ToArray()
    if (-not $all -or $all.Length -eq 0) { throw 'empty response from mihomo API' }
    $hdrEnd = -1
    for ($i = 0; $i -lt $all.Length - 3; $i++) {
        if ($all[$i] -eq 13 -and $all[$i + 1] -eq 10 -and $all[$i + 2] -eq 13 -and $all[$i + 3] -eq 10) { $hdrEnd = $i; break }
    }
    if ($hdrEnd -lt 0) { throw 'malformed response from mihomo API' }
    $headText = [System.Text.Encoding]::ASCII.GetString($all, 0, $hdrEnd)
    $bodyLen = $all.Length - ($hdrEnd + 4)
    $body = New-Object byte[] $bodyLen
    [Array]::Copy($all, $hdrEnd + 4, $body, 0, $bodyLen)

    if ($headText -match '(?i)transfer-encoding:\s*chunked') {
        $out = New-Object System.IO.MemoryStream; $pos = 0
        while ($pos -lt $body.Length) {
            $j = $pos
            while ($j + 1 -lt $body.Length -and -not ($body[$j] -eq 13 -and $body[$j + 1] -eq 10)) { $j++ }
            if ($j + 1 -ge $body.Length) { break }
            $line = [System.Text.Encoding]::ASCII.GetString($body, $pos, $j - $pos)
            $hex = ($line -split ';')[0].Trim()
            if (-not $hex) { break }
            try { $len = [Convert]::ToInt32($hex, 16) } catch { break }
            if ($len -le 0) { break }
            $start = $j + 2
            if ($start + $len -gt $body.Length) { $len = $body.Length - $start }
            $out.Write($body, $start, $len)
            $pos = $start + $len + 2
        }
        $body = $out.ToArray()
    }
    $statusLine = ($headText -split "`r`n")[0]
    $code = 0
    if ($statusLine -match 'HTTP/\d\.\d\s+(\d{3})') { $code = [int]$Matches[1] }
    return [pscustomobject]@{ StatusCode = $code; StatusLine = $statusLine; Body = [System.Text.Encoding]::UTF8.GetString($body) }
}

# ------------------------------------------------------------ net probing ---
function Get-NeutralIp {
    <#  resolve the caller's egress IP via a neutral endpoint; $Proxy like 'socks5h://127.0.0.1:7897' or '' for direct #>
    param([string]$Proxy = '', [int]$TimeoutSec = 20)
    $targets = @('https://api.ipify.org', 'https://ifconfig.me/ip', 'https://icanhazip.com')
    foreach ($t in $targets) {
        $curlArgs = @('-sS', '-m', "$TimeoutSec")
        if ($Proxy) { $curlArgs += @('-x', $Proxy) } else { $curlArgs += @('--noproxy', '*') }
        $curlArgs += $t
        # H1: under EAP=Stop, native stderr with 2>&1 raises a TERMINATING error.
        # curl -sS writes every failure to stderr, which killed the retry loop and
        # skipped the restore path. Scope EAP locally and branch on $LASTEXITCODE.
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $out = & curl.exe @curlArgs 2>&1
            $rc = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $prevEap }
        if ($rc -ne 0) { continue }
        $txt = ($out -join '').Trim()
        if ($txt -match '^\s*(\d{1,3}(\.\d{1,3}){3})\s*$') { return $Matches[1] }
    }
    return $null
}

function Test-TcpPort {
    param([string]$Target = '127.0.0.1', [Parameter(Mandatory)][int]$Port, [int]$TimeoutMs = 1500)
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $t = $c.ConnectAsync($Target, $Port)
        if ($t.Wait($TimeoutMs) -and $c.Connected) { return $true }
        return $false
    }
    catch { return $false }
    finally { $c.Close() }
}

function Test-FirstHop {
    <# real HTTP CONNECT through the local first hop - proves it proxies, not merely listens #>
    param([string]$Target = '127.0.0.1', [Parameter(Mandatory)][int]$Port,
          [string]$ProbeHost = 'api.ipify.org', [int]$ProbePort = 443, [int]$TimeoutMs = 8000)
    $res = [pscustomobject]@{ Ok = $false; Detail = '' }
    if (-not (Test-TcpPort -Target $Target -Port $Port)) {
        $res.Detail = "port $Port not listening"; return $res
    }
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $c.Connect($Target, $Port)
        $c.ReceiveTimeout = $TimeoutMs
        $s = $c.GetStream()
        $req = "CONNECT $ProbeHost`:$ProbePort HTTP/1.1`r`nHost: $ProbeHost`:$ProbePort`r`nProxy-Connection: Keep-Alive`r`n`r`n"
        $b = [System.Text.Encoding]::ASCII.GetBytes($req)
        $s.Write($b, 0, $b.Length); $s.Flush()
        $c.ReceiveTimeout = $TimeoutMs
        $buf2 = New-Object byte[] 512
        $n = $s.Read($buf2, 0, $buf2.Length)
        if ($n -le 0) { $res.Detail = 'first hop closed without reply'; return $res }
        $line = ([System.Text.Encoding]::ASCII.GetString($buf2, 0, $n) -split "`r`n")[0]
        if ($line -match '^HTTP/\d\.\d\s+200') {
            $res.Ok = $true; $res.Detail = "CONNECT ok ($line)"
        }
        else { $res.Detail = "unexpected reply: $line" }
    }
    catch { $res.Detail = "first-hop probe failed: $($_.Exception.Message)" }
    finally { $c.Close() }
    return $res
}

# --------------------------------------------------------------- system px ---
function Get-SystemProxy {
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $v = Get-ItemProperty $k -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Enabled = [bool]$v.ProxyEnable; Server = $v.ProxyServer; Override = $v.ProxyOverride }
}

function Set-SystemProxy {
    param([Parameter(Mandatory)][string]$Server)
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    Set-ItemProperty $k -Name ProxyServer -Value $Server
    Set-ItemProperty $k -Name ProxyEnable -Value 1
    $override = 'localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*'
    Set-ItemProperty $k -Name ProxyOverride -Value $override
    Update-WinInet
}

function Clear-SystemProxy {
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    Set-ItemProperty $k -Name ProxyEnable -Value 0
    Update-WinInet
}

function Update-WinInet {
    if (-not ('WinInet.Refresh' -as [type])) {
        $sig = @'
[DllImport("wininet.dll", SetLastError = true)]
public static extern bool InternetSetOption(IntPtr h, int o, IntPtr b, int l);
'@
        Add-Type -MemberDefinition $sig -Name Refresh -Namespace WinInet | Out-Null
    }
    [void][WinInet.Refresh]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)
    [void][WinInet.Refresh]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)
}

# ------------------------------------------------------------ transactions ---
function New-StateSnapshot {
    <# copy config files into a timestamped backup dir + manifest with hashes #>
    param([Parameter(Mandatory)][string]$Root, [int]$KeepDays = 30)
    $p = Get-ClashPaths
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dir = Join-Path $Root "backup\$stamp"
    New-Item -ItemType Directory -Path (Join-Path $dir 'profiles') -Force | Out-Null

    $files = @('clash-verge.yaml', 'config.yaml', 'verge.yaml', 'profiles.yaml')
    $manifest = @{ createdAt = (Get-Date).ToString('s'); files = @(); profileUid = $p.ProfileUid }
    foreach ($f in $files) {
        $src = Join-Path $p.AppDataDir $f
        if (Test-Path $src) {
            Copy-Item $src (Join-Path $dir $f) -Force
            $manifest.files += [pscustomobject]@{
                name = $f; sha256 = (Get-FileHash $src -Algorithm SHA256).Hash; bytes = (Get-Item $src).Length
            }
        }
    }
    if ($p.ProfileFile -and (Test-Path $p.ProfileFile)) {
        $leaf = Split-Path $p.ProfileFile -Leaf
        Copy-Item $p.ProfileFile (Join-Path $dir "profiles\$leaf") -Force
        $manifest.files += [pscustomobject]@{
            name = "profiles\$leaf"; sha256 = (Get-FileHash $p.ProfileFile -Algorithm SHA256).Hash; bytes = (Get-Item $p.ProfileFile).Length
        }
    }
    $manifest.systemProxy = Get-SystemProxy
    # remember whether the app was running, so rollback does not start it and let
    # it re-assert its own system proxy on top of the restored value
    $manifest.clashRunning = [bool](Get-Process -Name 'clash-verge' -ErrorAction SilentlyContinue)
    $manifest | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $dir 'manifest.json') -Encoding UTF8

    # retention
    Get-ChildItem (Join-Path $Root 'backup') -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$KeepDays) } |
        ForEach-Object { try { Remove-Item $_.FullName -Recurse -Force } catch { } }

    Protect-PrivatePath -Path $dir | Out-Null
    return $dir
}

function Restore-StateSnapshot {
    param([Parameter(Mandatory)][string]$SnapshotDir)
    $p = Get-ClashPaths
    $manifestPath = Join-Path $SnapshotDir 'manifest.json'
    if (-not (Test-Path $manifestPath)) { throw "snapshot manifest missing: $SnapshotDir" }
    # H5: verify the snapshot BEFORE overwriting anything live. Restoring first and
    # hashing afterwards means a corrupt snapshot destroys the good live config.
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    foreach ($entry in @($manifest.files)) {
        if (-not $entry) { continue }
        $src = Join-Path $SnapshotDir $entry.name
        if (-not (Test-Path $src)) { throw "snapshot is incomplete: missing $($entry.name)" }
        if ($entry.sha256) {
            $h = (Get-FileHash $src -Algorithm SHA256).Hash
            if ($h -ne $entry.sha256) { throw "snapshot hash mismatch: $($entry.name) (refusing to restore)" }
        }
    }
    foreach ($f in @('clash-verge.yaml', 'config.yaml', 'verge.yaml', 'profiles.yaml')) {
        $src = Join-Path $SnapshotDir $f
        if (Test-Path $src) { Copy-Item $src (Join-Path $p.AppDataDir $f) -Force }
    }
    $profDir = Join-Path $SnapshotDir 'profiles'
    if (Test-Path $profDir) {
        Get-ChildItem $profDir -File | ForEach-Object { Copy-Item $_.FullName (Join-Path $p.ProfilesDir $_.Name) -Force }
    }
    return $true
}

function Protect-PrivatePath {
    <# restrict ACL to current user + SYSTEM + Administrators.
       Files cannot carry inherited-ACE flags; directories can. Getting this
       wrong silently drops the owner rule and locks the user out. #>
    param([Parameter(Mandatory)][string]$Path)
    try {
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $isDir = Test-Path -LiteralPath $Path -PathType Container
        $inherit = if ($isDir) { [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit' }
                   else { [System.Security.AccessControl.InheritanceFlags]'None' }
        $prop = if ($isDir) { [System.Security.AccessControl.PropagationFlags]'None' }
                else { [System.Security.AccessControl.PropagationFlags]'None' }

        $acl = Get-Acl -LiteralPath $Path
        # M1: idempotent - an already-correct ACL must return success on re-runs
        # (previously the second call always failed and reported "needs ownership").
        $meAce = $acl.Access | Where-Object { $_.IdentityReference.Value -eq $me }
        if ($acl.AreAccessRulesProtected -and $meAce -and @($acl.Access).Count -eq 3) { return $true }
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($r in @($acl.Access)) { [void]$acl.RemoveAccessRule($r) }

        $added = 0; $ownerAdded = $false
        foreach ($id in @($me, 'NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators')) {
            try {
                $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $id, 'FullControl', $inherit, $prop, 'Allow')
                [void]$acl.AddAccessRule($rule)
                $added++
                if ($id -eq $me) { $ownerAdded = $true }
            } catch { }
        }
        # M2: require the OWNER's ACE specifically. If only SYSTEM/Administrators were
        # added, Set-Acl would persist a DACL that locks the current user out.
        if (-not $ownerAdded) { throw 'owner ACE could not be built; refusing to lock the user out' }

        Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop

        # self-check: the current user must still be able to read it back
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [void][System.IO.File]::ReadAllBytes($Path)
        }
        return $true
    }
    catch {
        return $false
    }
}

function Invoke-AtomicReplace {
    <# stage -> validate -> replace, restoring the original on any failure.
       $Validator receives the temp path; must return $true or throw. #>
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][scriptblock]$Validator
    )
    $dir = Split-Path -Parent $TargetPath
    $tmp = Join-Path $dir ('.staged-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '-' + (Split-Path $TargetPath -Leaf))
    # H2: a fixed "$Target.bak" let a later run restore a STALE previous backup over
    # an untouched live file. Use a per-run name and only restore what THIS run made.
    $bak = '{0}.{1}.bak' -f $TargetPath, [guid]::NewGuid().ToString('N').Substring(0, 8)
    $madeBackup = $false
    Write-TextFile -Path $tmp -Content $Content
    try {
        & $Validator $tmp
        if (Test-Path $TargetPath) { Copy-Item $TargetPath $bak -Force; $madeBackup = $true }
        Move-Item -LiteralPath $tmp -Destination $TargetPath -Force
        if ($madeBackup) { Remove-Item $bak -Force -ErrorAction SilentlyContinue }
        return $true
    }
    catch {
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        if ($madeBackup -and (Test-Path $bak)) {
            Copy-Item $bak $TargetPath -Force -ErrorAction SilentlyContinue
            Remove-Item $bak -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Test-MihomoConfig {
    param([Parameter(Mandatory)][string]$ConfigPath, [Parameter(Mandatory)][string]$WorkDir)
    $p = Get-ClashPaths
    if (-not $p.Core) { throw 'mihomo core binary not found; cannot validate' }
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $p.Core -t -f $ConfigPath -d $WorkDir 2>&1
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $prevEap }
    $text = ($out | Out-String)
    if ($code -ne 0 -or $text -notmatch 'test is successful') {
        throw "mihomo config validation failed (exit=$code): $(Get-Redacted ($text.Trim() -split "`n" | Select-Object -Last 1))"
    }
    return $true
}

function Restart-ClashVerge {
    <# returns $true when 7897 is listening within timeout #>
    param([int]$TimeoutSec = 45, [int]$Port = 7897)
    $p = Get-ClashPaths
    if (-not $p.Exe) { throw 'clash-verge.exe not found' }
    Get-Process -Name 'verge-mihomo', 'clash-verge' -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Start-Process -FilePath $p.Exe | Out-Null
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 1200
        if (Test-TcpPort -Port $Port) { Start-Sleep -Seconds 2; return $true }
    }
    return $false
}

function Get-ProfileCredential {
    <# read existing socks5 credentials from the active profile WITHOUT printing them #>
    param([Parameter(Mandatory)][string]$ProfilePath)
    $t = Read-TextFile $ProfilePath
    if (-not $t) { return $null }
    $u = $null; $pw = $null
    if ($t -match '(?m)^\s*username:\s*"?([^"\r\n]+)"?\s*$') { $u = $Matches[1].Trim() }
    if ($t -match '(?m)^\s*password:\s*"?([^"\r\n]+)"?\s*$') { $pw = $Matches[1].Trim() }
    if (-not $u -or -not $pw) { return $null }
    Register-Secret $pw
    Register-Secret $u
    return [pscustomobject]@{ Username = $u; Password = $pw }
}

function Write-SummaryTable {
    param([Parameter(Mandatory)][object[]]$Rows)
    $Rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
}

# --------------------------------------------------------- profile parsing ---
function Get-ProxyNodes {
    <# minimal block parser for the `proxies:` list of a mihomo profile #>
    param([Parameter(Mandatory)][string]$ProfilePath)
    $t = Read-TextFile $ProfilePath
    if (-not $t) { return @() }
    $nodes = @()
    $cur = $null
    foreach ($ln in ($t -split "`r?`n")) {
        if ($ln -match '^\s*-\s*name:\s*(.+?)\s*$') {
            if ($cur) { $nodes += [pscustomobject]$cur }
            $cur = @{ name = $Matches[1].Trim().Trim('"').Trim("'") }
            continue
        }
        if (-not $cur) { continue }
        if ($ln -match '^\s*([A-Za-z0-9\-]+):\s*(.+?)\s*$') {
            $k = $Matches[1]; $v = $Matches[2].Trim().Trim('"').Trim("'")
            if ($k -in @('type', 'server', 'port', 'dialer-proxy')) { $cur[$k] = $v }
        }
    }
    if ($cur) { $nodes += [pscustomobject]$cur }
    return $nodes
}

function Get-FirstHopConfig {
    <# the local first-hop node (server 127.0.0.1). Returns @{Name;Port;Type} or $null #>
    param([Parameter(Mandatory)][string]$ProfilePath)
    $nodes = Get-ProxyNodes -ProfilePath $ProfilePath
    $hop = $nodes | Where-Object { $_.server -in @('127.0.0.1', 'localhost') } | Select-Object -First 1
    if (-not $hop) { return $null }
    $port = 11119
    if ($hop.port) { $port = [int]$hop.port }
    return [pscustomobject]@{ Name = $hop.name; Port = $port; Type = $hop.type }
}

function Get-StaticTarget {
    <# the NexIP socks5 node. Returns @{Name;Host;Port} or $null #>
    param([Parameter(Mandatory)][string]$ProfilePath)
    $nodes = Get-ProxyNodes -ProfilePath $ProfilePath
    $n = $nodes |
        Where-Object { $_.type -eq 'socks5' -and $_.server -and $_.server -notin @('127.0.0.1', 'localhost') } |
        Select-Object -First 1
    if (-not $n) {
        $n = $nodes | Where-Object { $_.server -and $_.server -notin @('127.0.0.1', 'localhost') } | Select-Object -First 1
    }
    if (-not $n) { return $null }
    return [pscustomobject]@{ Name = $n.name; Host = $n.server; Port = [int]$n.port }
}
