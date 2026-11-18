#Requires -Version 5.1
# Infrastructure, lifecycle, security and real-script isolation checks.
$script:InfraFixture = Join-Path $PSScriptRoot 'fixtures\Run-InfraCase.ps1'

function Invoke-InfraCase {
  param([string]$Id, [int]$TimeoutMs = 180000)
  $root = New-TestTempRoot -Prefix ('infra-' + $Id.ToLowerInvariant())
  try {
    $out = Join-Path $root 'result.json'
    $r = Invoke-TestChildPowerShell -ScriptPath $script:InfraFixture -Arguments @('-Case', $Id, '-OutFile', $out) -TimeoutMs $TimeoutMs
    if ($r.ExitCode -ne 0) {
      $tail = [string]$r.StdOut
      if ($tail.Length -gt 4000) { $tail = $tail.Substring($tail.Length - 4000) }
      throw ('infra case ' + $Id + ' failed (exit ' + [string]$r.ExitCode + '): ' + $tail + ' ' + [string]$r.StdErr)
    }
    if (-not (Test-Path -LiteralPath $out -PathType Leaf)) { throw ('infra case ' + $Id + ' did not write its result') }
    $j = Get-Content -LiteralPath $out -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ([bool]$j.pass) ($Id + ' failed: ' + [string]$j.detail)
    Set-TestActual ([string]$j.actual)
    return $j
  }
  finally { Remove-TestTempRoot -Path $root | Out-Null }
}

