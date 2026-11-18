#Requires -Version 5.1
<#
  Run-Tests.ps1 - V6 test entry point (Windows PowerShell 5.1).

  Loads Harness.ps1 + lib\TestSupport.ps1, then dot-sources every
  cases\*.tests.ps1 file (sorted by name) and runs the selected tests.
  Case files must only register tests; they must not call Invoke-TestRun.

  Exit codes (enforced by Harness.ps1):
    0 pass, 1 test failure, 2 zero executed, 3 harness error, 4 evidence error.

  Examples:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File proxy_v6\tests\Run-Tests.ps1
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File proxy_v6\tests\Run-Tests.ps1 -Filter 'F08-*'
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File proxy_v6\tests\Run-Tests.ps1 -OutFile proxy_v6\evidence\v6\f08.json
#>
[CmdletBinding()]
param(
  [string]$Filter = '*',
  [string]$OutFile = '',
  [string]$EvidenceDir = '',
  [string]$CasesDir = '',
  [string]$RepoRoot = ''
)

$ErrorActionPreference = 'Stop'
$testsDir = $PSScriptRoot

try {
  if (-not $RepoRoot) { $RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $testsDir '..\..')) }
  if (-not $CasesDir) { $CasesDir = Join-Path $testsDir 'cases' }

  . (Join-Path $testsDir 'Harness.ps1')

  $supportPath = Join-Path $testsDir 'lib\TestSupport.ps1'
  if (Test-Path -LiteralPath $supportPath -PathType Leaf) {
    . $supportPath
  } else {
    Add-HarnessError 'load' ('TestSupport.ps1 not found: ' + $supportPath)
  }

  $loadedFiles = 0
  if (Test-Path -LiteralPath $CasesDir -PathType Container) {
    $caseFiles = @(Get-ChildItem -LiteralPath $CasesDir -Filter '*.tests.ps1' -File -ErrorAction Stop | Sort-Object Name)
    foreach ($f in $caseFiles) {
      try {
        . $f.FullName
        $loadedFiles = $loadedFiles + 1
      } catch {
        Add-HarnessError 'load' ('failed to load test file ' + $f.Name + ': ' + [string]$_.Exception.Message) ([string]$_.ScriptStackTrace)
      }
    }
    Write-Output ('Loaded test files: ' + [string]$loadedFiles + ' from ' + $CasesDir)
  } else {
    Write-Output ('[WARN] cases directory not found: ' + $CasesDir + ' (zero tests will execute; exit 2)')
  }

  $result = Invoke-TestRun -OutFile $OutFile -EvidenceDir $EvidenceDir -Filter $Filter -RepoRoot $RepoRoot
  exit [int]$result.exitCode
} catch {
  Write-Output ('[HARNESS-ERROR] Run-Tests.ps1: ' + [string]$_.Exception.Message)
  if ($_.ScriptStackTrace) { Write-Output ('       ' + [string]$_.ScriptStackTrace) }
  exit 3
}
