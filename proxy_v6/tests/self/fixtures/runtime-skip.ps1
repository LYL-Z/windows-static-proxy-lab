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
Register-Test -Id 'FIX-SKIP-RUNTIME' -Requirement 'META-05' -Precondition 'runtime skip requested inside the body' -InjectedFault 'runtime skip' -Expected 'runtime skip is recorded separately and the run exits 2' -Body {
  Skip-HarnessTest 'fixture runtime skip: simulated missing dependency'
}

$result = Invoke-TestRun -OutFile $OutFile -EvidenceDir $EvidenceDir -Filter $Filter
exit [int]$result.exitCode
