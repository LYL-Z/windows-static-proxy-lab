#Requires -Version 5.1
# F11 regression tests: production-state isolation (FT16..FT21).
$script:FTFixture = Join-Path $PSScriptRoot 'fixtures\Run-FT-Case.ps1'

function Invoke-FTCase {
  param([string]$Id, [int]$TimeoutMs = 120000)
  $root = New-TestTempRoot -Prefix ('ft-' + $Id.ToLowerInvariant())
  try {
    $out = Join-Path $root 'result.json'
    $r = Invoke-TestChildPowerShell -ScriptPath $script:FTFixture -Arguments @('-Case', $Id, '-OutFile', $out) -TimeoutMs $TimeoutMs
    if ($r.ExitCode -ne 0) {
      $tail = [string]$r.StdOut
      if ($tail.Length -gt 4000) { $tail = $tail.Substring($tail.Length - 4000) }
      throw ('FT case ' + $Id + ' failed (exit ' + [string]$r.ExitCode + '): ' + $tail + ' ' + [string]$r.StdErr)
    }
    if (-not (Test-Path -LiteralPath $out -PathType Leaf)) { throw ('FT case ' + $Id + ' did not write its result') }
    $j = Get-Content -LiteralPath $out -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ([bool]$j.pass) ($Id + ' failed: ' + [string]$j.detail)
    Set-TestActual ([string]$j.actual)
    return $j
  }
  finally { Remove-TestTempRoot -Path $root | Out-Null }
}

$cases = @(
  @{ id='FT16'; req='F11'; pre='test mode + mock registry writer'; fault='attempt to write ProxyServer=x'; exp='x only in mock; real HKCU unchanged' },
  @{ id='FT17'; req='F11'; pre='test mode + mock writer that throws'; fault='mock failure'; exp='operation aborts; real HKCU unchanged' },
  @{ id='FT18'; req='F11'; pre='mocked child performing a write'; fault='child killed abnormally'; exp='real HKCU unchanged' },
  @{ id='FT19'; req='F11'; pre='two parallel mocked children'; fault='parallel test execution'; exp='real HKCU unchanged' },
  @{ id='FT20'; req='F11'; pre='state core with ProxyServer=x'; fault='corrupt proxy / wrong exit'; exp='DEGRADED, never HEALTHY' },
  @{ id='FT21'; req='F11'; pre='test without a writer'; fault='no mock installed'; exp='write refused; HKCU/WinHTTP identical before/after' }
)
foreach ($c in $cases) {
  $id = [string]$c.id
  $body = { Invoke-FTCase -Id $id | Out-Null }.GetNewClosure()
  Register-Test -Id $id -Requirement ([string]$c.req) -Precondition ([string]$c.pre) -InjectedFault ([string]$c.fault) -Expected ([string]$c.exp) -Body $body
}