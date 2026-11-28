#Requires -Version 5.1
<#
.SYNOPSIS  Local loopback HTTP proxy fixture for the INC checks.
.DESCRIPTION
  Modes (one per fixture process):
    fail      every request is answered with 502 Bad Gateway
    drop      TCP is accepted, the request is read, then the socket is closed
              with no response at all (the NexIP "accept then drop" symptom)
    alternate odd connection -> forwarded, even connection -> 502; deterministic,
              not time based, so an intermittency check cannot flake
    forward   every request is forwarded to the local origin

  F62: the fixture can never reach the public network.  A request is only dialled
  when its host is a loopback name AND its port equals -OriginPort; everything else
  is answered 502 and never connected.  There is no CONNECT tunnel: every fixture
  URL is plain http to the local origin, so no TLS handshake and no external host
  is involved.

  All bytes stay on 127.0.0.1.  No file is written.

.PARAMETER Port
  TCP port to bind on 127.0.0.1.
.PARAMETER Mode
  fail | drop | alternate | forward.
.PARAMETER OriginPort
  The only port forwarding is allowed to.  Required for alternate/forward.
#>
param(
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][ValidateSet('fail', 'drop', 'alternate', 'forward')][string]$Mode,
    [int]$OriginPort = 0
)
$ErrorActionPreference = 'Continue'

$loopbackNames = @('127.0.0.1', 'localhost', '::1')

function Send-Bytes([Net.Sockets.NetworkStream]$Stream, [byte[]]$Bytes) {
    if ($null -ne $Bytes -and $Bytes.Length -gt 0) {
        $Stream.Write($Bytes, 0, $Bytes.Length)
        $Stream.Flush()
    }
}

function Send-Status([Net.Sockets.NetworkStream]$Stream, [string]$Status) {
    $resp = "HTTP/1.1 $Status`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"
    Send-Bytes $Stream ([Text.Encoding]::ASCII.GetBytes($resp))
}

function Receive-Request([Net.Sockets.NetworkStream]$Stream) {
    $ms = New-Object System.IO.MemoryStream
    $buf = New-Object byte[] 8192
    $headEnd = -1
    while ($headEnd -lt 0) {
        $n = 0
        try { $n = $Stream.Read($buf, 0, $buf.Length) } catch { return $null }
        if ($n -le 0) { return $null }
        $ms.Write($buf, 0, $n)
        $arr = $ms.ToArray()
        for ($i = 3; $i -lt $arr.Length; $i++) {
            if ($arr[$i - 3] -eq 13 -and $arr[$i - 2] -eq 10 -and $arr[$i - 1] -eq 13 -and $arr[$i] -eq 10) {
                $headEnd = $i + 1
                break
            }
        }
    }
    $all = $ms.ToArray()
    $headText = [Text.Encoding]::ASCII.GetString($all, 0, $headEnd)
    $declared = 0
    if ($headText -match '(?im)^Content-Length:\s*(\d+)') { $declared = [int]$Matches[1] }
    $body = New-Object byte[] 0
    if ($all.Length -gt $headEnd) { [byte[]]$body = $all[$headEnd..($all.Length - 1)] }
    while ($body.Length -lt $declared) {
        $want = [Math]::Min($buf.Length, $declared - $body.Length)
        $n = 0
        try { $n = $Stream.Read($buf, 0, $want) } catch { break }
        if ($n -le 0) { break }
        $grown = New-Object byte[] ($body.Length + $n)
        [Array]::Copy($body, 0, $grown, 0, $body.Length)
        [Array]::Copy($buf, 0, $grown, $body.Length, $n)
        $body = $grown
    }
    return [pscustomobject]@{ Head = $headText; Body = $body }
}

