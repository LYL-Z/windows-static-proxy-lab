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
Register-Test -Id 'FIX-ORDER-01' -Requirement 'META-07' -Precondition 'isolated child process' -InjectedFault 'earlier failing assertion' -Expected 'earlier test fails' -Body {
  Assert-True $false 'earlier failure must persist'
}
Register-Test -Id 'FIX-ORDER-02' -Requirement 'META-07' -Precondition 'isolated child process' -InjectedFault 'none' -Expected 'later test passes' -Body {
  Assert-True $true 'later test passed'
}

$result = Invoke-TestRun -OutFile $OutFile -EvidenceDir $EvidenceDir -Filter $Filter
exit [int]$result.exitCode
