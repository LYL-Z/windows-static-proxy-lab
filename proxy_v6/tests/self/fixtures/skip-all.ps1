#Requires -Version 5.1
<#
  Fixture for the V6 harness self-test. Runs in its own powershell.exe child.
  Inputs: -OutFile / -EvidenceDir / -Filter are forwarded to Invoke-TestRun.
#>
[CmdletBinding()]
param(
  [string]$OutFile = '',
  [string]$EvidenceDir = '',
  [string]$Filter = '*'
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'Harness.ps1')
Register-Test -Id 'FIX-SKIP-ONLY' -Requirement 'META-05' -Precondition 'dependency intentionally absent' -InjectedFault 'registration skip' -Expected 'all-skipped run must be exit 2' -Skip -SkipReason 'fixture registration skip: only test skipped' -Body {
  throw 'skipped test body must never execute'
}

$result = Invoke-TestRun -OutFile $OutFile -EvidenceDir $EvidenceDir -Filter $Filter
exit [int]$result.exitCode
