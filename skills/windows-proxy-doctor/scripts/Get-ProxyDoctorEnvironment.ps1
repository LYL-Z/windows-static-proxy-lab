#Requires -Version 5.1
<#
Discovers local Windows proxy capabilities without changing settings or contacting
an endpoint. Fixtures replace the entire live collection.
#>
[CmdletBinding()]
param(
    [switch]$Json,
    [switch]$AsObject,
    [string]$TestFixture,
    [ValidateSet('UNKNOWN', 'AVAILABLE', 'UNAVAILABLE')][string]$BrowserTool = 'UNKNOWN',
    [ValidateSet('UNKNOWN', 'AVAILABLE', 'UNAVAILABLE')][string]$DesktopTool = 'UNKNOWN',
    [ValidateRange(1, 65535)][int[]]$CheckPort = @()
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProxyListeners.ps1')
. (Join-Path $PSScriptRoot 'ProxyTarget.ps1')

# Match canonical product names and process basenames only. Never publish an
# unrecognized process name, registry entry, command line or filesystem path.
$products = [ordered]@{
    starsky    = @{ name = '^StarSky(?:\s|$)'; processes = @('starsky', 'magicspeed') }
    clashVerge = @{ name = '^Clash Verge(?:\s|$)'; processes = @('clash-verge') }
    mihomo     = @{ name = '^Mihomo(?:\s|$)'; processes = @('mihomo', 'verge-mihomo', 'clash-meta') }
    edge       = @{ name = '^Microsoft Edge$'; processes = @('msedge') }
    chrome     = @{ name = '^Google Chrome(?:\s|$)'; processes = @('chrome') }
    firefox    = @{ name = '^Mozilla Firefox(?:\s|$)'; processes = @('firefox') }
    wireguard  = @{ name = '^WireGuard(?:\s|$)'; processes = @('wireguard') }
    openvpn    = @{ name = '^OpenVPN(?:\s|$)'; processes = @('openvpn', 'openvpn-gui', 'openvpnconnect') }
    tailscale  = @{ name = '^Tailscale(?:\s|$)'; processes = @('tailscale', 'tailscaled', 'tailscale-ipn') }
    zeroTier   = @{ name = '^ZeroTier(?:\s|$)'; processes = @('zerotier-one_x64', 'zerotier-one_x86', 'zerotier_desktop_ui') }
    easyConnect = @{ name = '^EasyConnect(?:\s|$)'; processes = @('easyconnect') }
    v2rayN     = @{ name = '^v2rayN(?:\s|$)'; processes = @('v2rayn') }
    singBox    = @{ name = '^sing-box(?:\s|$)'; processes = @('sing-box') }
    hiddify    = @{ name = '^Hiddify(?:\s|$)'; processes = @('hiddify') }
    clash      = @{ name = '^Clash for Windows(?:\s|$)'; processes = @('clash for windows', 'clash-win64') }
    warp       = @{ name = '^Cloudflare WARP(?:\s|$)'; processes = @('warp-svc', 'cloudflare warp') }
    mullvad    = @{ name = '^Mullvad VPN(?:\s|$)'; processes = @('mullvad vpn', 'mullvad-daemon') }
    nordVpn    = @{ name = '^NordVPN(?:\s|$)'; processes = @('nordvpn', 'nordvpn-service') }
    protonVpn  = @{ name = '^Proton\s?VPN(?:\s|$)'; processes = @('protonvpn', 'protonvpn-service') }
    proxifier  = @{ name = '^Proxifier(?:\s|$)'; processes = @('proxifier') }
}

function Get-ObservedVersion([string]$Version) {
    if ($Version -match '^v?(\d+(?:\.\d+){0,5})(?:[^a-z0-9.]|$)' -and $Matches[1].Length -le 48) {
        return $Matches[1]
    }
    return $null
}

function Get-PortableWindowsFacts {
    $os = $null
    $architecture = 'UNKNOWN'
    $administrator = $null
    try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop }
    catch { }
    try {
        $arch = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToUpperInvariant()
        if ($arch -in @('X86', 'X64', 'ARM', 'ARM64')) { $architecture = $arch }
    } catch {
        $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
        if ($arch -eq 'AMD64') { $architecture = 'X64' }
        elseif ($arch -in @('X86', 'ARM', 'ARM64')) { $architecture = $arch.ToUpperInvariant() }
    }
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        try {
            $principal = [Security.Principal.WindowsPrincipal]::new($identity)
            $administrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        } finally { $identity.Dispose() }
    } catch { }

    [int]$build = 0
    $version = Get-ObservedVersion $os.Version
    $family = 'UNKNOWN'
    $supported = $null
    if ($os -and $os.ProductType -in @(1, 2, 3) -and [int]::TryParse($os.BuildNumber, [ref]$build)) {
        $family = if ($os.ProductType -in @(2, 3)) { 'WINDOWS_SERVER' }
            elseif ($build -ge 22000) { 'WINDOWS_11' }
            elseif ($build -ge 10240) { 'WINDOWS_10' }
            else { 'OTHER_WINDOWS' }
        $supported = $family -in @('WINDOWS_10', 'WINDOWS_11')
    }
    return @{ version = $version; build = $(if ($build -gt 0) { $build } else { $null }); family = $family; supported = $supported
        architecture = $architecture; powerShell = $PSVersionTable.PSVersion.ToString()
        administrator = $administrator }
}

