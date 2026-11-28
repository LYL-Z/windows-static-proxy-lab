#Requires -Version 5.1
<#
.SYNOPSIS
  Controlled, disjoint-profile WebRTC candidate probe for a Chromium browser
  (Edge/Chrome) driven over the DevTools protocol.  Read-only with respect to
  the machine; it only talks to the declared STUN server in a throwaway profile.

.DESCRIPTION
  Why this exists: a STUN probe proves which UDP egress this machine has, but
  only the browser itself can show which candidates a WebRTC session would
  advertise (host / mDNS / server-reflexive).  This script measures exactly
  that without touching the user's browser data:

    * a NEW throwaway --user-data-dir under %TEMP% is created and deleted; the
      user's real profile is never opened, never read, never modified
    * --headless, --no-first-run, --no-default-browser-check; no extensions
    * the page is a generated local file; the only external target is the
      declared STUN server below
    * the browser process is killed at the end of the run
    * no TUN/proxy/DNS/route/firewall change of any kind

  It must be requested explicitly (-Consent) because it starts a browser.

  Output fields:
    candidates       raw ICE candidate lines the browser produced
    hostMdns         host candidates whose address is an mDNS name (.local)
    hostIpLiteral    host candidates with a literal address (this is the
                     "local address exposed" case)
    srflx            server-reflexive addresses = the public UDP egress
    verdict          ONE_OF: NO_CANDIDATES | HOST_ONLY | SRFLX_PUBLIC |
                     UNVERIFIED
    error            present when the run could not be completed

.EXAMPLE
  .\webrtc-browser-probe.ps1 -Consent
  .\webrtc-browser-probe.ps1 -Consent -Json -GatherSeconds 12
#>
[CmdletBinding()]
param(
    [switch]$Consent,
    [string]$StunUrl = 'stun:stun.cloudflare.com:3478',
    [int]$GatherSeconds = 12,
    [string]$BrowserPath = '',
    [switch]$Json
)
$ErrorActionPreference = 'Continue'

$evidenceTime = [datetimeoffset]::Now.ToString('o')
$result = [ordered]@{
    observedAt        = $evidenceTime
    tool              = 'webrtc-browser-probe.ps1'
    readOnly          = $true
    profileIsThrowaway = $true
    usedUserProfile   = $false
    declaredStunUrl   = $StunUrl
    candidates        = @()
    hostMdns          = @()
    hostIpLiteral     = @()
    srflx             = @()
    verdict           = 'UNVERIFIED'
    error             = $null
}

if (-not $Consent) {
    $result.error = 'consent_required: pass -Consent to start a throwaway headless browser'
    if ($Json) { $result | ConvertTo-Json -Depth 6 } else { Write-Host ('  UNVERIFIED: {0}' -f $result.error) -ForegroundColor Yellow }
    exit 2
}

