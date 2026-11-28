#Requires -Version 5.1
<#
  Local protocol limits for CAB evidence.

  Uses one example.com system lookup and loopback sockets only.
  Does not change system DNS, the firewall, or the proxy.
  A passing run is not production protection.
#>
$ErrorActionPreference = 'Stop'

function Get-SettingsFingerprint {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $proxy = Get-ItemProperty -Path $key
    $dns = 'UNREAD'
    try {
        $dns = (@(Get-DnsClientServerAddress -ErrorAction Stop | ForEach-Object {
            $servers = @($_.ServerAddresses | Sort-Object) -join ','
            '{0}|{1}|{2}' -f $_.InterfaceIndex, $_.AddressFamily, $servers
        } | Sort-Object)) -join ';'
    } catch {
        $dns = 'UNREAD'
    }
    return [pscustomobject]@{
        ProxyEnable = [string]$proxy.ProxyEnable
        ProxyServer = [string]$proxy.ProxyServer
        ProxyOverride = [string]$proxy.ProxyOverride
        Dns = $dns
    }
}

function Get-ExampleDnsAnswer {
    $task = [System.Net.Dns]::GetHostAddressesAsync('example.com')
    if (-not $task.Wait(8000)) {
        return @{ Answered = $false; Count = 0 }
    }
    if ($task.IsFaulted -or $task.IsCanceled) {
        return @{ Answered = $false; Count = 0 }
    }
    $count = @($task.Result).Count
    return @{ Answered = ($count -gt 0); Count = $count }
}

function Get-LoopbackHttpStatus {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $client = $null
    $accepted = $null
    try {
        $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
        $client = [System.Net.Sockets.TcpClient]::new()
        $client.Connect([System.Net.IPAddress]::Loopback, $port)
        $accepted = $listener.AcceptTcpClient()
        $request = [Text.Encoding]::ASCII.GetBytes("GET /resolve?name=example.com&type=A HTTP/1.1`r`nHost: 127.0.0.1:$port`r`nConnection: close`r`n`r`n")
        $client.GetStream().Write($request, 0, $request.Length)
        $serverStream = $accepted.GetStream()
        $buffer = New-Object byte[] 2048
        $read = $serverStream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) { throw 'loopback receiver saw no HTTP request' }
        $response = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 204 No Content`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
        $serverStream.Write($response, 0, $response.Length)
        $client.GetStream().ReadTimeout = 2000
        $reply = New-Object byte[] 256
        $got = $client.GetStream().Read($reply, 0, $reply.Length)
        $text = [Text.Encoding]::ASCII.GetString($reply, 0, [Math]::Max($got, 0))
        if ($text -notmatch 'HTTP/1\.[01] (\d{3})') { throw 'loopback HTTP status line was missing' }
        return [int]$Matches[1]
    } finally {
        if ($accepted) { $accepted.Close() }
        if ($client) { $client.Close() }
        $listener.Stop()
    }
}

function Test-Ipv6Loopback {
    $server = $null
    $client = $null
    $accepted = $null
    try {
        $server = New-Object System.Net.Sockets.Socket (
            [System.Net.Sockets.AddressFamily]::InterNetworkV6,
            [System.Net.Sockets.SocketType]::Stream,
            [System.Net.Sockets.ProtocolType]::Tcp)
        $server.DualMode = $false
        $server.Bind((New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::IPv6Loopback, 0)))
        $server.Listen(1)
        $port = ([System.Net.IPEndPoint]$server.LocalEndPoint).Port
        $client = New-Object System.Net.Sockets.Socket (
            [System.Net.Sockets.AddressFamily]::InterNetworkV6,
            [System.Net.Sockets.SocketType]::Stream,
            [System.Net.Sockets.ProtocolType]::Tcp)
        $client.DualMode = $false
        $client.Connect([System.Net.IPAddress]::IPv6Loopback, $port)
        $accepted = $server.Accept()
        [void]$client.Send([byte[]](7))
        $accepted.ReceiveTimeout = 1500
        $buffer = New-Object byte[] 1
        $got = $accepted.Receive($buffer)
        return @{ Exchanged = ($got -eq 1 -and $buffer[0] -eq 7); ErrorCode = '' }
    } catch [System.Net.Sockets.SocketException] {
        return @{ Exchanged = $false; ErrorCode = [string]$_.Exception.ErrorCode }
    } catch {
        return @{ Exchanged = $false; ErrorCode = $_.Exception.GetType().Name }
    } finally {
        if ($accepted) { $accepted.Dispose() }
        if ($client) { $client.Dispose() }
        if ($server) { $server.Dispose() }
    }
}

$before = Get-SettingsFingerprint
$dns = Get-ExampleDnsAnswer
$status = Get-LoopbackHttpStatus
$ipv6 = Test-Ipv6Loopback
$browserCaptured = $false
$after = Get-SettingsFingerprint

$lines = @(
    'dnsResult=PathUnknown'
    ('dnsAnswered=' + $dns.Answered)
    ('dnsAnswerCount=' + $dns.Count)
    'dnsNote=system DNS answer is not a path proof'
    ('dohHttpStatus=' + $status)
    'browserDoh=NotTested'
    'dohNote=a DoH HTTP status is not browser DoH'
    ('ipv6LoopbackExchanged=' + $ipv6.Exchanged)
    ('ipv6Error=' + $ipv6.ErrorCode)
    'publicIpv6=NotTested'
    'ipv6Note=IPv6 loopback is not a public IPv6 path'
    'webrtc=NotTested'
    'turn=NotTested'
    'browserCaptured=False'
    'webrtcNote=WebRTC without a browser is NotTested'
    ('proxyUnchanged=' + ($before.ProxyEnable -eq $after.ProxyEnable -and $before.ProxyServer -eq $after.ProxyServer -and $before.ProxyOverride -eq $after.ProxyOverride))
    ('dnsServersUnchanged=' + ($before.Dns -eq $after.Dns))
)
$lines | ForEach-Object { Write-Output $_ }

$failed = $false
if ($dns.Answered -and ($lines -notcontains 'dnsResult=PathUnknown')) { $failed = $true }
if ($lines -notcontains 'browserDoh=NotTested') { $failed = $true }
if ($lines -notcontains 'publicIpv6=NotTested') { $failed = $true }
if ($lines -notcontains 'webrtc=NotTested') { $failed = $true }
if ($lines -notcontains 'turn=NotTested') { $failed = $true }
if ($browserCaptured) { $failed = $true }
if ($status -eq 204 -and ($lines -contains 'browserDoh=NotTested') -eq $false) { $failed = $true }
if ($lines -contains 'proxyUnchanged=False' -or $lines -contains 'dnsServersUnchanged=False') { $failed = $true }
foreach ($line in $lines) {
    if ($line -match 'PathKnown' -or $line -match '(?i)protected') { $failed = $true }
}
if ($failed) { exit 1 }
exit 0
