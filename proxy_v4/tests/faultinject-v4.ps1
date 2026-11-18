#Requires -Version 5.1
<#
.DEPRECATED
  The V4 fault-injection bench is retired. It had false positives (FT06 hard-coded
  true), did not exercise apply/rollback, used production paths/lock, and FT12
  called Protect-V4Acl on the real hosts file. It must not be run.

  V6 replaces it with proxy_v6/tests/Run-Tests.ps1 (74 isolated cases, explicit
  exit-code contract, self-tested harness). This file is kept only as a safe
  redirect for old documentation and scripts.
#>
$runner = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\proxy_v6\tests\Run-Tests.ps1'))
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
    Write-Host ('V6 test runner not found: ' + $runner) -ForegroundColor Red
    exit 3
}
Write-Host 'DEPRECATED: delegating to proxy_v6/tests/Run-Tests.ps1' -ForegroundColor Yellow
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner
exit $LASTEXITCODE