function Get-LocalAppRegistration {
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $ok = $true
    $views = @([Microsoft.Win32.RegistryView]::Registry32)
    if ([Environment]::Is64BitOperatingSystem) { $views += [Microsoft.Win32.RegistryView]::Registry64 }
    foreach ($hive in @([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryHive]::CurrentUser)) {
        $scope = if ($hive -eq [Microsoft.Win32.RegistryHive]::LocalMachine) { 'MACHINE' } else { 'CURRENT_USER' }
        foreach ($view in $views) {
            $root = $null
            $uninstall = $null
            try {
                $root = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, $view)
                $uninstall = $root.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Uninstall')
                if ($null -eq $uninstall) { continue }
                foreach ($subKey in $uninstall.GetSubKeyNames()) {
                    $app = $null
                    try {
                        $app = $uninstall.OpenSubKey($subKey)
                        if ($app) {
                            $name = [string]$app.GetValue('DisplayName', '')
                            if ($name) {
                                $rows.Add(@{ name = $name; scope = $scope; version = [string]$app.GetValue('DisplayVersion', '') })
                            }
                        }
                    } catch { $ok = $false }
                    finally { if ($app) { $app.Dispose() } }
                }
            } catch { $ok = $false }
            finally {
                if ($uninstall) { $uninstall.Dispose() }
                if ($root) { $root.Dispose() }
            }
        }
    }
    return @{ queryOk = $ok; rows = $rows.ToArray() }
}

function Get-LocalProcessFacts {
    try {
        $knownNames = @($products.Values | ForEach-Object { $_.processes } | Select-Object -Unique)
        $items = @(Get-Process -ErrorAction Stop | ForEach-Object {
            $name = $_.ProcessName
            $version = $null
            if ($name -in $knownNames) {
                try { $version = Get-ObservedVersion $_.FileVersion } catch { }
            }
            @{ name = $name; id = $_.Id; version = $version }
        })
        return @{ queryOk = $true; rows = $items }
    } catch { return @{ queryOk = $false; rows = @() } }
}

function Get-WinHttpMode {
    try {
        $netsh = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'netsh.exe'
        $raw = (& $netsh winhttp show proxy 2>$null) -join "`n"
        if ($LASTEXITCODE -eq 0) {
            if ($raw -match '(?i)Direct access\s*\(no proxy server\)|\u76f4\u63a5\u8bbf\u95ee[^\r\n]*\u6ca1\u6709\u4ee3\u7406\u670d\u52a1\u5668') { return 'DIRECT' }
            if ($raw -match '(?im)(?:Proxy Server\(s\)|Proxy Server|\u4ee3\u7406\u670d\u52a1\u5668)\s*[:\uff1a]\s*\S+') { return 'CONFIGURED' }
        }
    } catch { }
    return 'UNKNOWN'
}

function Get-LocalBinding([string]$Address) {
    if ($Address -in @('0.0.0.0', '::')) { return 'ALL_INTERFACES' }
    [Net.IPAddress]$ip = $null
    if (-not [Net.IPAddress]::TryParse($Address, [ref]$ip)) { return 'UNKNOWN' }
    if ([Net.IPAddress]::IsLoopback($ip)) { return 'LOOPBACK' }
    return 'OTHER_INTERFACE'
}

function Get-LoopbackProxyEndpoint([string]$Server) {
    $endpointPattern = '(?i)(?:(https?)://)?(127\.0\.0\.1|localhost|\[::1\]):(\d{1,5})'
    $mapped = $Server.Contains('=')
    $pairs = @(if ($mapped) {
        foreach ($entry in $Server.Split(';')) {
            $pair = $entry.Split('=', 2)
            if ($pair.Count -eq 2 -and $pair[0].Trim() -in @('http','https')) { $pair[1].Trim() }
        }
    } else { $Server.Trim() })
    $candidate = [regex]::Match([string]($pairs | Select-Object -First 1), "^$endpointPattern$")
    if (-not $candidate.Success) { return $null }
    $port = [int]$candidate.Groups[3].Value
    if ((Test-ProxyDoctorTarget -Server $Server -Port $port)) {
        $hosts = @(foreach ($endpoint in $pairs) {
            [regex]::Match($endpoint, "^$endpointPattern$").Groups[2].Value.ToLowerInvariant()
        })
        if (@($hosts | Sort-Object -Unique).Count -ne 1) { return $null }
        return @{
            port = $port
            host = $hosts[0]
            scheme = $(if (-not $mapped -and $candidate.Groups[1].Success) { $candidate.Groups[1].Value.ToLowerInvariant() } else { $null })
        }
    }
    return $null
}

