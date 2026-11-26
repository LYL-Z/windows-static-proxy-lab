#Requires -Version 5.1
<#
  SelfTest.ps1 - proves the V6 harness contract (META-01..META-07).

  Every META check runs a fixture .ps1 in a separate powershell.exe child and
  asserts the child exit code, stdout markers and evidence JSON. The self-test
  runner computes its own aggregate exit code with the same contract:
    0 pass, 1 META check failed, 2 zero checks executed, 3 self-test harness
    exception, 4 self-test evidence write failure.
  Precedence: 3 > 4 > 1 > 2 > 0.

  Usage:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File proxy_v6\tests\self\SelfTest.ps1
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File proxy_v6\tests\self\SelfTest.ps1 -Filter 'META-0[1-4]'

  Test-only negative controls for the runner's own aggregate exit code:
    -InjectCheckFailure META-01   force one check to fail (expect exit 1)
    -Filter META-99               select nothing (expect exit 2)
    -InjectHarnessError           raise inside the runner (expect exit 3)
    -OutDir <blocked path>        evidence cannot be written (expect exit 4)
#>
[CmdletBinding()]
param(
  [string]$Filter = 'META-*',
  [string]$OutDir = '',
  [switch]$KeepArtifacts,
  [string]$InjectCheckFailure = '',
  [switch]$InjectHarnessError
)

$ErrorActionPreference = 'Stop'
$selfDir = $PSScriptRoot
$testsDir = Split-Path -Parent $selfDir
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $testsDir '..\..'))
$fixturesDir = Join-Path $selfDir 'fixtures'

. (Join-Path $testsDir 'lib\TestSupport.ps1')

$script:Checks = New-Object System.Collections.ArrayList
$script:HarnessError = $false
$script:EvidenceError = $false
$script:WorkRoot = $null
$script:OutDirResolved = $null
$script:Selected = @()
$script:StartedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz')
$script:Clock = [System.Diagnostics.Stopwatch]::StartNew()

function Get-SelfTimestamp {
  return (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz')
}

function Get-SelfRepoHead {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & git -C $repoRoot rev-parse HEAD 2>$null
    if ($LASTEXITCODE -ne 0) { return '' }
    return ([string](@($out)[0])).Trim()
  } catch {
    return ''
  } finally {
    $ErrorActionPreference = $prev
  }
}

function Get-SelfRepoSideInfo {
  $info = [ordered]@{ head = ''; branch = ''; dirty = $null }
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $head = & git -C $repoRoot rev-parse HEAD 2>$null
    if ($LASTEXITCODE -eq 0) { $info.head = ([string](@($head)[0])).Trim() }
    $branch = & git -C $repoRoot rev-parse --abbrev-ref HEAD 2>$null
    if ($LASTEXITCODE -eq 0) { $info.branch = ([string](@($branch)[0])).Trim() }
    $status = & git -C $repoRoot status --porcelain 2>$null
    if ($LASTEXITCODE -eq 0) {
      $text = (@($status) -join [Environment]::NewLine).Trim()
      $info.dirty = ($text.Length -gt 0)
    }
  } catch {
    $info.dirty = $null
  } finally {
    $ErrorActionPreference = $prev
  }
  return $info
}

function Add-SelfCheck {
  param(
    [string]$Id,
    [string]$Name,
    [bool]$Passed,
    [string]$Detail,
    $Context,
    [string]$ExpectedExit = '',
    [string]$Requirement = ''
  )
  if ($InjectCheckFailure -and $Id -eq $InjectCheckFailure) {
    $Passed = $false
    $Detail = 'INJECTED self-test failure for aggregate exit-code control; ' + $Detail
  }
  $childExit = $null
  $timedOut = $false
  $savedStdout = $null
  $savedStderr = $null
  $savedEvidence = $null
  if ($Context) {
    $childExit = [int]$Context.ExitCode
    $timedOut = [bool]$Context.TimedOut
    $savedStdout = $Context.SavedStdoutPath
    $savedStderr = $Context.SavedStderrPath
    $savedEvidence = $Context.SavedEvidencePath
  }
  [void]$script:Checks.Add([ordered]@{
    id = $Id
    requirement = $Requirement
    name = $Name
    passed = $Passed
    detail = $Detail
    expectedExit = $ExpectedExit
    childExitCode = $childExit
    childTimedOut = $timedOut
    stdout = $savedStdout
    stderr = $savedStderr
    evidence = $savedEvidence
    at = (Get-SelfTimestamp)
  })
  $tag = 'FAIL'
  if ($Passed) { $tag = 'PASS' }
  Write-Output ('[' + $tag + '] ' + $Id + ' ' + $Name)
  if ($Context) { Write-Output ('       child exit=' + [string]$childExit + ' expected=' + [string]$ExpectedExit) }
  if (-not $Passed) { Write-Output ('       ' + (($Detail -split [Environment]::NewLine) -join ' | ')) }
}

