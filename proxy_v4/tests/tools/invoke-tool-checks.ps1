#Requires -Version 5.1
<#
.SYNOPSIS  Tool-level checks for the v2 diagnostic additions, LOCAL ONLY.

.DESCRIPTION
  Covers the tools added for the path / WebRTC investigation without touching
  the internet or the machine's network state:

    T01  diag-contract v2 -CaptureBody really returns the body (local origin)
    T02  without -CaptureBody the body stays $null (no accidental payload copy)
    T03  path-report.ps1 refuses to invent a conclusion when no egress IP is
         measurable: exit 3 and egressConsistency=INCONSISTENT_UNKNOWN
    T04  path-report.ps1 leaves the running Clash config and the system proxy
         setting byte-identical (read-only claim, measured)
    T05  webrtc-probe.ps1 without UDP evidence reports verdict=UNKNOWN and puts
         every gap in `unknown` (a missing measurement is never "clean")
    T06  webrtc-browser-probe.ps1 without -Consent starts nothing and says
         consent_required

  Only 127.0.0.1 is contacted.  Exit: 0 all checks passed, 2 some failed,
  3 nothing executed.

.EXAMPLE
  .\invoke-tool-checks.ps1
  .\invoke-tool-checks.ps1 -Json
#>
[CmdletBinding()]
param([switch]$Json)
$ErrorActionPreference = 'Continue'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$pkg = Split-Path -Parent (Split-Path -Parent $here)
$tools = Join-Path $pkg 'tools'
$contract = Join-Path $tools 'diag-contract.ps1'
$pathReport = Join-Path $tools 'path-report.ps1'
$webrtc = Join-Path $tools 'webrtc-probe.ps1'
$browser = Join-Path $tools 'webrtc-browser-probe.ps1'
$mockOrigin = Join-Path $pkg 'tests\incidents\mock-origin.ps1'

foreach ($f in @($contract, $pathReport, $webrtc, $browser, $mockOrigin)) {
    if (-not (Test-Path -LiteralPath $f)) {
        Write-Error ("missing file: {0}" -f $f)
        exit 3
    }
}

$results = @()
function Add-Result {
    param([string]$Id, [string]$Title, [string]$Expected, [string]$Actual, [bool]$Pass, [string]$Why)
    $script:results += [pscustomobject][ordered]@{
        id = $Id; title = $Title; expected = $Expected; actual = $Actual; pass = $Pass; why = $Why
    }
}

function New-FreePort {
    $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop(); return $p
}
function Wait-Port {
    param([int]$Port, [int]$TimeoutMs = 5000)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $c = New-Object Net.Sockets.TcpClient
        try { $c.Connect('127.0.0.1', $Port); $c.Close(); return $true }
        catch { try { $c.Close() } catch { } ; Start-Sleep -Milliseconds 120 }
    }
    return $false
}
function Invoke-Tool {
    param([string]$Script, [string[]]$Arguments)
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments 2>&1
    return [pscustomobject]@{ exit = $LASTEXITCODE; text = (@($out) -join "`n") }
}

$originPort = New-FreePort
$originProc = Start-Process -FilePath 'powershell' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $mockOrigin, '-Port', "$originPort") -PassThru -WindowStyle Hidden
$originUp = Wait-Port -Port $originPort -TimeoutMs 8000
if (-not $originUp) {
    Write-Error 'mock origin did not start'
    try { Stop-Process -Id $originProc.Id -Force } catch { }
    exit 3
}
. $contract