$cases = @(
  @{ id='INF-ACL-01'; req='SEC-02'; pre='protected temp directory + injected Everyone ACE'; fault='weak ACE added after hardening'; exp='second hardening removes Everyone and returns true' },
  @{ id='INF-LOG-01'; req='LOG-01'; pre='evidence path exists as a file'; fault='log directory cannot be created'; exp='Start-V4Log returns false; logging continues' },
  @{ id='INF-LOG-02'; req='LOG-02'; pre='log file path is invalid'; fault='Add-Content target missing'; exp='Write-V4Log never throws' },
  @{ id='INF-LAZY-01'; req='S07'; pre='clean test root'; fault='none'; exp='dot-source and Start-V4Log do not create config/backup' },
  @{ id='INF-GUARD-01'; req='P4'; pre='V4_TEST_MODE=1'; fault='attempt real HKCU/process operations'; exp='4/4 blocked; Get-V4Paths does not fall back' },
  @{ id='INF-REDACT-01'; req='SEC-03'; pre='registered secret'; fault='password/username/Basic/SOCKS userinfo'; exp='all redacted' },
  @{ id='INF-DPAPI-01'; req='SEC-01'; pre='plaintext fixture'; fault='none'; exp='DPAPI roundtrip; ciphertext has no plaintext' },
  @{ id='INF-SETTINGS-01'; req='SEC-02'; pre='clean root'; fault='none'; exp='settings DPAPI at rest, ACL restricted, roundtrip' },
  @{ id='INF-SETTINGS-02'; req='PARAM-05'; pre='invalid settings JSON'; fault='corrupt settings'; exp='code 11' },
  @{ id='INF-SETTINGS-03'; req='PARAM-04'; pre='no settings'; fault='missing settings'; exp='code 11' },
  @{ id='INF-SETTINGS-04'; req='R2C-03'; pre='hardened settings, then Everyone read ACE'; fault='ACL widened after save'; exp='Get-V4Settings refuses with code 12' },
  @{ id='INF-INIT-01'; req='F09'; pre='runtime profile with one socks5 node'; fault='none'; exp='migrated through injected writer' },
  @{ id='INF-INIT-02'; req='F09'; pre='runtime profile with two socks5 nodes'; fault='ambiguous profile'; exp='rejected; writer not called' },
  @{ id='INF-INIT-03'; req='F09'; pre='explicit init missing password'; fault='incomplete credentials'; exp='rejected; writer not called' },
  @{ id='INF-INIT-04'; req='F09'; pre='runtime password quoted with # and escaped quote'; fault='YAML scalar parsing'; exp='full password preserved' },
  @{ id='INF-LOCK-01'; req='LOCK-04'; pre='lock file with dead pid'; fault='stale lock'; exp='reclaimed and released' },
  @{ id='INF-LOCK-02'; req='LOCK-02'; pre='winner holds lock'; fault='wrong token exit'; exp='lock survives' },
  @{ id='INF-LOCK-03'; req='LOCK-05'; pre='lock file uses current pid with wrong start time'; fault='PID reuse'; exp='treated as stale' },
  @{ id='INF-START-01'; req='LIFE-05'; pre='port already listening'; fault='duplicate-start attempt'; exp='no launch' },
  @{ id='INF-START-02'; req='LIFE-02'; pre='process running, port not listening'; fault='delayed start'; exp='waits without duplicate launch' },
  @{ id='INF-START-03'; req='LIFE-01'; pre='nothing listening'; fault='timeout'; exp='false after one launch' },
  @{ id='INF-STATE-CORE-01'; req='LIFE-03'; pre='mock probes'; fault='9 state combinations'; exp='all branches match' },
  @{ id='INF-F12-01'; req='F12'; pre='UI and HKCU proxy states differ'; fault='UI on/HKCU off; UI off/HKCU on; first hop down'; exp='DEGRADED with explicit reasons' },
  @{ id='INF-F12-02'; req='F12'; pre='settings missing + UI on/HKCU off'; fault='state early return'; exp='FAILED but still includes UI mismatch reason' },
  @{ id='INF-F12-03'; req='F12'; pre='verge.yaml variations'; fault='UI parser'; exp='true/false/missing key/missing file handled' },
  @{ id='INF-INTEGRITY-01'; req='LIFE-08'; pre='marked profile + runtime chain'; fault='tamper profile'; exp='marker detected then lost' },
  @{ id='INF-SNAP-01'; req='TX-11'; pre='snapshot without managed profile'; fault='file created after snapshot'; exp='restore deletes it' },
  @{ id='INF-SNAP-02'; req='DATA-04'; pre='tampered snapshot file'; fault='hash mismatch'; exp='refused before live write' },
  @{ id='INF-SNAP-03'; req='DATA-04'; pre='manifest with traversal path'; fault='unsafe path'; exp='refused' },
  @{ id='INF-SNAP-04'; req='TX-08'; pre='one live target locked'; fault='restore failure on one file'; exp='failure reported; other file restored' },
  @{ id='INF-ATOMIC-01'; req='TX-02'; pre='existing target'; fault='none'; exp='replace committed; staging cleaned' },
  @{ id='INF-ATOMIC-02'; req='TX-02'; pre='existing target'; fault='validator rejection'; exp='target intact; staging cleaned' },
  @{ id='INF-ATOMIC-03'; req='TX-06'; pre='target locked'; fault='file occupied'; exp='refused; target intact' },
  @{ id='INF-PARAM-01'; req='PARAM-01'; pre='no settings'; fault='Repair+DryRun / Init+Repair'; exp='both exit 11; no settings' },
  @{ id='INF-PARAM-02'; req='PARAM-06'; pre='no settings'; fault='invalid Mode'; exp='nonzero; no settings' },
  @{ id='INF-APPLY-INIT-01'; req='F09'; pre='no appdata; explicit credentials file'; fault='Init reaches missing paths'; exp='settings written under lock; exit 10; lock released' },
  @{ id='INF-APPLY-INIT-02'; req='C-02'; pre='legacy -StaticPass parameter'; fault='command-line password'; exp='exit 11 removal message; no settings' },
  @{ id='INF-APPLY-INIT-03'; req='C-02'; pre='legacy -StaticPassFile parameter'; fault='old file parameter'; exp='exit 11 removal message; no settings' },
  @{ id='INF-DRYRUN-01'; req='PARAM-07'; pre='fake appdata/hop/core + real apply script'; fault='none'; exp='exit 0; no config/settings/appdata changes; no snapshot' },
  @{ id='INF-STATE-SCRIPT-01'; req='LIFE-04'; pre='corrupt settings'; fault='state probe'; exp='FAILED JSON and exit 3' },
  @{ id='INF-F06-01'; req='F06'; pre='built profiles'; fault='none'; exp='strict=select without DIRECT; resilient=fallback with DIRECT' },
  @{ id='INF-ROLLBACK-01'; req='TX-ROLLBACK'; pre='valid snapshot + journal'; fault='none'; exp='real rollback script restores files, clears journal/lock' },
  @{ id='INF-ROLLBACK-02'; req='TX-ROLLBACK'; pre='tampered snapshot'; fault='hash mismatch'; exp='exit 40, live files intact, lock released' },
  @{ id='INF-ROLLBACK-03'; req='TX-ROLLBACK'; pre='winner holds the lock'; fault='lock busy'; exp='exit 33, no start, winner lock intact' },
  @{ id='INF-ROLLBACK-04'; req='TX-ROLLBACK'; pre='settings mixedPort=65532'; fault='non-default mixed port'; exp='rollback restart uses 65532' },
  @{ id='INF-LOCK-05'; req='LOCK-04'; pre='zero-byte lock older than grace'; fault='empty lock file'; exp='reclaimed, not stuck forever' },
  @{ id='INF-JOURNAL-01'; req='TX-05'; pre='pending transaction journal'; fault='previous process died'; exp='apply refuses with exit 34; clear works' },
  @{ id='INF-YAML-01'; req='DATA-02'; pre='credentials containing quote/newline/backslash'; fault='YAML injection attempt'; exp='escaped; no injected top-level key' },
  @{ id='INF-SNAP-05'; req='TX-11'; pre='existing profiles/*.yaml'; fault='snapshot path separator'; exp='recorded as profiles\name and restored' },
  @{ id='INF-SNAP-06'; req='TX-07'; pre='manifest with zero file entries'; fault='empty manifest'; exp='refused; no false success' },
  @{ id='INF-SNAP-07'; req='TX-07'; pre='manifest missing profiles.yaml coverage'; fault='partial manifest'; exp='refused' },
  @{ id='INF-SNAP-08'; req='SEC-02'; pre='credential file deleted before restore'; fault='recreated file inherits ACL'; exp='restored file is ACL-hardened' },
  @{ id='INF-REDACT-02'; req='SEC-03'; pre='non-registered secret forms'; fault='pass/secret/Bearer/short Basic/URL/user'; exp='all redacted' },
  @{ id='INF-REDACT-03'; req='SEC-03'; pre='JSON key / spaces / URL / Cookie'; fault='structured secret forms'; exp='all redacted' }
)
foreach ($c in $cases) {
  $id = [string]$c.id
  $body = { Invoke-InfraCase -Id $id | Out-Null }.GetNewClosure()
  Register-Test -Id $id -Requirement ([string]$c.req) -Precondition ([string]$c.pre) -InjectedFault ([string]$c.fault) -Expected ([string]$c.exp) -Body $body
}