function Save-SelfText {
  param([string]$RelativePath, [string]$Content)
  if (-not $script:OutDirResolved) { $script:EvidenceError = $true; return $null }
  $target = Join-Path $script:OutDirResolved $RelativePath
  try {
    Write-TestTextFile -Path $target -Content ([string]$Content)
    return $target
  } catch {
    $script:EvidenceError = $true
    Write-Output ('[EVIDENCE-ERROR] failed to save ' + $RelativePath + ': ' + [string]$_.Exception.Message)
    return $null
  }
}

function Copy-SelfPath {
  param([string]$Source, [string]$RelativeDir)
  if (-not $script:OutDirResolved) { $script:EvidenceError = $true; return $null }
  if (-not (Test-Path -LiteralPath $Source)) { return $null }
  $target = Join-Path $script:OutDirResolved $RelativeDir
  try {
    if (Test-Path -LiteralPath $Source -PathType Container) {
      New-TestDirectory -Path $target
      foreach ($child in @(Get-ChildItem -LiteralPath $Source -Force)) {
        Copy-Item -LiteralPath $child.FullName -Destination $target -Recurse -Force -ErrorAction Stop
      }
    } else {
      $parent = Split-Path -Parent $target
      if ($parent) { New-TestDirectory -Path $parent }
      Copy-Item -LiteralPath $Source -Destination $target -Force -ErrorAction Stop
    }
    return $target
  } catch {
    $script:EvidenceError = $true
    Write-Output ('[EVIDENCE-ERROR] failed to copy ' + $Source + ': ' + [string]$_.Exception.Message)
    return $null
  }
}

function Invoke-MetaFixture {
  param(
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$FixtureName,
    [string]$FixtureFilter = '*',
    [switch]$BlockFinalEvidence,
    [switch]$BlockCaseEvidence
  )
  $fixture = Join-Path $fixturesDir $FixtureName
  if (-not (Test-Path -LiteralPath $fixture -PathType Leaf)) { throw ('fixture not found: ' + $fixture) }
  $caseDir = Join-Path $script:WorkRoot $RunId
  New-TestDirectory -Path $caseDir
  $evidencePath = Join-Path $caseDir 'evidence.json'
  $casesDir = Join-Path $caseDir 'cases'
  if ($BlockCaseEvidence) {
    $casesDir = Join-Path $caseDir 'cases-blocked'
    Write-TestTextFile -Path $casesDir -Content 'intentional blocking file: case evidence directory must fail here'
  }
  $outArg = $evidencePath
  if ($BlockFinalEvidence) {
    $blocker = Join-Path $caseDir 'blocked'
    Write-TestTextFile -Path $blocker -Content 'intentional blocking file: directory creation must fail here'
    $outArg = Join-Path $blocker 'evidence.json'
  }
  $childArgs = @('-OutFile', $outArg, '-EvidenceDir', $casesDir, '-Filter', $FixtureFilter)
  $child = Invoke-TestChildPowerShell -ScriptPath $fixture -Arguments $childArgs -TimeoutMs 180000

  $stdoutPath = Save-SelfText -RelativePath (Join-Path $RunId 'stdout.txt') -Content $child.StdOut
  $stderrPath = Save-SelfText -RelativePath (Join-Path $RunId 'stderr.txt') -Content $child.StdErr
  $savedEvidence = $null
  $savedCases = $null
  if (Test-Path -LiteralPath $evidencePath -PathType Leaf) {
    $savedEvidence = Copy-SelfPath -Source $evidencePath -RelativeDir (Join-Path $RunId 'evidence.json')
  }
  if (Test-Path -LiteralPath $casesDir -PathType Container) {
    $savedCases = Copy-SelfPath -Source $casesDir -RelativeDir (Join-Path $RunId 'cases')
  }

  $parsed = $null
  $parseError = ''
  if (Test-Path -LiteralPath $evidencePath -PathType Leaf) {
    try {
      $parsed = Get-Content -LiteralPath $evidencePath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
      $parseError = [string]$_.Exception.Message
    }
  }

  return [pscustomobject]@{
    RunId = $RunId
    Fixture = $FixtureName
    ExitCode = [int]$child.ExitCode
    TimedOut = [bool]$child.TimedOut
    StdOut = [string]$child.StdOut
    StdErr = [string]$child.StdErr
    Evidence = $parsed
    EvidenceParseError = $parseError
    EvidenceExists = (Test-Path -LiteralPath $evidencePath -PathType Leaf)
    EvidencePath = $evidencePath
    SavedEvidencePath = $savedEvidence
    SavedStdoutPath = $stdoutPath
    SavedStderrPath = $stderrPath
    CasesDir = $casesDir
    SavedCasesDir = $savedCases
  }
}

