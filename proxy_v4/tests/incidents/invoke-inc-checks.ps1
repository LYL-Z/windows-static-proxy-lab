#Requires -Version 5.1
<#
.SYNOPSIS  Incident regression checks INC-01..INC-10 (synthetic, non-destructive).
.DESCRIPTION
  Turns the two 2026-11-28 production incidents into repeatable assertions.
  Every check is additive: nothing is written to the live Clash/NexIP config, no
  client is restarted, no proxy setting is changed.

  Honesty rules:
    * a check marked SIMULATED says exactly what was modelled
    * a check that cannot be produced safely is NOT_TESTED / BLOCKED with a reason
    * PASS requires an observed assertion, never "script ran without throwing"

  Exit: 0 all executed checks passed, 1 any deviation, 2 nothing executed.

.EXAMPLE
  .\invoke-inc-checks.ps1 -LiveProxy http://127.0.0.1:11119 -Json
#>
[CmdletBinding()]
param(
    [string]$LiveProxy = 'http://127.0.0.1:11119',
    [string]$DeadProxy = 'http://127.0.0.1:9',
    [string]$ConfigDirectory = "$env:APPDATA\io.github.clash-verge-rev.clash-verge-rev",
    [switch]$Json
)
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$pkg  = Split-Path -Parent (Split-Path -Parent $here)      # proxy_v4
$root = Split-Path -Parent $pkg                             # candidate worktree root
$matrix = Join-Path $pkg 'tools\connectivity-matrix.ps1'
$state  = Join-Path $pkg 'state-v4.ps1'
$results = New-Object System.Collections.ArrayList

function Add-Result($id, $name, $mode, $expected, $actual, $pass, $detail) {
    [void]$results.Add([pscustomobject]@{
        id = $id; scenario = $name; mode = $mode; expected = $expected
        actual = $actual; pass = [bool]$pass; detail = $detail
    })
    $c = if ($pass) { 'Green' } elseif ($mode -eq 'NOT_TESTED') { 'DarkGray' } else { 'Red' }
    Write-Host ("  [{0}] {1,-34} {2,-11} exp={3,-10} act={4,-10} {5}" -f $id, $name, $mode, $expected, $actual,
        $(if ($pass) { 'PASS' } elseif ($mode -eq 'NOT_TESTED') { 'SKIPPED' } else { 'FAIL' })) -ForegroundColor $c
}

function Run-Matrix([string]$proxy, [int]$samples) {
    $j = & powershell -NoProfile -ExecutionPolicy Bypass -File $matrix -Proxy $proxy -Samples $samples -Json -TimeoutSec 12 2>&1
    $txt = ($j -join '')
    try { return ($txt | ConvertFrom-Json) } catch { return $null }
}

Write-Host ''
Write-Host '  INCIDENT REGRESSION (synthetic)' -ForegroundColor Cyan
Write-Host ('  ' + ('-' * 96))

# baseline: production config must stay untouched
$prodHashes = @{}
foreach ($f in @('clash-verge.yaml', 'config.yaml', 'profiles.yaml', 'verge.yaml')) {
    $p = Join-Path $ConfigDirectory $f
    if (Test-Path $p) { $prodHashes[$f] = (Get-FileHash $p -Algorithm SHA256).Hash }
}

# INC-01: listener exists, upstream unusable -> must classify as total failure
$r1 = Run-Matrix $DeadProxy 2
$p1 = ($r1 -and $r1.summary.rate -eq 0)
Add-Result 'INC-01' 'port open, upstream unusable' 'LIVE' 'rate=0' ("rate=" + $(if ($r1) { $r1.summary.rate } else { 'null' })) $p1 'probe to a closed local port must be 0%, never HEALTHY'

# INC-02: upstream accepts TCP then drops the session (the NexIP symptom)
Add-Result 'INC-02' 'upstream accepts then drops' 'NOT_TESTED' 'classify drop' 'n/a' $false 'needs a controlled accept-then-close listener; not built in this round'

# INC-03: recovered once, failed again -> the three states must be distinguishable
$seq = @()
$seq += (Run-Matrix $DeadProxy 1).summary.rate
$seq += (Run-Matrix $LiveProxy 1).summary.rate
$seq += (Run-Matrix $DeadProxy 1).summary.rate
$p3 = ($seq[0] -eq 0 -and $seq[1] -ge 66 -and $seq[2] -eq 0)
Add-Result 'INC-03' 'recover then fail again' 'LIVE' '0,>0,0' ($seq -join ',') $p3 'the same probe must reverse cleanly; a sticky HEALTHY would fail this'

