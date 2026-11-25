#Requires -Version 5.1
<#
Read-only TCP/DNS path probes. UDP/WebRTC is not probed (no generic safe UDP echo);
the output says udp = not_probed. No writes, no credentials.
#>
[CmdletBinding()]
param(
    [string]$Proxy = '',
    [string[]]$Urls = @('https://www.baidu.com','https://www.google.com'),
    [string[]]$DnsNames = @('www.baidu.com','www.google.com'),
    [switch]$Json,
    [switch]$Direct,
    [switch]$IPv4
)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'NetworkPathResult.ps1')
if ($Direct -and $Proxy) { throw 'Use either -Direct or -Proxy.' }
[uri]$proxyUri = $null
if ($Proxy) {
    $given = if ($Proxy -match '^\w+://') { $Proxy } else { 'http://' + $Proxy }
    if (-not [uri]::TryCreate($given, [UriKind]::Absolute, [ref]$proxyUri) -or
        $proxyUri.Scheme -notin @('http','https','socks4','socks4a','socks5','socks5h') -or
        -not $proxyUri.Host -or $proxyUri.UserInfo -or $proxyUri.AbsolutePath -ne '/' -or
        $proxyUri.Query -or $proxyUri.Fragment -or $given.Contains('@')) {
        throw 'Use an unauthenticated proxy endpoint without a path, query, or fragment.'
    }
}
$curl = Get-Command curl.exe -ErrorAction SilentlyContinue
# The legacy Windows argument marshaller drops an empty string without quoting.
$noProxyOverride = if ($PSVersionTable.PSVersion -lt [version]'7.3' -or $PSNativeCommandArgumentPassing -eq 'Legacy') { '""' } else { '' }
$http = @()
foreach ($u in $Urls) {
    [uri]$url = $null
    if (-not [uri]::TryCreate($u, [UriKind]::Absolute, [ref]$url) -or
        $url.Scheme -notin @('http','https') -or $url.UserInfo) {
        throw 'Probe URLs must use HTTP(S) and contain no credentials.'
    }
    $label = $url.GetLeftPart([UriPartial]::Path)
    if (-not $curl) { $http += [ordered]@{ url=$label; status='skipped'; code=$null; detail='curl.exe not found' }; continue }
    $curlArgs = @('-q','-sS','--max-time','12','-o','NUL','-w','%{http_code} %{http_connect}')
    if ($IPv4) { $curlArgs += '--ipv4' }
    if ($Proxy) { $curlArgs += @('-x',$Proxy,'--noproxy',$noProxyOverride) }
    if ($Direct) { $curlArgs += @('--noproxy','*') }
    $raw = (& $curl.Source @curlArgs -- $u 2>$null) -join ''
    $measurement = ConvertFrom-ProxyDoctorCurlResult -Raw $raw -ExitCode $LASTEXITCODE
    $measurement.url = $label
    $http += $measurement
}
$dns = @()
foreach ($n in $DnsNames) {
    try {
        $r = Resolve-DnsName -Name $n -Type A -DnsOnly -ErrorAction Stop | Where-Object { $_.Type -eq 'A' } | Select-Object -First 1
        $dns += [ordered]@{ name=$n; status=$(if ($r) { 'ok' } else { 'empty' }); address=$r.IPAddress }
    } catch { $dns += [ordered]@{ name=$n; status='failed'; address=$null } }
}
$out = [ordered]@{
    schema = 1
    ts = (Get-Date).ToString('o')
    proxy = $Proxy
    transportSelection = $(if ($Proxy) { 'explicit_proxy' } elseif ($Direct) { 'direct' } else { 'curl_environment' })
    socksDestinationResolution = switch ($proxyUri.Scheme) {
        'socks5' { 'client' }
        'socks5h' { 'proxy' }
        default { $null }
    }
    clientIPv4Requested = [bool]$IPv4
    http = @($http)
    dns = @($dns)
    udp = 'not_probed'
    notes = 'The DNS sample reports a Windows A answer. Browser/proxy resolver path and UDP/WebRTC require separate measurement.'
}
if ($Json) { $out | ConvertTo-Json -Depth 6 } else { $out | Format-List }
