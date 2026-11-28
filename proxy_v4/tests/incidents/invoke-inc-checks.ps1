#Requires -Version 5.1
<#
.SYNOPSIS  Incident regression INC-01..INC-10 with LOCAL controlled servers.
.DESCRIPTION
  Every scenario is produced by a fixture owned by this script, not by "whatever the
  internet happens to do today":

      mock proxy  : 502-loop (port open, upstream unusable) / drop-loop / alternate
      mock origin : GET 200 + POST 500 (page opens, upload fails)

  Assertions are strict: a check passes only when the measured value equals the
  expected one. "pass -ge 0" style always-true conditions are forbidden here.

  Nothing writes to the live Clash/NexIP configuration, no client is restarted, no
  proxy setting is changed. INC-10 proves it for the whole run.

.EXAMPLE
  .\invoke-inc-checks.ps1 -LiveProxy http://127.0.0.1:11119 -Json
#>
[CmdletBinding()]
param(
    [string]$LiveProxy = 'http://127.0.0.1:11119',
    [string]$ConfigDirectory = "$env:APPDATA\io.github.clash-verge-rev.clash-verge-rev",
    [switch]$Json
)
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$pkg  = Split-Path -Parent (Split-Path -Parent $here)     # proxy_v4
$matrix = Join-Path $pkg 'tools\connectivity-matrix.ps1'
$state  = Join-Path $pkg 'state-v4.ps1'
$results = New-Object System.Collections.ArrayList

function Add-Result($id, $name, $mode, $expected, $actual, $pass, $detail) {
    [void]$results.Add([pscustomobject]@{
        id = $id; scenario = $name; mode = $mode; expected = $expected
        actual = $actual; pass = [bool]$pass; detail = $detail
    })
    $c = if ($pass) { 'Green' } elseif ($mode -eq 'NOT_TESTED') { 'DarkGray' } else { 'Red' }
    Write-Host ("  [{0}] {1,-32} {2,-9} exp={3,-14} act={4,-16} {5}" -f $id, $name, $mode, $expected, $actual,
        $(if ($pass) { 'PASS' } elseif ($mode -eq 'NOT_TESTED') { 'SKIPPED' } else { 'FAIL' })) -ForegroundColor $c
}

function Wait-Port([int]$Port, [int]$TimeoutMs = 8000) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        try {
            $c = New-Object Net.Sockets.TcpClient
            $c.Connect('127.0.0.1', $Port); $c.Close(); return $true
        } catch { Start-Sleep -Milliseconds 150 }
    }
    return $false
}

function Start-MockProxy([int]$Port, [string]$Mode) {
    return Start-Job -ArgumentList $Port, $Mode -ScriptBlock {
        param($Port, $Mode)
        $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port)
        $l.Start(); $n = 0
        while ($true) {
            try { $c = $l.AcceptTcpClient() } catch { break }
            $n++
            $s = $c.GetStream(); $buf = New-Object byte[] 4096
            $read = 0; try { $read = $s.Read($buf, 0, 4096) } catch { }
            if ($read -le 0) { $c.Close(); continue }
            $req = [Text.Encoding]::ASCII.GetString($buf, 0, $read)
            if ($Mode -eq 'drop') { $c.Close(); continue }
            $forward = switch ($Mode) {
                'fail' { $false }
                'alternate' { (($n % 2) -eq 1) }   # odd connections forwarded = real success
                default { $false }
            }
            if (-not $forward) {
                $resp = "HTTP/1.1 502 Bad Gateway`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"
                $b = [Text.Encoding]::ASCII.GetBytes($resp)
                try { $s.Write($b, 0, $b.Length); $s.Flush() } catch { }
                $c.Close(); continue
            }
            if ($req -match '^CONNECT\s+([^:\s]+):(\d+)') {
                $hostName = $Matches[1]; $portNo = [int]$Matches[2]
                $up = $null
                try { $up = New-Object Net.Sockets.TcpClient; $up.Connect($hostName, $portNo) }
                catch {
                    $resp = "HTTP/1.1 502 Bad Gateway`r`nContent-Length: 0`r`n`r`n"
                    $b = [Text.Encoding]::ASCII.GetBytes($resp)
                    try { $s.Write($b, 0, $b.Length); $s.Flush() } catch { }
                    $c.Close(); continue
                }
                $s2 = $up.GetStream()
                $hs = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 Connection established`r`n`r`n")
                $s.Write($hs, 0, $hs.Length); $s.Flush()
                $t1 = $s.CopyToAsync($s2); $t2 = $s2.CopyToAsync($s)
                [void][Threading.Tasks.Task]::WaitAny(@($t1, $t2), 15000)
                $up.Close(); $c.Close()
            }
            else { $c.Close() }
        }
        $l.Stop()
    }
}

