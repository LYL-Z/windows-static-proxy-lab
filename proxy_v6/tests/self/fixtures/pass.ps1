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
Register-Test -Id 'FIX-PASS-01' -Requirement 'META-01' -Precondition 'isolated child process; temp evidence directory' -InjectedFault 'none' -Expected 'Assert-Equal 1 1 passes' -Body {
  Assert-Equal 1 1
  Set-TestActual '1 equals 1'
}
Register-Test -Id 'FIX-PASS-02' -Requirement 'META-01' -Precondition 'isolated child process; temp evidence directory' -InjectedFault 'none' -Expected 'pattern abc123 matches ^[a-z]+[0-9]+$' -Body {
  Assert-True $true
  Assert-Match 'abc123' '^[a-z]+[0-9]+$'
}

$result = Invoke-TestRun -OutFile $OutFile -EvidenceDir $EvidenceDir -Filter $Filter
exit [int]$result.exitCode
