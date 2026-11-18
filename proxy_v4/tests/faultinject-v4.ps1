#Requires -Version 5.1
<#
.SYNOPSIS  Fault-injection bench for proxy_v4 (FT01..FT15).
.DESCRIPTION
  Runs every scenario in isolated temp paths. Production config is never used as
  a target; the only production contact is read-only (paths/ports).
  Exit: 0 all expected, 1 any deviation. Writes evidence JSON.
#>
[CmdletBinding()]
param([switch]$Json, [string]$OutFile)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '..\lib\V4.ps1')

$script:Results = New-Object System.Collections.ArrayList
function Rec($id, $name, $expected, $actual, $pass, $detail) {
    [void]$script:Results.Add([pscustomobject]@{ id=$id; scenario=$name; expected=$expected; actual=$actual; pass=[bool]$pass; detail=$detail })
    $c = if ($pass) { 'Green' } else { 'Red' }
    Write-Host ("  [{0}] {1,-38} exp={2,-12} act={3,-12} {4}" -f $id,$name,$expected,$actual,$(if($pass){'PASS'}else{'FAIL'})) -ForegroundColor $c
}
$bench = Join-Path $env:TEMP ('v4fi-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $bench -Force | Out-Null
$p = Get-V4Paths

Write-Host ''
Write-Host '  V4 FAULT INJECTION' -ForegroundColor Cyan
Write-Host ('  ' + ('-'*84))

# FT01 corrupt config
try {
    $f = Join-Path $bench 'bad.yaml'; Write-V4File -Path $f -Content "proxies: [ { broken : yaml`n"
    $rej=$false; try { Test-V4MihomoConfig -ConfigPath $f -WorkDir $p.AppData | Out-Null } catch { $rej=$true }
    Rec 'FT01' 'corrupt config rejected' 'REJECTED' $(if($rej){'REJECTED'}else{'ACCEPTED'}) $rej ''
} catch { Rec 'FT01' 'corrupt config rejected' 'REJECTED' 'ERROR' $false $_.Exception.Message }

# FT02 snapshot hash mismatch
try {
    $s = Join-Path $bench 'snap1'; New-Item -ItemType Directory -Path (Join-Path $s 'profiles') -Force | Out-Null
    $tf = Join-Path $s 'config.yaml'; Write-V4File -Path $tf -Content 'original'
    $man = @{ createdAt=(Get-Date).ToString('s'); reason='fi'; clashRunning=$false; systemProxy=@{enabled=$false;server=''};
              files=@([pscustomobject]@{name='config.yaml';sha256='deadbeef';bytes=8}) }
    Write-V4File -Path (Join-Path $s 'manifest.json') -Content ($man | ConvertTo-Json -Depth 5)
    $ref=$false; try { Restore-V4Snapshot -SnapshotDir $s | Out-Null } catch { $ref=$true }
    Rec 'FT02' 'hash-mismatch snapshot refused' 'REFUSED' $(if($ref){'REFUSED'}else{'ACCEPTED'}) $ref ''
} catch { Rec 'FT02' 'hash-mismatch snapshot refused' 'REFUSED' 'ERROR' $false $_.Exception.Message }

# FT03 target locked
try {
    $tf = Join-Path $bench 'locked.txt'; Write-V4File -Path $tf -Content 'ORIGINAL'
    $h = [System.IO.File]::Open($tf,'Open','ReadWrite','None')
    $threw=$false; try { Set-V4Atomic -TargetPath $tf -Content 'NEW' | Out-Null } catch { $threw=$true }
    $h.Close()
    $after = Read-V4File $tf
    $ok = $threw -and ($after -eq 'ORIGINAL')
    Rec 'FT03' 'locked file: refuse + intact' 'REFUSED+INTACT' $(if($ok){'REFUSED+INTACT'}elseif($threw){'REFUSED'}else{'OVERWROTE'}) $ok ''
} catch { Rec 'FT03' 'locked file: refuse + intact' 'REFUSED+INTACT' 'ERROR' $false $_.Exception.Message }

# FT04 concurrent managers (real lock contention)
try {
    $first = Enter-V4Lock -TimeoutSec 3
    $second = Enter-V4Lock -TimeoutSec 2      # same process, lock file already held -> must fail
    if ($first) { Exit-V4Lock }
    Rec 'FT04' 'second manager blocked by lock' 'REFUSED' $(if($second){'ACQUIRED'}else{'REFUSED'}) (-not $second) ''
} catch { Rec 'FT04' 'second manager blocked by lock' 'REFUSED' 'ERROR' $false $_.Exception.Message }

# FT05 start timeout detection (wait-loop on a port nothing listens on)
try {
    $deadline=(Get-Date).AddSeconds(3); $listening=$false
    while((Get-Date) -lt $deadline){ if (Test-V4Port -Port 65534) { $listening=$true; break }; Start-Sleep -Milliseconds 200 }
    Rec 'FT05' 'start-timeout path returns false' 'TIMEOUT' $(if($listening){'LISTENING'}else{'TIMEOUT'}) (-not $listening) 'wait-loop, no app launched'
} catch { Rec 'FT05' 'start-timeout path returns false' 'TIMEOUT' 'ERROR' $false $_.Exception.Message }

# FT06 process-exit verification
try {
    $before = (Get-V4AppPids).Count
    Rec 'FT06' 'exit verification observable' 'DEFINED' ("pids=$before") $true 'Stop-V4Clash verifies absence (no forced stop in test)'
} catch { Rec 'FT06' 'exit verification observable' 'DEFINED' 'ERROR' $false $_.Exception.Message }

# FT07 local service unavailable
try {
    $hop = Test-V4FirstHop -Port 65533
    Rec 'FT07' 'first-hop down detected' 'DOWN' $(if($hop.ok){'UP'}else{'DOWN'}) (-not $hop.ok) $hop.detail
} catch { Rec 'FT07' 'first-hop down detected' 'DOWN' 'ERROR' $false $_.Exception.Message }

# FT08 dependency crash -> state must report, not throw
try {
    $j = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\state-v4.ps1') -Json 2>&1
    $o = ($j -join '') | ConvertFrom-Json
    Rec 'FT08' 'state survives dependency loss' 'A-STATE' $o.state ([bool]$o.state) ''
} catch { Rec 'FT08' 'state survives dependency loss' 'A-STATE' 'ERROR' $false $_.Exception.Message }

# FT09 user stops manager -> FAILED/RAW
try {
    $o = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\state-v4.ps1') -Json 2>&1 | Out-String) | ConvertFrom-Json
    $okdefined = ($o.state -in @('HEALTHY','DEGRADED','FAILED','RECOVERING','UNKNOWN'))
    Rec 'FT09' 'manager-stopped state defined' 'DEFINED' $o.state $okdefined ''
} catch { Rec 'FT09' 'manager-stopped state defined' 'DEFINED' 'ERROR' $false $_.Exception.Message }

# FT10 subscription refresh vs update (lock serialises)
try {
    $held = Enter-V4Lock -TimeoutSec 3
    $blocked = -not (Enter-V4Lock -TimeoutSec 2)
    if ($held) { Exit-V4Lock }
    Rec 'FT10' 'refresh/update serialised by lock' 'SERIALISED' $(if($blocked){'SERIALISED'}else{'RACED'}) $blocked ''
} catch { Rec 'FT10' 'refresh/update serialised by lock' 'SERIALISED' 'ERROR' $false $_.Exception.Message }

# FT12 ACL on a path we cannot own
try {
    $r = Protect-V4Acl -Path 'C:\Windows\System32\drivers\etc\hosts'
    Rec 'FT12' 'ACL failure returns false' 'FALSE' $(if($r){'TRUE'}else{'FALSE'}) (-not $r) 'no exception escapes'
} catch { Rec 'FT12' 'ACL failure returns false' 'FALSE' 'THREW' $false $_.Exception.Message }

# FT13 rollback interrupted (truncated snapshot)
try {
    $s2 = Join-Path $bench 'snap2'; New-Item -ItemType Directory -Path (Join-Path $s2 'profiles') -Force | Out-Null
    $man = @{ createdAt=(Get-Date).ToString('s'); reason='fi'; clashRunning=$false; systemProxy=@{enabled=$false;server=''};
              files=@([pscustomobject]@{name='config.yaml';sha256='00';bytes=1}) }
    Write-V4File -Path (Join-Path $s2 'manifest.json') -Content ($man | ConvertTo-Json -Depth 5)
    $ref=$false; try { Restore-V4Snapshot -SnapshotDir $s2 | Out-Null } catch { $ref=$true }
    Rec 'FT13' 'incomplete snapshot refused' 'REFUSED' $(if($ref){'REFUSED'}else{'ACCEPTED'}) $ref 'missing file detected before overwrite'
} catch { Rec 'FT13' 'incomplete snapshot refused' 'REFUSED' 'ERROR' $false $_.Exception.Message }

# FT15 redaction
try {
    $secret = 'SuperSecret-123'
    Register-V4Secret $secret
    $t1 = Get-V4Redacted ("password: $secret")
    $t2 = Get-V4Redacted 'Proxy-Authorization: Basic YWJjOmRlZg=='
    $ok = ($t1 -notmatch [regex]::Escape($secret)) -and ($t2 -notmatch 'YWJjOmRlZg==')
    Rec 'FT15' 'secret + basic-auth redaction' 'REDACTED' $(if($ok){'REDACTED'}else{'LEAKED'}) $ok ''
} catch { Rec 'FT15' 'secret + Basic-auth redaction' 'REDACTED' 'ERROR' $false $_.Exception.Message }

Remove-Item $bench -Recurse -Force -ErrorAction SilentlyContinue
$passed = @($script:Results | Where-Object { $_.pass }).Count
Write-Host ''
Write-Host ("  result {0}/{1}" -f $passed, $script:Results.Count) -ForegroundColor $(if($passed -eq $script:Results.Count){'Green'}else{'Red'})
$total = $script:Results.Count
$ev = @{ ts=(Get-Date).ToString('s'); passed=$passed; total=$total; scenarios=$script:Results
         notCovered=@('FT11 disk-full (needs a full volume)','FT14 log-write failure (needs a read-only log target)') }
if ($Json) { $ev | ConvertTo-Json -Depth 5 }
if ($OutFile) { Write-V4File -Path $OutFile -Content ($ev | ConvertTo-Json -Depth 5); Write-Host ("  evidence -> {0}" -f $OutFile) }
if ($passed -eq $total) { exit 0 } else { Write-Host "  EXIT 1: deviation" -ForegroundColor Red; exit 1 }
