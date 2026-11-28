#Requires -Version 5.1
# Helper for scenario cases. Loaded by cases\*.tests.ps1 (Harness + TestSupport already loaded).
$helperExisting = Get-Variable -Name 'ReproHelpersLoaded' -ErrorAction SilentlyContinue
if ($helperExisting -and $helperExisting.Value) { return }
$script:ReproHelpersLoaded = $true

function Invoke-ReproCase {
  param(
    [Parameter(Mandatory = $true)][ValidateSet('F07','F08','F09','F10')][string]$Suite,
    [Parameter(Mandatory = $true)][string]$Id,
    [int]$TimeoutMs = 240000
  )
  $root = New-TestTempRoot -Prefix ('repro-' + $Suite.ToLowerInvariant())
  try {
    $outFile = Join-Path $root 'result.json'
    $scriptPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ('..\repro\Repro-' + $Suite + '.ps1')))
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw ('repro suite not found: ' + $scriptPath) }
    $r = Invoke-TestChildPowerShell -ScriptPath $scriptPath -Arguments @('-Only', $Id, '-OutFile', $outFile) -TimeoutMs $TimeoutMs
    if ($r.ExitCode -ne 0) {
      $tail = [string]$r.StdOut
      if ($tail.Length -gt 4000) { $tail = $tail.Substring($tail.Length - 4000) }
      throw ('repro suite failed (exit ' + [string]$r.ExitCode + '): ' + $tail + ' ' + [string]$r.StdErr)
    }
    if (-not (Test-Path -LiteralPath $outFile -PathType Leaf)) { throw ('repro suite did not write its result file: ' + $outFile) }
    $j = Get-Content -LiteralPath $outFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($Id -eq '*') {
      if ([int]$j.total -lt 1) { throw 'repro suite executed zero checks' }
      Assert-True ([int]$j.passed -eq [int]$j.total) ('repro suite has failures: ' + [string]$j.passed + '/' + [string]$j.total)
      Set-TestActual ('all ' + [string]$j.total + ' sub-checks passed')
      return $j
    }
    $case = @($j.cases) | Where-Object { [string]$_.id -eq $Id } | Select-Object -First 1
    Assert-NotNull $case ('repro result does not contain ' + $Id)
    Assert-True ([bool]$case.pass) ($Id + ' failed: ' + [string]$case.detail)
    Set-TestActual ($Id + ': ' + [string]$case.detail)
    return $case
  }
  finally { Remove-TestTempRoot -Path $root | Out-Null }
}