function Test-ProxyListeningAddress([string]$TargetHost, [string]$Address) {
    switch ($TargetHost) {
        '127.0.0.1' { return $Address -in @('127.0.0.1', '0.0.0.0') }
        '[::1]' { return $Address -in @('::1', '::') }
        default { return $Address -in @('127.0.0.1', '0.0.0.0', '::1', '::') }
    }
}

function Get-DiscoveryProduct([string]$Product) {
    $pattern = $products[$Product]
    $registered = @($facts.installedApps | Where-Object { $_.name -match $pattern.name })
    $active = @($facts.processes | Where-Object { ([string]$_.name -replace '(?i)\.exe$', '') -in $pattern.processes })
    $scopes = @($registered.scope | Where-Object { $_ -in @('MACHINE', 'CURRENT_USER') } | Sort-Object -Unique)
    $scope = if ($scopes.Count -gt 1) { 'MULTIPLE' } elseif ($scopes.Count -eq 1) { $scopes[0] } else { 'UNKNOWN' }
    $running = if ($active.Count) { $true } elseif ($facts.processQueryOk -eq $true) { $false } else { $null }
    $versions = @(@($active.version) + @($registered.version) | ForEach-Object {
        $version = Get-ObservedVersion $_
        if ($version) { $version }
    } | Sort-Object -Unique)
    $evidence = @(if ($registered.Count) { 'UNINSTALL_REGISTRATION' }; if ($active.Count) { 'PROCESS_BASENAME' })
    return [ordered]@{
        installation = $(if ($registered.Count) { 'REGISTERED' } elseif ($active.Count) { 'PORTABLE_OR_UNREGISTERED' } else { 'UNKNOWN' })
        running = $running
        scope = $scope
        version = $(if ($versions.Count -eq 1) { $versions[0] } else { $null })
        versions = $versions
        evidence = $evidence
    }
}

if ($TestFixture) {
    try { $facts = Get-Content -LiteralPath $TestFixture -Raw | ConvertFrom-Json }
    catch { throw 'The environment fixture could not be read as JSON.' }
    if ($facts -isnot [pscustomobject]) { throw 'The environment fixture must be one JSON object.' }
} elseif ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    $registration = Get-LocalAppRegistration
    $processes = Get-LocalProcessFacts
    $listeners = Get-ProxyDoctorListeners -AllBindings
    $proxy = $null
    try { $proxy = & (Join-Path $PSScriptRoot 'Get-ProxyDoctorSnapshot.ps1') -AsObject -FirstHopPort 0 }
    catch { }
    $facts = @{
        windows = Get-PortableWindowsFacts
        installedApps = $registration.rows; registryQueryOk = $registration.queryOk
        processes = $processes.rows; processQueryOk = $processes.queryOk
        listeners = @($listeners.rows | ForEach-Object { @{ port = $_.LocalPort; address = $_.LocalAddress; pid = $_.OwningProcess } })
        listenerQueryOk = $listeners.queryOk
        proxy = $proxy
        winHttp = Get-WinHttpMode
    }
} else {
    $facts = @{ windows = @{ supported = $false; powerShell = $PSVersionTable.PSVersion.ToString() } }
}

$clients = [ordered]@{}
foreach ($name in @('starsky', 'clashVerge', 'mihomo')) { $clients[$name] = Get-DiscoveryProduct $name }
$browsers = [ordered]@{}
foreach ($name in @('edge', 'chrome', 'firefox')) { $browsers[$name] = Get-DiscoveryProduct $name }
$other = @(foreach ($name in $products.Keys) {
    if ($name -notin $clients.Keys -and $name -notin $browsers.Keys) {
        $details = Get-DiscoveryProduct $name
        if ($details.installation -ne 'UNKNOWN') { $details.id = $name; $details }
    }
})

