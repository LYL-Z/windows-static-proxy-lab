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
    [switch]$Json
)
$ErrorActionPreference = 'Continue'
$curl = Get-Command curl.exe -ErrorAction SilentlyContinue
$http = @()
foreach ($u in $Urls) {
    if (-not $curl) { $http += [ordered]@{ url=$u; status='skipped'; code=$null; detail='curl.exe not found' }; continue }
    $curlArgs = @('-sS','--max-time','12','--ssl-no-revoke','-o','NUL','-w','%{http_code}')
    if ($Proxy) { $curlArgs += @('-x',$Proxy) }
    $curlArgs += $u
    $code = & $curl.Source @curlArgs 2>$null
    $http += [ordered]@{ url=$u; status=$(if ($LASTEXITCODE -eq 0) { 'ok' } else { 'failed' }); code=[string]$code; detail='' }
}
$dns = @()
foreach ($n in $DnsNames) {
    try {
        $r = Resolve-DnsName -Name $n -Type A -ErrorAction Stop | Where-Object { $_.IPAddress } | Select-Object -First 1
        $dns += [ordered]@{ name=$n; status=$(if ($r) { 'ok' } else { 'empty' }); address=$r.IPAddress }
    } catch { $dns += [ordered]@{ name=$n; status='failed'; address=$null } }
}
$out = [ordered]@{
    schema = 1
    ts = (Get-Date).ToString('o')
    proxy = $Proxy
    http = @($http)
    dns = @($dns)
    udp = 'not_probed'
    notes = 'TCP/DNS only. WebRTC/UDP needs a browser or protocol-specific probe.'
}
if ($Json) { $out | ConvertTo-Json -Depth 6 } else { $out | Format-List }