function Find-Browser {
    param([string]$Explicit)
    if ($Explicit -and (Test-Path -LiteralPath $Explicit)) { return $Explicit }
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe'),
        (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe')
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    return $null
}

$browser = Find-Browser -Explicit $BrowserPath
if (-not $browser) {
    $result.error = 'no Chromium browser found (Edge/Chrome)'
    if ($Json) { $result | ConvertTo-Json -Depth 6 } else { Write-Host ('  UNVERIFIED: {0}' -f $result.error) -ForegroundColor Yellow }
    exit 2
}
$result.browser = $browser

# A throwaway profile directory that this script owns end to end.
$tempRoot = [IO.Path]::GetFullPath($env:TEMP)
$workDir = Join-Path $tempRoot ('webrtc-browser-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workDir -Force | Out-Null
$result.userDataDirClass = 'throwaway under %TEMP%'

$html = @"
<!doctype html><html><head><meta charset="utf-8"><title>pending</title></head>
<body><pre id="out">pending</pre>
<script>
const cands = [];
const pc = new RTCPeerConnection({iceServers:[{urls:'$StunUrl'}]});
pc.createDataChannel('probe');
pc.onicecandidate = (e) => { if (e.candidate && e.candidate.candidate) cands.push(e.candidate.candidate); };
pc.createOffer().then(o => pc.setLocalDescription(o));
setTimeout(() => {
  document.getElementById('out').textContent = 'RESULT:' + JSON.stringify({count: cands.length, candidates: cands});
}, $($GatherSeconds * 1000));
</script></body></html>
"@
$pagePath = Join-Path $workDir 'probe.html'
Set-Content -LiteralPath $pagePath -Value $html -Encoding UTF8
$pageUrl = 'file:///' + ($pagePath -replace '\\', '/')

# Pick a free, deterministic-range debugging port (ephemeral ports are avoided
# because Chromium refuses some of them for DevTools).
$port = 0
foreach ($candidate in 9310..9360) {
    $probe = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $candidate)
    try {
        $probe.Start()
        $probe.Stop()
        $port = $candidate
        break
    }
    catch { try { $probe.Stop() } catch { } }
}
if ($port -eq 0) {
    $result.error = 'no free devtools port in 9310-9360'
    if ($Json) { $result | ConvertTo-Json -Depth 6 } else { Write-Host ('  UNVERIFIED: {0}' -f $result.error) -ForegroundColor Yellow }
    exit 2
}

$proc = $null
$ws = $null
try {
    # Launched through System.Diagnostics.Process, not Start-Process: Chromium
    # must not inherit a non-console parent's stdio (it exits with code 13 when
    # it does), and CreateNoWindow keeps the throwaway profile invisible.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $browser
    $psi.Arguments = @(
        '--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
        '--disable-extensions', '--disable-background-networking',
        ('--user-data-dir="{0}"' -f (Join-Path $workDir 'profile')),
        ('--remote-debugging-port={0}' -f $port),
        'about:blank'
    ) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    # Drain the redirected pipes so Chromium can never block on a full buffer.
    $null = $proc.StandardOutput.ReadToEndAsync()
    $null = $proc.StandardError.ReadToEndAsync()
    $targets = $null
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Milliseconds 500
        try {
            $targets = Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/json" -f $port) -TimeoutSec 1
            if ($targets) { break }
        }
        catch { }
    }
    $page = @($targets | Where-Object { $_.type -eq 'page' }) | Select-Object -First 1
    if (-not $page) { throw 'devtools endpoint did not expose a page target' }

    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    if (-not $ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait(8000)) {
        throw 'devtools websocket connect timed out'
    }

    function Send-Cdp {
        param([int]$Id, [string]$Method, $Params)
        $msg = @{ id = $Id; method = $Method; params = $Params } | ConvertTo-Json -Compress -Depth 6
        $bytes = [Text.Encoding]::UTF8.GetBytes($msg)
        $ws.SendAsync([ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text,
            $true, [Threading.CancellationToken]::None).Wait(5000) | Out-Null
    }
    function Receive-Cdp {
        param([int]$TimeoutMs = 5000)
        $buf = New-Object byte[] 65536
        $task = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf), [Threading.CancellationToken]::None)
        if (-not $task.Wait($TimeoutMs)) { return $null }
        return [Text.Encoding]::UTF8.GetString($buf, 0, $task.Result.Count)
    }

    Send-Cdp -Id 1 -Method 'Page.navigate' -Params @{ url = $pageUrl }
    # Real time, not virtual time: the STUN exchange is a socket round trip.
    Start-Sleep -Seconds ($GatherSeconds + 3)
    Send-Cdp -Id 2 -Method 'Runtime.evaluate' -Params @{
        expression = "document.getElementById('out').textContent"; returnByValue = $true
    }
    $evaluated = $null
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        $msg = Receive-Cdp -TimeoutMs 3000
        if ($msg -and $msg -match '"id":2') { $evaluated = $msg; break }
    }
    if (-not $evaluated) { throw 'no evaluation reply from the browser' }
    $parsed = $evaluated | ConvertFrom-Json
    $text = [string]$parsed.result.result.value
    if ($text -notmatch '^RESULT:(.*)$') { throw ('unexpected page output: {0}' -f $text.Substring(0, [Math]::Min(120, $text.Length))) }
    $payload = $Matches[1] | ConvertFrom-Json

    $cands = @($payload.candidates)
    $result.candidates = $cands
    $hostMdns = @()
    $hostLiteral = @()
    $srflx = @()
    foreach ($c in $cands) {
        # candidate:<foundation> <component> <transport> <priority> <address> <port> typ <type> ...
        if ($c -match '(?i)\btyp\s+(\w+)') { $type = $Matches[1].ToLower() } else { continue }
        if ($c -match '^candidate:\S+\s+\d+\s+\S+\s+\d+\s+(\S+)\s+\d+\s+typ') { $addr = $Matches[1] } else { $addr = '' }
        switch ($type) {
            'host' { if ($addr -match '(?i)\.local$') { $hostMdns += $addr } else { $hostLiteral += $addr } }
            'srflx' { if ($addr) { $srflx += $addr } }
        }
    }
    $result.hostMdns = @($hostMdns)
    $result.hostIpLiteral = @($hostLiteral)
    $result.srflx = @($srflx)
    if ($cands.Count -eq 0) { $result.verdict = 'NO_CANDIDATES' }
    elseif (@($srflx).Count -gt 0) { $result.verdict = 'SRFLX_PUBLIC' }
    else { $result.verdict = 'HOST_ONLY' }
}
catch {
    $result.error = ($_.Exception.Message -replace '\s+', ' ')
    $result.verdict = 'UNVERIFIED'
}
finally {
    if ($ws) { try { $ws.Dispose() } catch { } }
    if ($proc) { try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { } }
    # Edge may re-launch itself, so kill by command line: only processes that
    # carry THIS run's throwaway --user-data-dir are touched.
    try {
        Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine.Contains($workDir) } |
            ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
    }
    catch { }
    Start-Sleep -Milliseconds 800
    # Only ever delete the throwaway directory this script created under %TEMP%.
    $full = [IO.Path]::GetFullPath($workDir)
    if ($full.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $full -Leaf) -like 'webrtc-browser-*') {
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$exitCode = switch ($result.verdict) {
    'SRFLX_PUBLIC' { 0 }
    'HOST_ONLY' { 2 }
    'NO_CANDIDATES' { 2 }
    default { 2 }
}

if ($Json) { $result | ConvertTo-Json -Depth 8 }
else {
    Write-Host ''
    Write-Host '  BROWSER WEBRTC CANDIDATE PROBE (throwaway profile, headless, read-only)' -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * 90))
    Write-Host ('  browser      : {0}' -f $browser)
    Write-Host ('  stun         : {0}' -f $StunUrl)
    Write-Host ('  verdict      : {0}' -f $result.verdict)
    Write-Host ('  candidates   : {0}' -f @($result.candidates).Count)
    foreach ($c in @($result.candidates)) { Write-Host ('    {0}' -f $c) -ForegroundColor DarkGray }
    Write-Host ('  mDNS host    : {0}' -f $(if (@($result.hostMdns).Count) { @($result.hostMdns) -join ', ' } else { '(none)' }))
    Write-Host ('  literal host : {0}' -f $(if (@($result.hostIpLiteral).Count) { @($result.hostIpLiteral) -join ', ' } else { '(none)' }))
    Write-Host ('  srflx (UDP)  : {0}' -f $(if (@($result.srflx).Count) { @($result.srflx) -join ', ' } else { '(none)' }))
    if ($result.error) { Write-Host ('  error        : {0}' -f $result.error) -ForegroundColor Yellow }
    Write-Host ('  evidence     : {0}' -f $evidenceTime) -ForegroundColor DarkGray
    Write-Host ''
}

exit $exitCode
