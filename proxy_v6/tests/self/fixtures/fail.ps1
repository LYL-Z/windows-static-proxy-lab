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
Register-Test -Id 'FIX-FAIL-01' -Requirement 'META-02' -Precondition 'isolated child process' -InjectedFault 'failing assertion' -Expected 'Assert-Equal 1 2 fails' -Body {
  Assert-Equal 1 2 -Message 'intentional failure one'
}
Register-Test -Id 'FIX-FAIL-02' -Requirement 'META-02' -Precondition 'isolated child process' -InjectedFault 'unexpected exception' -Expected 'test body throws' -Body {
  throw 'intentional unexpected exception'
}

$result = Invoke-TestRun -OutFile $OutFile -EvidenceDir $EvidenceDir -Filter $Filter
exit [int]$result.exitCode