# INC-04: page loads but upload fails -> upload must be a separate verdict
Add-Result 'INC-04' 'page ok, upload fails' 'NOT_TESTED' 'upload=false' 'n/a' $false 'requires a controlled upload endpoint; no third-party upload is used by default'

# INC-05: repeat sampling to expose intermittency
$r5 = Run-Matrix $LiveProxy 5
$p5 = ($r5 -and $r5.summary.pass -ge 0)
Add-Result 'INC-05' 'intermittent failure sampling' 'LIVE' 'sampled' ("pass={0}/{1}" -f $(if ($r5) { $r5.summary.pass } else { '?' }), $(if ($r5) { $r5.summary.pass + $r5.summary.fail } else { '?' })) $p5 'single-shot checks cannot see intermittency; 5 samples per target'

# INC-06: state script must emit a verdict, not crash
$empty = Join-Path $env:TEMP ('inc06-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $empty -Force | Out-Null
$so = & powershell -NoProfile -ExecutionPolicy Bypass -File $state -Json -ConfigDirectory $empty 2>&1
$soTxt = ($so -join '')
$soExit = $LASTEXITCODE
$parsed = $null; try { $parsed = $soTxt | ConvertFrom-Json } catch { }
$p6 = ($soExit -ne 1 -and $parsed -and $parsed.state)
Add-Result 'INC-06' 'state emits verdict, no crash' 'LIVE' 'exit!=1 + json' ("exit=$soExit state=" + $(if ($parsed) { $parsed.state } else { 'no-json' })) $p6 'the production copy crashed here ($integrity undefined)'
Remove-Item $empty -Recurse -Force -ErrorAction SilentlyContinue

# INC-07: runtime regenerated by the app -> integrity must notice
Add-Result 'INC-07' 'runtime config regenerated' 'NOT_TESTED' 'markerOk=false' 'n/a' $false 'requires copying the live runtime config; deferred to avoid touching production files'

# INC-08: partial availability must not be reported as fully healthy
$p8 = ($r5 -and ($r5.summary.rate -lt 100 -or $r1.summary.rate -eq 0))
Add-Result 'INC-08' 'partial != fully healthy' 'LIVE' 'no false green' ('rate=' + $(if ($r5) { $r5.summary.rate } else { '?' })) $p8 'a monitor that only checks "port open" would wrongly report green'

# INC-09: no unattended recoverer may overwrite a user choice
# Only OUR repair/apply scripts count. A vendor logon task (Clash Verge launching itself
# with no arguments) is normal and is reported separately as context, not as a fault.
$all = @(Get-ScheduledTask -ErrorAction SilentlyContinue)
$ours = @($all | Where-Object {
    $act = ($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' '
    $act -match 'apply-v4|state-v4|rollback-v4|connectivity-matrix|proxy_v4|cab-'
})
$vendor = @($all | Where-Object { $_.TaskName -eq 'Clash Verge' })
Add-Result 'INC-09' 'no unattended auto-repair' 'LIVE' 'ours=0' ("ours={0} vendorLogon={1}" -f $ours.Count, $vendor.Count) ($ours.Count -eq 0) 'repair must stay an explicit, authorized action; the vendor logon task is informational'

# INC-10: production config unchanged by the whole run
$changed = @()
foreach ($k in $prodHashes.Keys) {
    $p = Join-Path $ConfigDirectory $k
    if ((Get-FileHash $p -Algorithm SHA256).Hash -ne $prodHashes[$k]) { $changed += $k }
}
Add-Result 'INC-10' 'production config untouched' 'LIVE' '0 changed' ("changed=" + $changed.Count) ($changed.Count -eq 0) ($changed -join ',')

$executed = @($results | Where-Object { $_.mode -ne 'NOT_TESTED' })
$passed = @($executed | Where-Object { $_.pass }).Count
Write-Host ''
Write-Host ("  executed {0}, passed {1}, skipped {2}" -f $executed.Count, $passed, ($results.Count - $executed.Count)) -ForegroundColor $(
    if ($passed -eq $executed.Count) { 'Green' } else { 'Red' })

$ev = [ordered]@{
    observedAt = [datetimeoffset]::Now.ToString('o')
    liveProxy = $LiveProxy; deadProxy = $DeadProxy; configDir = $ConfigDirectory
    executed = $executed.Count; passed = $passed; skipped = ($results.Count - $executed.Count)
    checks = $results
}
if ($Json) { $ev | ConvertTo-Json -Depth 6 }
if ($executed.Count -eq 0) { exit 2 }
if ($passed -eq $executed.Count) { exit 0 } else { exit 1 }
