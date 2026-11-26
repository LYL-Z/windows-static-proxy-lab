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
Register-Test -Id 'FIX-META03-01' -Requirement 'META-03' -Precondition 'isolated child process' -InjectedFault 'none' -Expected 'test passes before the framework fault' -Body {
  Assert-True $true
}
Register-Test -Id 'FIX-META03-02' -Requirement 'META-03' -Precondition 'isolated child process' -InjectedFault 'none' -Expected 'test passes before the framework fault' -Body {
  Assert-Equal 'a' 'a'
}

$result = Invoke-TestRun -OutFile $OutFile -EvidenceDir $EvidenceDir -Filter $Filter -FaultStage 'before-summary'
exit [int]$result.exitCode