try {
    # T01 / T02: body capture is opt-in and complete.
    $withBody = Invoke-DiagProbe -Url ("http://127.0.0.1:{0}/ok" -f $originPort) -TimeoutSec 10
    $without = Invoke-DiagProbe -Url ("http://127.0.0.1:{0}/ok" -f $originPort) -TimeoutSec 10 -CaptureBody
    $t01 = [bool]($without.ok -and $without.body -eq 'ok' -and (Get-DiagContractInfo).version -eq 2)
    Add-Result 'T01' 'contract v2 -CaptureBody returns the body' 'ok/200 body=ok version=2' `
        ("ok={0} status={1} body='{2}' version={3}" -f $without.ok, $without.httpStatus, $without.body, (Get-DiagContractInfo).version) $t01 `
        'a probe that does not ask for the body must still be able to read an echo'

    $t02 = [bool]($withBody.body -eq $null -and $withBody.ok)
    Add-Result 'T02' 'default probe keeps body=null' 'body null, ok=true' `
        ("body={0} ok={1}" -f $(if ($null -eq $withBody.body) { 'null' } else { "'$($withBody.body)'" }), $withBody.ok) $t02 `
        'the body is only copied when explicitly requested'

    # T03: no measurable egress IP -> the tool must not claim CONSISTENT.
    $r3 = Invoke-Tool -Script $pathReport -Arguments @(
        '-Json', '-Paths', 'DIRECT', '-ForeignTargets', ("http://127.0.0.1:{0}/ok" -f $originPort),
        '-DomesticTargets', ("http://127.0.0.1:{0}/ok" -f $originPort), '-Samples', '1', '-TimeoutSec', '8', '-SkipConfigRead')
    $j3 = $null
    try { $j3 = $r3.text | ConvertFrom-Json -ErrorAction Stop } catch { }
    $t03 = [bool]($r3.exit -eq 3 -and $j3 -and $j3.conclusion.egressConsistency -eq 'INCONSISTENT_UNKNOWN')
    Add-Result 'T03' 'path-report without an echo IP never says CONSISTENT' 'exit=3 INCONSISTENT_UNKNOWN' `
        ("exit={0} consistency={1}" -f $r3.exit, $(if ($j3) { $j3.conclusion.egressConsistency } else { 'unparsed' })) $t03 `
        'a conclusion with no egress IP would be a guess'

    # T04: read-only claim is measured on the running config + system proxy.
    $cfg = Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev\clash-verge.yaml'
    $hashBefore = if (Test-Path -LiteralPath $cfg) { (Get-FileHash -LiteralPath $cfg -Algorithm SHA256).Hash } else { 'absent' }
    $regKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $regBefore = (Get-ItemProperty -Path $regKey -ErrorAction SilentlyContinue).ProxyServer
    $null = Invoke-Tool -Script $pathReport -Arguments @(
        '-Json', '-Paths', 'DIRECT', '-ForeignTargets', ("http://127.0.0.1:{0}/ok" -f $originPort),
        '-DomesticTargets', ("http://127.0.0.1:{0}/ok" -f $originPort), '-Samples', '1', '-TimeoutSec', '8')
    $hashAfter = if (Test-Path -LiteralPath $cfg) { (Get-FileHash -LiteralPath $cfg -Algorithm SHA256).Hash } else { 'absent' }
    $regAfter = (Get-ItemProperty -Path $regKey -ErrorAction SilentlyContinue).ProxyServer
    $t04 = [bool]($hashBefore -eq $hashAfter -and $regBefore -eq $regAfter)
    Add-Result 'T04' 'path-report leaves config and system proxy unchanged' 'both hashes/values equal' `
        ("configEqual={0} proxyEqual={1}" -f ($hashBefore -eq $hashAfter), ($regBefore -eq $regAfter)) $t04 `
        'the report is a reader: it must not rewrite the thing it measures'

    # T05: no UDP evidence -> UNKNOWN + explicit gaps.
    $r5 = Invoke-Tool -Script $webrtc -Arguments @('-Json', '-SkipStun')
    $j5 = $null
    try { $j5 = $r5.text | ConvertFrom-Json -ErrorAction Stop } catch { }
    $gaps = if ($j5) { @($j5.unknown) } else { @() }
    $t05 = [bool]($j5 -and $j5.verdict -eq 'UNKNOWN' -and $gaps.Count -ge 2)
    Add-Result 'T05' 'webrtc-probe without UDP says UNKNOWN, lists gaps' 'verdict=UNKNOWN unknown>=2' `
        ("verdict={0} unknown={1}" -f $(if ($j5) { $j5.verdict } else { 'unparsed' }), $gaps.Count) $t05 `
        'an unmeasured UDP path must never be reported as clean'

    # T06: no consent -> no browser.
    $r6 = Invoke-Tool -Script $browser -Arguments @('-Json')
    $j6 = $null
    try { $j6 = $r6.text | ConvertFrom-Json -ErrorAction Stop } catch { }
    $t06 = [bool]($r6.exit -eq 2 -and $j6 -and $j6.verdict -eq 'UNVERIFIED' -and $j6.error -like 'consent_required*')
    Add-Result 'T06' 'browser probe refuses to run without -Consent' 'exit=2 UNVERIFIED consent_required' `
        ("exit={0} verdict={1} error={2}" -f $r6.exit, $(if ($j6) { $j6.verdict } else { 'unparsed' }), $(if ($j6) { $j6.error } else { '' })) $t06 `
        'starting a browser is an explicit act'
}
finally {
    try { Stop-Process -Id $originProc.Id -Force -ErrorAction SilentlyContinue } catch { }
}

$passed = @($results | Where-Object { $_.pass }).Count
$total = $results.Count
$exitCode = if ($total -eq 0) { 3 } elseif ($passed -eq $total) { 0 } else { 2 }

if ($Json) {
    [ordered]@{
        observedAt = [datetimeoffset]::Now.ToString('o')
        tool       = 'invoke-tool-checks.ps1'
        localOnly  = $true
        checks     = $results
        summary    = [ordered]@{ pass = $passed; total = $total }
        exitCode   = $exitCode
    } | ConvertTo-Json -Depth 6
}
else {
    Write-Host ''
    Write-Host '  TOOL CHECKS (local loopback only)' -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * 96))
    $results | Format-Table @{n = 'id'; e = { $_.id } }, @{n = 'ok'; e = { $_.pass } },
        @{n = 'title'; e = { $_.title } }, @{n = 'actual'; e = { $_.actual } } -AutoSize |
        Out-String -Width 160 | Write-Host
    $c = if ($exitCode -eq 0) { 'Green' } else { 'Red' }
    Write-Host ('  RESULT {0}/{1}' -f $passed, $total) -ForegroundColor $c
    Write-Host ''
}

exit $exitCode
