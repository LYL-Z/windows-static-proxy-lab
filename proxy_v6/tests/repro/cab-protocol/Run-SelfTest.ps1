#Requires -Version 5.1
<#
  Runs the cab-protocol loopback repro.
  Exit 0 means the self-test passed. It does not mean a path is protected.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$probe = Join-Path $PSScriptRoot 'protocol_probe.py'
if (-not (Test-Path -LiteralPath $probe)) {
  Write-Error "Missing $probe"
  exit 2
}

$py = Get-Command py -ErrorAction SilentlyContinue
if ($py) {
  & $py.Source -3 $probe --self-test
  exit $LASTEXITCODE
}

$python = Get-Command python -ErrorAction SilentlyContinue
if ($python) {
  & $python.Source $probe --self-test
  exit $LASTEXITCODE
}

Write-Error 'Python is required to run the cab-protocol self-test.'
exit 2
