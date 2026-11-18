# V6 scenario tests (F07-F10 and later)

This directory is the only place where scenario test files are auto-loaded.
Run-Tests.ps1 dot-sources every file matching cases\*.tests.ps1 in name order.

## Contract for a case file

- The file must only REGISTER tests (Register-Test). Do not call Invoke-TestRun
  and do not call exit: the runner owns the single run and the exit code.
- Harness.ps1 and lib\TestSupport.ps1 are already loaded by Run-Tests.ps1.
  If a case file is executed directly, dot-source ..\Harness.ps1 and
  ..\lib\TestSupport.ps1 first (both are idempotent).
- Every test must supply id, requirement, precondition, injectedFault,
  expected and a body. Skipped tests must supply -Skip -SkipReason.
- Work only under a directory returned by New-TestTempRoot and remove it in a
  finally block with Remove-TestTempRoot. Never point a test at the real
  proxy_v4\config, appdata, HKCU, Clash processes or the network.
- Do not dot-source proxy_v4\lib\V4.ps1 in the runner process: the current
  production library creates config/backup directories at load time. Scenario
  tests that need production code must start an isolated child process whose
  working copy and data root are under TEMP, and must use the V4 test mode
  once the lead has added it.
- The harness captures test output and masks common password/username/Basic
  patterns in evidence, but tests must still avoid printing real secrets.
- Keep source ASCII-only: Windows PowerShell 5.1 misreads BOM-less non-ASCII
  scripts in some hosts. Use English ids/messages; localize only report files.

## Example skeleton (splatting avoids line-continuation backticks)

    $case = @{
      Id = 'F08-01'
      Requirement = 'F08'
      Precondition = 'isolated temp appdata; target profile has no updated field'
      InjectedFault = 'target profile lacks updated; a following profile has one'
      Expected = 'only the target profile block is rewritten'
      Body = {
        $root = New-TestTempRoot -Prefix 'f08'
        try {
          # build fixture files under $root, call the function under test
          Assert-Equal 'expected' 'actual'
          Set-TestActual 'target block rewritten; next profile untouched'
        } finally {
          Remove-TestTempRoot -Path $root | Out-Null
        }
      }
    }
    Register-Test @case

Do not add F07-F10 scenarios in the harness deliverable itself; the lead owns
those files. This file only documents the convention.