function Start-MockOrigin([int]$Port) {
    return Start-Job -ArgumentList $Port -ScriptBlock {
        param($Port)
        $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port)
        $l.Start()
        while ($true) {
            try { $c = $l.AcceptTcpClient() } catch { break }
            $s = $c.GetStream(); $buf = New-Object byte[] 4096
            $n = 0; try { $n = $s.Read($buf, 0, 4096) } catch { }
            $req = if ($n -gt 0) { [Text.Encoding]::ASCII.GetString($buf, 0, $n) } else { '' }
            if ($req -match '^POST ') { $code = '500 Internal Server Error'; $body = 'upload-rejected' }
            else { $code = '200 OK'; $body = 'ok' }
            $resp = "HTTP/1.1 $code`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n$body"
            $b = [Text.Encoding]::ASCII.GetBytes($resp)
            try { $s.Write($b, 0, $b.Length); $s.Flush() } catch { }
            $c.Close()
        }
        $l.Stop()
    }
}

function Run-Matrix([string[]]$extra) {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $matrix @extra -Json -TimeoutSec 10 2>&1
    $code = $LASTEXITCODE
    $txt = ($out -join '')
    $obj = $null
    try { $obj = $txt | ConvertFrom-Json } catch { }
    return [pscustomobject]@{ json = $obj; exit = $code; raw = $txt }
}

