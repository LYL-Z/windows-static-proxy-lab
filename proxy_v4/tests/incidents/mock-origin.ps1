#Requires -Version 5.1
<#
.SYNOPSIS  Local loopback HTTP origin fixture for the INC checks.
.DESCRIPTION
  Listens on 127.0.0.1 only.  A GET is answered with 200 (body "ok").  A POST to a
  /upload-ok path is answered 200 (body "accepted"); every other POST is answered
  500 (body "upload-rejected"); anything else with 404.  No TLS, no external host,
  no file is read or written.  Used to prove GET/upload divergence (INC-04) and as
  the only forwarding destination of mock-proxy.ps1 (INC-03/05/08).
.PARAMETER Port
  TCP port to bind on 127.0.0.1.  Exit code 2 when the port cannot be bound.
#>
param(
    [Parameter(Mandatory = $true)][int]$Port
)
$ErrorActionPreference = 'Continue'

try {
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port)
    $listener.Start()
}
catch {
    Write-Error ("mock-origin: cannot listen on 127.0.0.1:{0}: {1}" -f $Port, $_.Exception.Message)
    exit 2
}

function Receive-Head([Net.Sockets.NetworkStream]$Stream) {
    $ms = New-Object System.IO.MemoryStream
    $buf = New-Object byte[] 4096
    while ($ms.Length -lt 65536) {
        $n = 0
        try { $n = $Stream.Read($buf, 0, $buf.Length) } catch { return $null }
        if ($n -le 0) { return $null }
        $ms.Write($buf, 0, $n)
        $arr = $ms.ToArray()
        for ($i = 3; $i -lt $arr.Length; $i++) {
            if ($arr[$i - 3] -eq 13 -and $arr[$i - 2] -eq 10 -and $arr[$i - 1] -eq 13 -and $arr[$i] -eq 10) {
                return [Text.Encoding]::ASCII.GetString($arr, 0, $i + 1)
            }
        }
    }
    return $null
}

while ($true) {
    try { $client = $listener.AcceptTcpClient() } catch { break }
    try {
        $client.ReceiveTimeout = 15000
        $stream = $client.GetStream()
        $head = Receive-Head $stream
        if ($null -ne $head -and $head -match '^POST ') {
            if ($head -match '^POST\s+[^\s]*/upload-ok') { $status = '200 OK'; $body = 'accepted' }
            else { $status = '500 Internal Server Error'; $body = 'upload-rejected' }
        }
        elseif ($null -ne $head -and $head -match '^GET ') { $status = '200 OK'; $body = 'ok' }
        else { $status = '404 Not Found'; $body = 'unexpected-request' }
        $resp = "HTTP/1.1 $status`r`nContent-Type: text/plain`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n$body"
        $bytes = [Text.Encoding]::ASCII.GetBytes($resp)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
    }
    catch { }
    try { $client.Close() } catch { }
}
try { $listener.Stop() } catch { }