function Add-Mismatch {
  param([System.Collections.ArrayList]$List, [string]$Label, $Expected, $Actual)
  $e = '<null>'
  if ($null -ne $Expected) { $e = [string]$Expected }
  $a = '<null>'
  if ($null -ne $Actual) { $a = [string]$Actual }
  if ($e -ne $a) { [void]$List.Add($Label + ': expected [' + $e + '] actual [' + $a + ']') }
}

function Get-EvidenceCase {
  param($Evidence, [string]$CaseId)
  foreach ($c in @($Evidence.cases)) {
    if ([string]$c.id -eq $CaseId) { return $c }
  }
  return $null
}

function Test-SelfSelected {
  param([string]$Id)
  return (@($script:Selected) -contains $Id)
}

function Complete-SelfCheck {
  param([string]$Id, [string]$Name, [System.Collections.ArrayList]$Mismatches, $Context, [string]$ExpectedExit, [string]$Requirement)
  $pass = ($Mismatches.Count -eq 0)
  $detail = 'all assertions met'
  if (-not $pass) { $detail = ($Mismatches | ForEach-Object { [string]$_ }) -join '; ' }
  Add-SelfCheck -Id $Id -Name $Name -Passed $pass -Detail $detail -Context $Context -ExpectedExit $ExpectedExit -Requirement $Requirement
}

$finalExitCode = 3
try {
# --------------------------------------------------------------- setup ------
try {
  if (-not $OutDir) {
    $OutDir = Join-Path (Join-Path (Join-Path $repoRoot 'proxy_v6') 'evidence') ('selftest\' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
  }
  if (-not [System.IO.Path]::IsPathRooted($OutDir)) {
    $OutDir = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $OutDir))
  } else {
    $OutDir = [System.IO.Path]::GetFullPath($OutDir)
  }
  $script:OutDirResolved = $OutDir
  New-TestDirectory -Path $script:OutDirResolved
} catch {
  $script:EvidenceError = $true
  $script:OutDirResolved = $null
  Write-Output ('[EVIDENCE-ERROR] cannot prepare self-test output directory: ' + [string]$_.Exception.Message)
}

try {
  $script:WorkRoot = New-TestTempRoot -Prefix 'v6-selftest'
} catch {
  throw ('cannot create isolated work root: ' + [string]$_.Exception.Message)
}

$allMeta = @('META-01', 'META-02', 'META-03', 'META-04', 'META-05', 'META-06', 'META-07')
if (-not $Filter) { $Filter = 'META-*' }
$script:Selected = @($allMeta | Where-Object { $_ -like $Filter })
Write-Output ''
Write-Output '== V6 TEST HARNESS SELF-TEST =='
Write-Output ('Repo: ' + $repoRoot)
Write-Output ('Filter: ' + $Filter + '; selected: ' + [string](@($script:Selected).Count) + ' of 7 META checks')
Write-Output ('Work root: ' + $script:WorkRoot)
if ($script:OutDirResolved) { Write-Output ('Output: ' + $script:OutDirResolved) }
Write-Output '--------------------------------------------------------------'

$repoHead = Get-SelfRepoHead

# Sanity-check the self-test's own mismatch engine so the META checks cannot
# pass vacuously if Add-Mismatch stops recording differences.
try {
  $probeList = New-Object System.Collections.ArrayList
  Add-Mismatch $probeList 'sanity' 1 2
  $probeList2 = New-Object System.Collections.ArrayList
  Add-Mismatch $probeList2 'sanity' 'same' 'same'
  if ($probeList.Count -ne 1 -or $probeList2.Count -ne 0) {
    $script:HarnessError = $true
    Write-Output '[SELFTEST-HARNESS-ERROR] self-test mismatch engine sanity check failed'
  }
} catch {
  $script:HarnessError = $true
  Write-Output ('[SELFTEST-HARNESS-ERROR] mismatch engine sanity check threw: ' + [string]$_.Exception.Message)
}