$jobs = @()
$ports = @{ fail = 18801; drop = 18802; alternate = 18803; origin = 18804 }
try {
    Write-Host ''
    Write-Host '  INCIDENT REGRESSION (local fixtures, no third-party dependency)' -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * 104))

    # ---- protected-resource manifest (F48: presence, not just 4 hashes) ----
    $manifestFiles = @('clash-verge.yaml', 'config.yaml', 'profiles.yaml', 'verge.yaml')
    $before = [ordered]@{}
    foreach ($f in $manifestFiles) {
        $p = Join-Path $ConfigDirectory $f
        $before[$f] = if (Test-Path $p) { (Get-FileHash $p -Algorithm SHA256).Hash } else { 'ABSENT' }
    }
    $hk = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $regBefore = [ordered]@{
        ProxyEnable = (Get-ItemProperty $hk -ErrorAction SilentlyContinue).ProxyEnable
        ProxyServer = (Get-ItemProperty $hk -ErrorAction SilentlyContinue).ProxyServer
    }
    $listingBefore = @(Get-ChildItem $ConfigDirectory -File -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { $_.Name })

    # ---- fixtures ----
    $jobs += Start-MockProxy $ports.fail 'fail'
    $jobs += Start-MockProxy $ports.drop 'drop'
    $jobs += Start-MockProxy $ports.alternate 'alternate'
    $jobs += Start-MockOrigin $ports.origin
    foreach ($p in $ports.Values) { [void](Wait-Port $p) }

    $pFail = "http://127.0.0.1:$($ports.fail)"
    $pDrop = "http://127.0.0.1:$($ports.drop)"
    $pAlt  = "http://127.0.0.1:$($ports.alternate)"
    $origin = "http://127.0.0.1:$($ports.origin)"

    # INC-01: the PORT IS LISTENING, the upstream is not usable (F43)
    $listening = (Wait-Port $ports.fail 2000)
    $r1 = Run-Matrix @('-Proxy', $pFail, '-Samples', '2', '-Targets', 'https://example.com')
    $p1 = ($listening -and $r1.json -and $r1.json.summary.rate -eq 0 -and $r1.exit -eq 3)
    Add-Result 'INC-01' 'listening but upstream 502' 'LIVE' 'rate=0 exit=3' ("listen=$listening rate=" + $(if ($r1.json) { $r1.json.summary.rate } else { '?' }) + " exit=$($r1.exit)") $p1 'real listener returns 502; a closed port would be a different scenario'

    # INC-02: accept TCP then drop the session (the NexIP symptom) (was NOT_TESTED)
    $r2 = Run-Matrix @('-Proxy', $pDrop, '-Samples', '2', '-Targets', 'https://example.com')
    $kinds = if ($r2.json) { @($r2.json.targets | ForEach-Object { $_.kind } | Where-Object { $_ }) -join ',' } else { '' }
    $p2 = ($r2.json -and $r2.json.summary.rate -eq 0 -and $r2.exit -eq 3 -and $kinds -match 'EMPTY_REPLY|CONNECT_REFUSED|RECV_FAIL|OTHER')
    Add-Result 'INC-02' 'accept then drop' 'LIVE' 'rate=0 + classified' ("rate=" + $(if ($r2.json) { $r2.json.summary.rate } else { '?' }) + " kind=$kinds") $p2 'session dropped without a response; failure must be classified, not silent'

    # INC-03: fail -> live -> fail must reverse cleanly
    $a = (Run-Matrix @('-Proxy', $pFail, '-Samples', '1', '-Targets', 'https://example.com')).json.summary.rate
    $b = (Run-Matrix @('-Proxy', $LiveProxy, '-Samples', '2', '-Targets', 'https://www.google.com')).json.summary.rate
    $c = (Run-Matrix @('-Proxy', $pFail, '-Samples', '1', '-Targets', 'https://example.com')).json.summary.rate
    $p3 = ($a -eq 0 -and $b -gt 0 -and $c -eq 0)
    Add-Result 'INC-03' 'recover then fail again' 'LIVE' '0,>0,0' ("$a,$b,$c") $p3 'the same probe must reverse; a sticky HEALTHY fails this'

    # INC-04: GET works, upload fails -> verdict must not be full success (F46)
    $r4 = Run-Matrix @('-Direct', '-Samples', '1', '-Targets', "$origin/ok", '-PostUrl', "$origin/upload")
    $p4 = ($r4.json -and $r4.json.summary.pass -ge 1 -and $r4.json.summary.uploadFailed -eq $true -and $r4.exit -ne 0)
    Add-Result 'INC-04' 'page ok, upload fails' 'LIVE' 'upload=false exit!=0' ("pass=" + $(if ($r4.json) { $r4.json.summary.pass } else { '?' }) + " upFail=" + $(if ($r4.json) { $r4.json.summary.uploadFailed } else { '?' }) + " exit=$($r4.exit)") $p4 'local origin: GET 200, POST 500'

    # INC-05: deterministic intermittency from the alternate fixture (F44)
    $r5 = Run-Matrix @('-Proxy', $pAlt, '-Samples', '6', '-Targets', 'https://example.com')
    $pass5 = if ($r5.json) { $r5.json.summary.pass } else { -1 }
    $tot5 = if ($r5.json) { $r5.json.summary.pass + $r5.json.summary.fail } else { 0 }
    $p5 = ($tot5 -eq 6 -and $pass5 -gt 0 -and $pass5 -lt 6)
    Add-Result 'INC-05' 'alternating failures' 'LIVE' '0<pass<6' ("pass=$pass5/$tot5") $p5 'fixture alternates 502/drop per connection'

    # INC-06: state must emit a verdict for empty, corrupt and text modes (F51)
    $empty = Join-Path $env:TEMP ('inc06e-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $empty -Force | Out-Null
    $corrupt = Join-Path $env:TEMP ('inc06c-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $corrupt -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $corrupt 'settings.json') -Value '{ this is not json' -Encoding utf8
    $o1 = & powershell -NoProfile -ExecutionPolicy Bypass -File $state -Json -ConfigDirectory $empty 2>&1; $e1 = $LASTEXITCODE
    $o2 = & powershell -NoProfile -ExecutionPolicy Bypass -File $state -Json -ConfigDirectory $corrupt 2>&1; $e2 = $LASTEXITCODE
    $o3 = & powershell -NoProfile -ExecutionPolicy Bypass -File $state -ConfigDirectory $empty 2>&1; $e3 = $LASTEXITCODE
    $j1 = ($o1 -join ''); $j2 = ($o2 -join '')
    $parse1 = $null; try { $parse1 = $j1 | ConvertFrom-Json } catch { }
    $parse2 = $null; try { $parse2 = $j2 | ConvertFrom-Json } catch { }
    $crash = (($o1 -join ' ') + ($o2 -join ' ') + ($o3 -join ' ')) -match 'VariableIsUndefined|cannot be retrieved|has not been set'
    $p6 = ($e1 -ne 1 -and $e2 -ne 1 -and $e3 -ne 1 -and $parse1 -and $parse2 -and -not $crash)
    Add-Result 'INC-06' 'state verdict, no crash' 'LIVE' 'no crash, 3 modes' ("empty=$e1 corrupt=$e2 text=$e3") $p6 ("empty={0} corrupt={1} text={2}" -f $(if ($parse1) { $parse1.state } else { 'no-json' }), $(if ($parse2) { $parse2.state } else { 'no-json' }), $e3)
    Remove-Item $empty, $corrupt -Recurse -Force -ErrorAction SilentlyContinue

    # INC-07: regenerated runtime / lost marker must be detected (was NOT_TESTED)
    $synth = Join-Path $env:TEMP ('inc07-' + [guid]::NewGuid().ToString('N'))
    $prof = Join-Path $synth 'profiles'; New-Item -ItemType Directory $prof -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $prof 'v4-managed.yaml') -Value "proxies:`n  - name: X`n" -Encoding utf8
    $rt = Join-Path $synth 'clash-verge.yaml'; Set-Content -LiteralPath $rt -Value "proxies:`n  - name: US`n    dialer-proxy: STAR-FIRSTHOP`n" -Encoding utf8
    $probe = @'
param($pkg,$profDir,$runtime)
$ErrorActionPreference='SilentlyContinue'
. (Join-Path $pkg 'lib\V4.ps1')
$paths = [pscustomobject]@{ ProfilesDir=$profDir; RuntimeFile=$runtime }
$r = Get-V4Integrity -Paths $paths
@{ markerOk=$r.markerOk; runtimeMarkerOk=$r.runtimeMarkerOk; profileExists=$r.profileExists } | ConvertTo-Json -Compress
'@
    $probeFile = Join-Path $env:TEMP ('probe-' + [guid]::NewGuid().ToString('N') + '.ps1')
    Set-Content -LiteralPath $probeFile -Value $probe -Encoding utf8
    $pi = & powershell -NoProfile -ExecutionPolicy Bypass -File $probeFile $pkg $prof $rt 2>&1
    $pj = ($pi -join '') | ConvertFrom-Json -ErrorAction SilentlyContinue
    $p7 = ($pj -and $pj.profileExists -eq $true -and $pj.markerOk -eq $false)
    Add-Result 'INC-07' 'marker lost detected' 'LIVE' 'markerOk=false' ("exists=$(if($pj){$pj.profileExists}else{'?'}) markerOk=$(if($pj){$pj.markerOk}else{'?'})") $p7 'synthetic config dir; no production file is copied'
    Remove-Item $synth, $probeFile -Recurse -Force -ErrorAction SilentlyContinue

    # INC-08: partial availability must not be reported as full health (F45)
    $r8 = Run-Matrix @('-Proxy', $pAlt, '-Samples', '4', '-Targets', 'https://example.com')
    $rate8 = if ($r8.json) { $r8.json.summary.rate } else { -1 }
    $p8 = ($rate8 -gt 0 -and $rate8 -lt 100 -and $r8.exit -eq 2)
    Add-Result 'INC-08' 'partial != healthy' 'LIVE' '0<rate<100 exit=2' ("rate=$rate8 exit=$($r8.exit)") $p8 'exit 2 is partial; only a clean run may return 0'

    # INC-09: no unattended recoverer (tasks + processes + startup) (F52)
    $allTasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue)
    $oursTasks = @($allTasks | Where-Object {
        $act = ($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' '
        $act -match 'apply-v4|state-v4|rollback-v4|connectivity-matrix|proxy_v4|cab-'
    })
    $selfTree = New-Object System.Collections.ArrayList
    [void]$selfTree.Add($PID)
    $parent = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction SilentlyContinue).ParentProcessId
    if ($parent) { [void]$selfTree.Add([int]$parent) }
    $oursProcs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessId -and $selfTree -notcontains [int]$_.ProcessId -and
        $_.CommandLine -and $_.CommandLine -notmatch 'invoke-inc-checks' -and
        $_.CommandLine -match 'apply-v4\.ps1|state-v4\.ps1|rollback-v4\.ps1|connectivity-matrix\.ps1'
    })
    $runKeys = @()
    foreach ($k in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run')) {
        $p = Get-ItemProperty $k -ErrorAction SilentlyContinue
        if ($p) { $p.PSObject.Properties | Where-Object { $_.Value -match 'apply-v4|state-v4|proxy_v4|cab-' } | ForEach-Object { $runKeys += $_.Name } }
    }
    $startup = @(Get-ChildItem ([Environment]::GetFolderPath('Startup')) -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'cab|proxy|clash|verge' })
    $p9 = ($oursTasks.Count -eq 0 -and $oursProcs.Count -eq 0 -and $runKeys.Count -eq 0 -and $startup.Count -eq 0)
    Add-Result 'INC-09' 'no unattended recoverer' 'LIVE' '0 everywhere' ("task=$($oursTasks.Count) proc=$($oursProcs.Count) run=$($runKeys.Count) startup=$($startup.Count)") $p9 'scheduled tasks + live processes + Run keys + Startup folder'

    # INC-10: manifest-based integrity of the protected resources (F48)
    $changed = @()
    foreach ($f in $manifestFiles) {
        $p = Join-Path $ConfigDirectory $f
        $now = if (Test-Path $p) { (Get-FileHash $p -Algorithm SHA256).Hash } else { 'ABSENT' }
        if ($now -ne $before[$f]) { $changed += $f }
    }
    $listingAfter = @(Get-ChildItem $ConfigDirectory -File -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { $_.Name })
    $newFiles = @($listingAfter | Where-Object { $listingAfter -notcontains $_ -or -not ($listingBefore -contains $_) })
    $regAfter = @{
        ProxyEnable = (Get-ItemProperty $hk -ErrorAction SilentlyContinue).ProxyEnable
        ProxyServer = (Get-ItemProperty $hk -ErrorAction SilentlyContinue).ProxyServer
    }
    $regChanged = ($regBefore.ProxyEnable -ne $regAfter.ProxyEnable) -or ($regBefore.ProxyServer -ne $regAfter.ProxyServer)
    $absent = @($before.Keys | Where-Object { $before[$_] -eq 'ABSENT' })
    $p10 = ($changed.Count -eq 0 -and -not $regChanged -and $newFiles.Count -eq 0)
    Add-Result 'INC-10' 'protected resources intact' 'LIVE' '0 delta' ("files=$($changed.Count) reg=$regChanged new=$($newFiles.Count) absentInit=$($absent.Count)") $p10 'files + new files + HKCU proxy values; two samples only, not continuous monitoring'
}
finally {
    foreach ($j in $jobs) { Stop-Job $j -ErrorAction SilentlyContinue; Remove-Job $j -Force -ErrorAction SilentlyContinue }
}

$executed = @($results | Where-Object { $_.mode -ne 'NOT_TESTED' })
$passed = @($executed | Where-Object { $_.pass }).Count
Write-Host ''
Write-Host ("  executed {0}, passed {1}, skipped {2}" -f $executed.Count, $passed, ($results.Count - $executed.Count)) -ForegroundColor $(
    if ($passed -eq $executed.Count) { 'Green' } else { 'Red' })

$ev = [ordered]@{
    observedAt = [datetimeoffset]::Now.ToString('o')
    liveProxy = $LiveProxy; configDir = $ConfigDirectory
    executed = $executed.Count; passed = $passed; skipped = ($results.Count - $executed.Count)
    checks = $results
}
if ($Json) { $ev | ConvertTo-Json -Depth 6 }
if ($executed.Count -eq 0) { exit 2 }
if ($passed -eq $executed.Count) { exit 0 } else { exit 1 }