function Invoke-Forward($Request, [Net.Sockets.NetworkStream]$ClientStream) {
    $lines = $Request.Head -split "`r`n"
    if (-not $lines -or $lines[0] -notmatch '^([A-Za-z]+)\s+(\S+)\s+HTTP/\d') {
        Send-Status $ClientStream '502 Bad Gateway'; return
    }
    $method = $Matches[1]
    $target = $Matches[2]

    # CONNECT is not supported: the fixtures use plain http to the local origin.
    if ($method -eq 'CONNECT') { Send-Status $ClientStream '502 Bad Gateway'; return }

    $hostName = ''
    $portNo = 0
    $path = $target
    if ($target -match '^(?i)https?://') {
        $u = $null
        if (-not [Uri]::TryCreate($target, [UriKind]::Absolute, [ref]$u)) {
            Send-Status $ClientStream '502 Bad Gateway'; return
        }
        if ($u.Scheme -ne 'http') { Send-Status $ClientStream '502 Bad Gateway'; return }
        $hostName = $u.Host
        $portNo = $u.Port
        $path = $u.PathAndQuery
    }
    else {
        if ($Request.Head -match '(?im)^Host:\s*(.+?)\s*$') {
            $hv = $Matches[1]
            if ($hv -match '^([^:]+):(\d+)$') { $hostName = $Matches[1]; $portNo = [int]$Matches[2] }
            else { $hostName = $hv; $portNo = 80 }
        }
        $path = $target
    }

    # F62 hard stop: loopback only, and only the declared local origin port.
    $allowed = ($loopbackNames -contains $hostName) -and ($portNo -gt 0)
    if ($OriginPort -gt 0 -and $portNo -ne $OriginPort) { $allowed = $false }
    if (-not $allowed) { Send-Status $ClientStream '502 Bad Gateway'; return }

    $rest = @($lines | Select-Object -Skip 1 | Where-Object {
        $_ -ne '' -and
        $_ -notmatch '^(?i)Proxy-Connection:' -and
        $_ -notmatch '^(?i)Proxy-Authorization:' -and
        $_ -notmatch '^(?i)Connection:'
    })
    $upHead = ("{0} {1} HTTP/1.1`r`n{2}`r`nConnection: close`r`n`r`n" -f $method, $path, ($rest -join "`r`n"))

    $up = New-Object Net.Sockets.TcpClient
    try { $up.Connect([Net.IPAddress]::Loopback, $portNo) }
    catch {
        Send-Status $ClientStream '502 Bad Gateway'
        try { $up.Close() } catch { }
        return
    }
    try {
        $up.ReceiveTimeout = 15000
        $upStream = $up.GetStream()
        Send-Bytes $upStream ([Text.Encoding]::ASCII.GetBytes($upHead))
        Send-Bytes $upStream $Request.Body
        $rb = New-Object byte[] 8192
        while ($true) {
            $n = 0
            try { $n = $upStream.Read($rb, 0, $rb.Length) } catch { break }
            if ($n -le 0) { break }
            Send-Bytes $ClientStream $rb[0..($n - 1)]
        }
    }
    catch { }
    finally { try { $up.Close() } catch { } }
}

try {
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port)
    $listener.Start()
}
catch {
    Write-Error ("mock-proxy: cannot listen on 127.0.0.1:{0}: {1}" -f $Port, $_.Exception.Message)
    exit 2
}

$connection = 0
while ($true) {
    try { $client = $listener.AcceptTcpClient() } catch { break }
    $connection++
    try {
        $client.ReceiveTimeout = 15000
        $stream = $client.GetStream()
        $request = Receive-Request $stream
        if ($null -eq $request) { try { $client.Close() } catch { }; continue }

        if ($Mode -eq 'drop') {
            # accept, then close with no response at all
            try { $client.Close() } catch { }
            continue
        }

        $forward = switch ($Mode) {
            'fail' { $false }
            'alternate' { (($connection % 2) -eq 1) }
            'forward' { $true }
            default { $false }
        }
        if (-not $forward) {
            Send-Status $stream '502 Bad Gateway'
            try { $client.Close() } catch { }
            continue
        }

        Invoke-Forward $request $stream
        try { $client.Close() } catch { }
    }
    catch {
        try { $client.Close() } catch { }
    }
}
try { $listener.Stop() } catch { }
