# V6 test harness (Agent B deliverable)

ASCII-only, Windows PowerShell 5.1, no module installs, no Pester dependency.

## Files

- Harness.ps1       framework: Register-Test, Invoke-TestRun, assertions,
                    per-case evidence, final JSON evidence, exit codes.
- Run-Tests.ps1     entry point: loads Harness + lib\TestSupport, dot-sources
                    cases\*.tests.ps1, runs once and exits with the result.
- lib\TestSupport.ps1  TEMP isolation, file helpers, child powershell runner.
- cases\README.md   convention for the lead's F07-F10 scenario files.
- self\SelfTest.ps1 proves META-01..META-07 with child powershell fixtures.
- self\fixtures\*.ps1  fixtures used by SelfTest (never loaded by Run-Tests).

## Quick start

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File proxy_v6\tests\Run-Tests.ps1
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File proxy_v6\tests\Run-Tests.ps1 -Filter 'F08-*'
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File proxy_v6\tests\Run-Tests.ps1 -OutFile proxy_v6\evidence\v6\f08.json

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File proxy_v6\tests\self\SelfTest.ps1

## Exit-code contract (enforced, not documented only)

    0  at least one test executed, all executed tests passed, no harness error,
       final evidence written
    1  any executed test failed
    2  zero tests executed (none registered, filter matched nothing, or every
       selected test skipped)
    3  harness/framework exception
    4  evidence write failure

Precedence: 3 > 4 > 1 > 2 > 0. Skipped tests are recorded separately and are
never counted as passed. A later pass never removes an earlier failure.

## Evidence

Each case file under <evidenceDir>\<NNNN>-<id>.json contains id, requirement,
precondition, injectedFault, expected, actual, status, detail, durationMs,
assertions, startedAt, finishedAt and evidenceFile. The final JSON contains
schemaVersion, tool, harnessVersion, runId, host, git (head/branch/dirty),
repoRoot, filter, startedAt, finishedAt, durationMs, counts (registered,
executed, passed, failed, skipped, available), exitCode, outcome,
harnessErrors, evidenceErrors and cases.

## Why not Pester 3.4

Pester 3.4 is a 2015 build in this environment. It cannot express per-case
requirement/fault metadata or the evidence-write-failure / zero-executed
contract required here, and installing Pester 5 would modify the user's global
modules without authorization. The self-test proves the above semantics with
real child powershell.exe exit codes instead.