# META-01 -------------------------------------------------------------------
if (Test-SelfSelected 'META-01') {
  try {
    $ctx = Invoke-MetaFixture -RunId 'META-01' -FixtureName 'pass.ps1'
    $m = New-Object System.Collections.ArrayList
    Add-Mismatch $m 'child exit' 0 $ctx.ExitCode
    Add-Mismatch $m 'timed out' $false $ctx.TimedOut
    Add-Mismatch $m 'evidence exists' $true $ctx.EvidenceExists
    Add-Mismatch $m 'evidence parse error' '' $ctx.EvidenceParseError
    if ($ctx.Evidence) {
      Add-Mismatch $m 'outcome' 'PASS' $ctx.Evidence.outcome
      Add-Mismatch $m 'evidence exitCode' 0 $ctx.Evidence.exitCode
      Add-Mismatch $m 'counts registered' 2 $ctx.Evidence.counts.registered
      Add-Mismatch $m 'counts executed' 2 $ctx.Evidence.counts.executed
      Add-Mismatch $m 'counts passed' 2 $ctx.Evidence.counts.passed
      Add-Mismatch $m 'counts failed' 0 $ctx.Evidence.counts.failed
      Add-Mismatch $m 'counts skipped' 0 $ctx.Evidence.counts.skipped
      Add-Mismatch $m 'git available' $true $ctx.Evidence.git.available
      if ($repoHead) { Add-Mismatch $m 'git HEAD' $repoHead $ctx.Evidence.git.head }
      Add-Mismatch $m 'startedAt format' $true ([string]$ctx.Evidence.startedAt -match '^\d{4}-\d{2}-\d{2}T')
      Add-Mismatch $m 'finishedAt format' $true ([string]$ctx.Evidence.finishedAt -match '^\d{4}-\d{2}-\d{2}T')
      Add-Mismatch $m 'case count' 2 @($ctx.Evidence.cases).Count
      foreach ($case in @($ctx.Evidence.cases)) {
        $caseId = [string]$case.id
        Add-Mismatch $m ('case ' + $caseId + ' status') 'pass' $case.status
        Add-Mismatch $m ('case ' + $caseId + ' passed flag') $true $case.passed
        foreach ($field in @('id', 'requirement', 'precondition', 'injectedFault', 'expected', 'actual', 'status', 'detail')) {
          Add-Mismatch $m ('case ' + $caseId + ' field ' + $field + ' present') $true ($null -ne $case.$field)
        }
        Add-Mismatch $m ('case ' + $caseId + ' durationMs numeric') $true ([int]$case.durationMs -ge 0)
        $caseEvidence = [string]$case.evidenceFile
        if ($caseEvidence) {
          Add-Mismatch $m ('case ' + $caseId + ' evidence file exists') $true (Test-Path -LiteralPath $caseEvidence -PathType Leaf)
        } else {
          Add-Mismatch $m ('case ' + $caseId + ' evidence file set') $true $false
        }
      }
      Add-Mismatch $m 'stdout result line' $true ($ctx.StdOut -match '(?m)^RESULT: PASS EXIT 0\s*$')
    } else {
      [void]$m.Add('evidence JSON was not produced or could not be parsed')
    }
    Complete-SelfCheck -Id 'META-01' -Name 'all valid tests pass -> exit 0 and evidence written' -Mismatches $m -Context $ctx -ExpectedExit '0' -Requirement 'META-01'
  } catch {
    $script:HarnessError = $true
    Add-SelfCheck -Id 'META-01' -Name 'all valid tests pass -> exit 0 and evidence written' -Passed $false -Detail ('[SELFTEST-HARNESS-ERROR] ' + [string]$_.Exception.Message) -Context $null -ExpectedExit '0' -Requirement 'META-01'
  }
}

# META-02 -------------------------------------------------------------------
if (Test-SelfSelected 'META-02') {
  try {
    $ctx = Invoke-MetaFixture -RunId 'META-02' -FixtureName 'fail.ps1'
    $m = New-Object System.Collections.ArrayList
    Add-Mismatch $m 'child exit' 1 $ctx.ExitCode
    Add-Mismatch $m 'evidence exists' $true $ctx.EvidenceExists
    if ($ctx.Evidence) {
      Add-Mismatch $m 'outcome' 'FAIL' $ctx.Evidence.outcome
      Add-Mismatch $m 'evidence exitCode' 1 $ctx.Evidence.exitCode
      Add-Mismatch $m 'counts executed' 2 $ctx.Evidence.counts.executed
      Add-Mismatch $m 'counts failed' 2 $ctx.Evidence.counts.failed
      Add-Mismatch $m 'counts passed' 0 $ctx.Evidence.counts.passed
      $failedCase = Get-EvidenceCase -Evidence $ctx.Evidence -CaseId 'FIX-FAIL-01'
      if ($failedCase) {
        Add-Mismatch $m 'failed case status' 'fail' $failedCase.status
        Add-Mismatch $m 'failed case passed flag' $false $failedCase.passed
        Add-Mismatch $m 'failed case detail non-empty' $true (([string]$failedCase.detail).Length -gt 0)
      } else {
        [void]$m.Add('failed case FIX-FAIL-01 missing from evidence')
      }
      Add-Mismatch $m 'stdout has FAIL line' $true ($ctx.StdOut -match '(?m)^\[FAIL\]')
      Add-Mismatch $m 'stdout result line' $true ($ctx.StdOut -match '(?m)^RESULT: FAIL EXIT 1\s*$')
    } else {
      [void]$m.Add('evidence JSON missing')
    }
    Complete-SelfCheck -Id 'META-02' -Name 'any executed test fails -> exit 1' -Mismatches $m -Context $ctx -ExpectedExit '1' -Requirement 'META-02'
  } catch {
    $script:HarnessError = $true
    Add-SelfCheck -Id 'META-02' -Name 'any executed test fails -> exit 1' -Passed $false -Detail ('[SELFTEST-HARNESS-ERROR] ' + [string]$_.Exception.Message) -Context $null -ExpectedExit '1' -Requirement 'META-02'
  }
}

