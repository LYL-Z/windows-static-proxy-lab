# Query the running Mihomo core through its Windows named-pipe external controller.
# Read-only unless -Method PUT/PATCH -Body <json> is supplied.
#   .\mihomo_api.ps1 -Path /configs
#   .\mihomo_api.ps1 -Path "/proxies" -Raw
param(
    [string]$Path = "/configs",
    [string]$Method = "GET",
    [string]$Body = $null,
    [int]$TimeoutMs = 8000,
    [switch]$Raw
)
$ErrorActionPreference = 'Stop'
$pipeName = 'verge-mihomo-sidecar-release-582392de1c279b7f7ab1f8c38277da07a8b55c8486ecf17cc5c285d158fec75f'
$secret = 'set-your-secret'

$c = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pipeName,
        [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
try { $c.Connect(3000) } catch { Write-Output "PIPE_CONNECT_FAILED: $($_.Exception.Message)"; exit 2 }

$bodyBytes = $null
if ($Body) { $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Body) }
$sb = New-Object System.Text.StringBuilder
[void]$sb.Append("$Method $Path HTTP/1.1`r`n")
[void]$sb.Append("Host: localhost`r`n")
[void]$sb.Append("Authorization: Bearer $secret`r`n")
[void]$sb.Append("Accept: application/json`r`n")
[void]$sb.Append("Content-Type: application/json`r`n")
if ($bodyBytes) { [void]$sb.Append("Content-Length: $($bodyBytes.Length)`r`n") }
[void]$sb.Append("Connection: close`r`n`r`n")
$head = [System.Text.Encoding]::ASCII.GetBytes($sb.ToString())

$c.Write($head, 0, $head.Length)
if ($bodyBytes) { $c.Write($bodyBytes, 0, $bodyBytes.Length) }
$c.Flush()

$ms = New-Object System.IO.MemoryStream
$buf = New-Object byte[] 65536
$deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
while ([DateTime]::UtcNow -lt $deadline) {
    $task = $c.ReadAsync($buf, 0, $buf.Length)
    if (-not $task.Wait([Math]::Max(200, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))) { break }
    $n = $task.Result
    if ($n -le 0) { break }
    $ms.Write($buf, 0, $n)
}
$c.Dispose()

$all = $ms.ToArray()
if (-not $all -or $all.Length -eq 0) { Write-Output "EMPTY_RESPONSE (no data from core)"; exit 3 }

# byte-level header/body split
$hdrEnd = -1
for ($i = 0; $i -lt $all.Length - 3; $i++) {
    if ($all[$i] -eq 13 -and $all[$i+1] -eq 10 -and $all[$i+2] -eq 13 -and $all[$i+3] -eq 10) { $hdrEnd = $i; break }
}
if ($hdrEnd -lt 0) { Write-Output "RAW_NON_HTTP: $([System.Text.Encoding]::UTF8.GetString($all,0,[Math]::Min(300,$all.Length)))"; exit 0 }
$headText = [System.Text.Encoding]::ASCII.GetString($all, 0, $hdrEnd)
$bodyLen  = $all.Length - ($hdrEnd + 4)
$bodyArr  = New-Object byte[] $bodyLen
[Array]::Copy($all, $hdrEnd + 4, $bodyArr, 0, $bodyLen)

# de-chunk if needed
if ($headText -match '(?i)transfer-encoding:\s*chunked') {
    $out = New-Object System.IO.MemoryStream
    $p = 0
    while ($p -lt $bodyArr.Length) {
        $j = $p
        while ($j + 1 -lt $bodyArr.Length -and -not ($bodyArr[$j] -eq 13 -and $bodyArr[$j+1] -eq 10)) { $j++ }
        if ($j + 1 -ge $bodyArr.Length) { break }
        $line = [System.Text.Encoding]::ASCII.GetString($bodyArr, $p, $j - $p)
        $hex = ($line -split ';')[0].Trim()
        if (-not $hex) { break }
        try { $len = [Convert]::ToInt32($hex, 16) } catch { break }
        if ($len -le 0) { break }
        $start = $j + 2
        if ($start + $len -gt $bodyArr.Length) { $len = $bodyArr.Length - $start }
        $out.Write($bodyArr, $start, $len)
        $p = $start + $len + 2
    }
    $bodyArr = $out.ToArray()
}

$statusLine = ($headText -split "`r`n")[0]
$payload = [System.Text.Encoding]::UTF8.GetString($bodyArr)
if ($Raw) { Write-Output "[$statusLine]"; Write-Output $payload; exit 0 }
Write-Output "[$statusLine]"
Write-Output $payload