$proxyEndpoint = Get-LoopbackProxyEndpoint ([string]$facts.proxy.proxyServer)
$targetPort = $proxyEndpoint.port
$watched = @($CheckPort) + @($targetPort)
$byPid = @{}
foreach ($process in $facts.processes) {
    [int]$processId = 0
    if (-not [int]::TryParse([string]$process.id, [ref]$processId) -or $processId -lt 0) { continue }
    $processName = [string]$process.name -replace '(?i)\.exe$', ''
    $product = @($products.Keys | Where-Object { $processName -in $products[$_].processes } | Select-Object -First 1)
    $byPid[$processId] = if ($product.Count) { @{ name = $processName.ToLowerInvariant(); client = $product[0] } }
        else { @{ name = 'OTHER_PROCESS'; client = $null } }
}
$targetOwners = New-Object 'System.Collections.Generic.List[string]'
$portRows = @(foreach ($listener in $facts.listeners) {
    [int]$port = 0
    if (-not [int]::TryParse([string]$listener.port, [ref]$port) -or $port -lt 1 -or $port -gt 65535) { continue }
    $binding = Get-LocalBinding $listener.address
    [int]$ownerId = 0
    $owner = if ([int]::TryParse([string]$listener.pid, [ref]$ownerId)) { $byPid[$ownerId] }
    if ($owner.client -in $browsers.Keys) { $owner = @{ name = 'OTHER_PROCESS'; client = $null } }
    if ($port -eq $targetPort -and (Test-ProxyListeningAddress $proxyEndpoint.host $listener.address)) {
        $targetOwners.Add($(if ($owner.name -eq 'OTHER_PROCESS') { 'OTHER_PROCESS' } else { [string]$owner.client }))
    }
    if ($port -in $watched -or $owner.client) {
        [pscustomobject]@{ port = $port; binding = $binding; owner = $(if ($owner) { $owner.name } else { 'UNKNOWN' }); client = $owner.client }
    }
})
$portRows = @($portRows | Sort-Object -Property port,binding,owner,client -Unique)
$distinctOwners = @($targetOwners | Sort-Object -Unique)
$source = if ($TestFixture) { 'test-fixture' } else { 'live-read-only' }
$family = if ($facts.windows.family -in @('WINDOWS_10','WINDOWS_11','WINDOWS_SERVER','OTHER_WINDOWS')) { $facts.windows.family } else { 'UNKNOWN' }
$architecture = if ($facts.windows.architecture -in @('X86','X64','ARM','ARM64')) { $facts.windows.architecture } else { 'UNKNOWN' }
$winHttp = if ($facts.winHttp -in @('DIRECT','CONFIGURED')) { $facts.winHttp } else { 'UNKNOWN' }
$out = [ordered]@{
    schema = 1
    source = $source
    windows = [ordered]@{
        family = $family; version = Get-ObservedVersion $facts.windows.version
        build = Get-ObservedVersion $facts.windows.build; architecture = $architecture
        powerShell = Get-ObservedVersion $facts.windows.powerShell
        supported = $(if ($facts.windows.supported -is [bool]) { $facts.windows.supported } else { $null })
        administrator = $(if ($facts.windows.administrator -is [bool]) { $facts.windows.administrator } else { $null })
    }
    clients = $clients
    browsers = $browsers
    otherClients = $other
    registrationCoverage = $(if ($facts.registryQueryOk -eq $true) { 'MACHINE_AND_CURRENT_USER' } else { 'INCOMPLETE' })
    processQueryStatus = $(if ($facts.processQueryOk -eq $true) { 'OK' } else { 'UNKNOWN' })
    proxy = [ordered]@{
        manualEnabled = $(if ($facts.proxy.proxyEnabled -is [bool]) { $facts.proxy.proxyEnabled } else { $null })
        server = $(if ($targetPort) { "loopback port $targetPort" } elseif ($facts.proxy.proxyServer) { '[redacted]' } else { $null })
        scheme = $proxyEndpoint.scheme
        host = $proxyEndpoint.host
        targetPort = $targetPort
        targetListenerObserved = $(if ($targetPort -and $facts.listenerQueryOk -eq $true) { $targetOwners.Count -gt 0 } else { $null })
        targetClient = $(if ($distinctOwners.Count -eq 1 -and $distinctOwners[0] -in $products.Keys) { $distinctOwners[0] } else { $null })
        targetIsOtherProcess = ($distinctOwners.Count -eq 1 -and $distinctOwners[0] -eq 'OTHER_PROCESS')
        pacConfigured = $(if ($facts.proxy.pacConfigured -is [bool]) { $facts.proxy.pacConfigured } else { $null })
        clashSavedEnabled = $(if ($facts.proxy.uiEnabled -is [bool]) { $facts.proxy.uiEnabled } else { $null })
        winHttp = $winHttp
    }
    listeners = [ordered]@{ queryStatus = $(if ($facts.listenerQueryOk -eq $true) { 'OK' } else { 'UNKNOWN' }); entries = $portRows }
    tools = [ordered]@{ browser = $BrowserTool.ToUpperInvariant(); desktop = $DesktopTool.ToUpperInvariant() }
}
if ($Json -and -not $AsObject) { $out | ConvertTo-Json -Depth 9 }
else { [pscustomobject]$out }