# META-03 -------------------------------------------------------------------
if (Test-SelfSelected 'META-03') {
  try {
    $ctx = Invoke-MetaFixture -RunId 'META-03' -FixtureName 'harness-error.ps1'
    $m = New-Object System.Collections.ArrayList
    Add-Mismatch $m 'child exit' 3 $ctx.ExitCode
    Add-Mismatch $m 'evidence exists' $true $ctx.EvidenceExists
    if ($ctx.Evidence) {
      Add-Mismatch $m 'outcome' 'HARNESS_ERROR' $ctx.Evidence.outcome
      Add-Mismatch $m 'evidence exitCode' 3 $ctx.Evidence.exitCode
      Add-Mismatch $m 'harness error count' $true (@($ctx.Evidence.harnessErrors).Count -ge 1)
      if (@($ctx.Evidence.harnessErrors).Count -ge 1) {
        $first = @($ctx.Evidence.harnessErrors)[0]
        Add-Mismatch $m 'harness error stage' 'framework' $first.stage
        Add-Mismatch $m 'harness error mentions injected fault' $true (([string]$first.message) -match 'injected harness fault')
      }
      Add-Mismatch $m 'stdout has HARNESS-ERROR marker' $true ($ctx.StdOut -match '(?m)^\[HARNESS-ERROR\]')
      Add-Mismatch $m 'stdout result line' $true ($ctx.StdOut -match '(?m)^RESULT: HARNESS_ERROR EXIT 3\s*$')
    } else {
      [void]$m.Add('evidence JSON missing')
    }
    Complete-SelfCheck -Id 'META-03' -Name 'framework exception -> exit 3, not pass/fail' -Mismatches $m -Context $ctx -ExpectedExit '3' -Requirement 'META-03'
  } catch {
    $script:HarnessError = $true
    Add-SelfCheck -Id 'META-03' -Name 'framework exception -> exit 3, not pass/fail' -Passed $false -Detail ('[SELFTEST-HARNESS-ERROR] ' + [string]$_.Exception.Message) -Context $null -ExpectedExit '3' -Requirement 'META-03'
  }
}

# META-04 -------------------------------------------------------------------
if (Test-SelfSelected 'META-04') {
  try {
    $ctx = Invoke-MetaFixture -RunId 'META-04-empty' -FixtureName 'zero.ps1'
    $m = New-Object System.Collections.ArrayList
    Add-Mismatch $m 'zero-tests child exit' 2 $ctx.ExitCode
    Add-Mismatch $m 'zero-tests evidence exists' $true $ctx.EvidenceExists
    if ($ctx.Evidence) {
      Add-Mismatch $m 'zero-tests outcome' 'NO_TESTS_EXECUTED' $ctx.Evidence.outcome
      Add-Mismatch $m 'zero-tests evidence exitCode' 2 $ctx.Evidence.exitCode
      Add-Mismatch $m 'zero-tests executed count' 0 $ctx.Evidence.counts.executed
      Add-Mismatch $m 'zero-tests skipped count' 0 $ctx.Evidence.counts.skipped
      Add-Mismatch $m 'zero-tests stdout NO-TESTS marker' $true ($ctx.StdOut -match '(?m)^\[NO-TESTS\]')
      Add-Mismatch $m 'zero-tests stdout result line' $true ($ctx.StdOut -match '(?m)^RESULT: NO_TESTS_EXECUTED EXIT 2\s*$')
    } else {
      [void]$m.Add('zero-tests evidence JSON missing')
    }

    $ctx2 = Invoke-MetaFixture -RunId 'META-04-filter' -FixtureName 'pass.ps1' -FixtureFilter 'NO-SUCH-TEST-*'
    Add-Mismatch $m 'filtered child exit' 2 $ctx2.ExitCode
    Add-Mismatch $m 'filtered evidence exists' $true $ctx2.EvidenceExists
    if ($ctx2.Evidence) {
      Add-Mismatch $m 'filtered outcome' 'NO_TESTS_EXECUTED' $ctx2.Evidence.outcome
      Add-Mismatch $m 'filtered executed count' 0 $ctx2.Evidence.counts.executed
      Add-Mismatch $m 'filtered registered count' 0 $ctx2.Evidence.counts.registered
      Add-Mismatch $m 'filtered available count' 2 $ctx2.Evidence.counts.available
      Add-Mismatch $m 'filtered result line' $true ($ctx2.StdOut -match '(?m)^RESULT: NO_TESTS_EXECUTED EXIT 2\s*$')
    } else {
      [void]$m.Add('filtered evidence JSON missing')
    }
    Complete-SelfCheck -Id 'META-04' -Name 'zero executed tests -> exit 2 even with a filter' -Mismatches $m -Context $ctx -ExpectedExit '2' -Requirement 'META-04'
  } catch {
    $script:HarnessError = $true
    Add-SelfCheck -Id 'META-04' -Name 'zero executed tests -> exit 2 even with a filter' -Passed $false -Detail ('[SELFTEST-HARNESS-ERROR] ' + [string]$_.Exception.Message) -Context $null -ExpectedExit '2' -Requirement 'META-04'
  }
}

# META-05 -------------------------------------------------------------------
if (Test-SelfSelected 'META-05') {
  try {
    $ctx = Invoke-MetaFixture -RunId 'META-05-mixed' -FixtureName 'skip.ps1'
    $m = New-Object System.Collections.ArrayList
    Add-Mismatch $m 'mixed child exit' 0 $ctx.ExitCode
    Add-Mismatch $m 'mixed evidence exists' $true $ctx.EvidenceExists
    if ($ctx.Evidence) {
      Add-Mismatch $m 'mixed outcome' 'PASS' $ctx.Evidence.outcome
      Add-Mismatch $m 'mixed executed' 1 $ctx.Evidence.counts.executed
      Add-Mismatch $m 'mixed passed' 1 $ctx.Evidence.counts.passed
      Add-Mismatch $m 'mixed skipped' 1 $ctx.Evidence.counts.skipped
      $skippedCase = Get-EvidenceCase -Evidence $ctx.Evidence -CaseId 'FIX-SKIP-ONE'
      if ($skippedCase) {
        Add-Mismatch $m 'skipped case status' 'skip' $skippedCase.status
        Add-Mismatch $m 'skipped case passed flag' $false $skippedCase.passed
        Add-Mismatch $m 'skipped case reason recorded' $true (([string]$skippedCase.detail) -match 'fixture registration skip')
      } else {
        [void]$m.Add('skipped case FIX-SKIP-ONE missing from evidence')
      }
      Add-Mismatch $m 'mixed stdout SKIP marker' $true ($ctx.StdOut -match '(?m)^\[SKIP\]')
    } else {
      [void]$m.Add('mixed evidence JSON missing')
    }

    $ctx2 = Invoke-MetaFixture -RunId 'META-05-all' -FixtureName 'skip-all.ps1'
    Add-Mismatch $m 'all-skip child exit' 2 $ctx2.ExitCode
    if ($ctx2.Evidence) {
      Add-Mismatch $m 'all-skip outcome' 'NO_TESTS_EXECUTED' $ctx2.Evidence.outcome
      Add-Mismatch $m 'all-skip executed' 0 $ctx2.Evidence.counts.executed
      Add-Mismatch $m 'all-skip passed' 0 $ctx2.Evidence.counts.passed
      Add-Mismatch $m 'all-skip skipped' 1 $ctx2.Evidence.counts.skipped
      Add-Mismatch $m 'all-skip result line' $true ($ctx2.StdOut -match '(?m)^RESULT: NO_TESTS_EXECUTED EXIT 2\s*$')
    } else {
      [void]$m.Add('all-skip evidence JSON missing')
    }

    $ctx3 = Invoke-MetaFixture -RunId 'META-05-runtime' -FixtureName 'runtime-skip.ps1'
    Add-Mismatch $m 'runtime-skip child exit' 2 $ctx3.ExitCode
    if ($ctx3.Evidence) {
      Add-Mismatch $m 'runtime-skip executed' 0 $ctx3.Evidence.counts.executed
      Add-Mismatch $m 'runtime-skip skipped' 1 $ctx3.Evidence.counts.skipped
      $runtimeCase = Get-EvidenceCase -Evidence $ctx3.Evidence -CaseId 'FIX-SKIP-RUNTIME'
      if ($runtimeCase) {
        Add-Mismatch $m 'runtime-skip status' 'skip' $runtimeCase.status
        Add-Mismatch $m 'runtime-skip detail' $true (([string]$runtimeCase.detail) -match 'runtime skip')
      } else {
        [void]$m.Add('runtime skip case missing')
      }
    } else {
      [void]$m.Add('runtime-skip evidence JSON missing')
    }
    Complete-SelfCheck -Id 'META-05' -Name 'skips recorded separately; all-skip -> exit 2' -Mismatches $m -Context $ctx -ExpectedExit '0 mixed / 2 all-skip / 2 runtime' -Requirement 'META-05'
  } catch {
    $script:HarnessError = $true
    Add-SelfCheck -Id 'META-05' -Name 'skips recorded separately; all-skip -> exit 2' -Passed $false -Detail ('[SELFTEST-HARNESS-ERROR] ' + [string]$_.Exception.Message) -Context $null -ExpectedExit '2 (all-skip)' -Requirement 'META-05'
  }
}

# META-06 -------------------------------------------------------------------
if (Test-SelfSelected 'META-06') {
  try {
    $ctx = Invoke-MetaFixture -RunId 'META-06' -FixtureName 'evidence-fail.ps1' -BlockFinalEvidence
    $m = New-Object System.Collections.ArrayList
    Add-Mismatch $m 'child exit' 4 $ctx.ExitCode
    Add-Mismatch $m 'final evidence must not exist' $false $ctx.EvidenceExists
    Add-Mismatch $m 'stdout EVIDENCE-ERROR marker' $true ($ctx.StdOut -match '(?m)^\[EVIDENCE-ERROR\]')
    Add-Mismatch $m 'stdout shows the passing test' $true ($ctx.StdOut -match '(?m)^\[PASS\]')
    Add-Mismatch $m 'stdout counts passed=1' $true ($ctx.StdOut -match '(?m)^Counts: registered=1 executed=1 passed=1 failed=0 skipped=0')
    Add-Mismatch $m 'stdout result line' $true ($ctx.StdOut -match '(?m)^RESULT: EVIDENCE_ERROR EXIT 4\s*$')
    $caseEvidence = @(Get-ChildItem -LiteralPath $ctx.CasesDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
    Add-Mismatch $m 'per-case evidence still written' 1 $caseEvidence.Count

    $ctx2 = Invoke-MetaFixture -RunId 'META-06-case-evidence' -FixtureName 'evidence-fail.ps1' -BlockCaseEvidence
    Add-Mismatch $m 'case-evidence-fail child exit' 4 $ctx2.ExitCode
    Add-Mismatch $m 'case-evidence-fail final evidence exists' $true $ctx2.EvidenceExists
    if ($ctx2.Evidence) {
      Add-Mismatch $m 'case-evidence-fail outcome' 'EVIDENCE_ERROR' $ctx2.Evidence.outcome
      Add-Mismatch $m 'case-evidence-fail evidenceErrors' $true (@($ctx2.Evidence.evidenceErrors).Count -ge 1)
      Add-Mismatch $m 'case-evidence-fail per-case evidence file empty' '' ([string]@($ctx2.Evidence.cases)[0].evidenceFile)
    } else {
      [void]$m.Add('case-evidence-fail final evidence JSON missing')
    }
    Complete-SelfCheck -Id 'META-06' -Name 'final evidence write failure -> exit 4' -Mismatches $m -Context $ctx -ExpectedExit '4' -Requirement 'META-06'
  } catch {
    $script:HarnessError = $true
    Add-SelfCheck -Id 'META-06' -Name 'final evidence write failure -> exit 4' -Passed $false -Detail ('[SELFTEST-HARNESS-ERROR] ' + [string]$_.Exception.Message) -Context $null -ExpectedExit '4' -Requirement 'META-06'
  }
}

# META-07 -------------------------------------------------------------------
if (Test-SelfSelected 'META-07') {
  try {
    $ctx = Invoke-MetaFixture -RunId 'META-07' -FixtureName 'fail-then-pass.ps1'
    $m = New-Object System.Collections.ArrayList
    Add-Mismatch $m 'child exit' 1 $ctx.ExitCode
    Add-Mismatch $m 'evidence exists' $true $ctx.EvidenceExists
    if ($ctx.Evidence) {
      Add-Mismatch $m 'outcome' 'FAIL' $ctx.Evidence.outcome
      Add-Mismatch $m 'evidence exitCode' 1 $ctx.Evidence.exitCode
      Add-Mismatch $m 'counts executed' 2 $ctx.Evidence.counts.executed
      Add-Mismatch $m 'counts passed' 1 $ctx.Evidence.counts.passed
      Add-Mismatch $m 'counts failed' 1 $ctx.Evidence.counts.failed
      $cases = @($ctx.Evidence.cases)
      Add-Mismatch $m 'case count' 2 $cases.Count
      if ($cases.Count -ge 2) {
        Add-Mismatch $m 'first case status' 'fail' $cases[0].status
        Add-Mismatch $m 'second case status' 'pass' $cases[1].status
      }
      Add-Mismatch $m 'stdout still shows earlier FAIL' $true ($ctx.StdOut -match '(?m)^\[FAIL\] FIX-ORDER-01')
      Add-Mismatch $m 'stdout shows later PASS' $true ($ctx.StdOut -match '(?m)^\[PASS\] FIX-ORDER-02')
      Add-Mismatch $m 'stdout result line' $true ($ctx.StdOut -match '(?m)^RESULT: FAIL EXIT 1\s*$')
    } else {
      [void]$m.Add('evidence JSON missing')
    }
    Complete-SelfCheck -Id 'META-07' -Name 'later pass never overwrites an earlier failure' -Mismatches $m -Context $ctx -ExpectedExit '1' -Requirement 'META-07'
  } catch {
    $script:HarnessError = $true
    Add-SelfCheck -Id 'META-07' -Name 'later pass never overwrites an earlier failure' -Passed $false -Detail ('[SELFTEST-HARNESS-ERROR] ' + [string]$_.Exception.Message) -Context $null -ExpectedExit '1' -Requirement 'META-07'
  }
}

# negative controls for the self-test runner's own exit code (test-only)
if ($InjectCheckFailure -and (@($script:Checks | Where-Object { [string]$_.id -eq $InjectCheckFailure }).Count -eq 0)) {
  $script:HarnessError = $true
  Write-Output ('[SELFTEST-HARNESS-ERROR] injection target not found: ' + $InjectCheckFailure)
}
if ($InjectHarnessError) {
  throw 'injected self-test harness exception for aggregate exit-code control'
}

# --------------------------------------------------------------- aggregate --
$checks = @($script:Checks)
$selectedCount = @($script:Selected).Count
$passedChecks = @($checks | Where-Object { $_.passed }).Count
$failedChecks = $checks.Count - $passedChecks

function Get-SelfExitCode {
  if ($script:HarnessError) { return 3 }
  if ($script:EvidenceError) { return 4 }
  if ($checks.Count -ne $selectedCount) { return 3 }
  if ($failedChecks -gt 0) { return 1 }
  if ($checks.Count -eq 0) { return 2 }
  return 0
}

function Get-SelfOutcome {
  param([int]$Code)
  switch ($Code) {
    0 { return 'SELFTEST_PASS' }
    1 { return 'SELFTEST_FAIL' }
    2 { return 'NO_TESTS_EXECUTED' }
    3 { return 'HARNESS_ERROR' }
    4 { return 'EVIDENCE_ERROR' }
    default { return 'UNKNOWN' }
  }
}

$exitCode = Get-SelfExitCode
$outcome = Get-SelfOutcome -Code $exitCode
$script:Clock.Stop()
$finishedAt = Get-SelfTimestamp
$side = Get-SelfRepoSideInfo

$evidence = [ordered]@{
  schemaVersion = 1
  tool = 'proxy_v6/tests/self/SelfTest.ps1'
  startedAt = $script:StartedAt
  finishedAt = $finishedAt
  durationMs = [int][math]::Round($script:Clock.Elapsed.TotalMilliseconds)
  repoRoot = $repoRoot
  git = $side
  filter = $Filter
  selected = @($script:Selected)
  counts = [ordered]@{
    selected = $selectedCount
    checks = $checks.Count
    passed = $passedChecks
    failed = $failedChecks
  }
  exitCode = $exitCode
  outcome = $outcome
  checks = $checks
}

$selfEvidenceWritten = $false
if ($script:OutDirResolved) {
  try {
    $json = $evidence | ConvertTo-Json -Depth 8
    Write-TestTextFile -Path (Join-Path $script:OutDirResolved 'selftest.json') -Content ($json + [Environment]::NewLine)
    if (-not (Test-Path -LiteralPath (Join-Path $script:OutDirResolved 'selftest.json') -PathType Leaf)) { throw 'selftest.json missing after write' }
    $selfEvidenceWritten = $true
  } catch {
    $script:EvidenceError = $true
    Write-Output ('[EVIDENCE-ERROR] failed to write self-test evidence: ' + [string]$_.Exception.Message)
  }
} else {
  $script:EvidenceError = $true
  Write-Output '[EVIDENCE-ERROR] self-test output directory is unavailable'
}

if (-not $selfEvidenceWritten) {
  $exitCode = Get-SelfExitCode
  $outcome = Get-SelfOutcome -Code $exitCode
}

Write-Output '--------------------------------------------------------------'
Write-Output ('SELFTEST COUNTS: selected=' + [string]$selectedCount + ' checks=' + [string]$checks.Count + ' passed=' + [string]$passedChecks + ' failed=' + [string]$failedChecks)
if ($checks.Count -eq 0) { Write-Output '[NO-TESTS] no META check executed; a green result is not permitted (exit 2).' }
if ($script:OutDirResolved -and $selfEvidenceWritten) { Write-Output ('SELFTEST EVIDENCE: ' + (Join-Path $script:OutDirResolved 'selftest.json')) }
else { Write-Output 'SELFTEST EVIDENCE: NOT WRITTEN' }
Write-Output ('SELFTEST RESULT: ' + $outcome + ' EXIT ' + [string]$exitCode)

  $finalExitCode = $exitCode
} catch {
  Write-Output ('[SELFTEST-HARNESS-ERROR] ' + [string]$_.Exception.Message)
  Write-Output 'SELFTEST RESULT: HARNESS_ERROR EXIT 3'
  $finalExitCode = 3
} finally {
  if ($script:WorkRoot) {
    if ($KeepArtifacts) {
      Write-Output ('Artifacts kept: ' + $script:WorkRoot)
    } else {
      $removed = Remove-TestTempRoot -Path $script:WorkRoot
      if (-not $removed) { Write-Output ('[WARN] could not fully remove temp root: ' + $script:WorkRoot) }
    }
  }
}

exit $finalExitCode