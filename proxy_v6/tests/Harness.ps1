#Requires -Version 5.1
<#
  Harness.ps1 - V6 minimal test harness for Windows PowerShell 5.1.
  ASCII-only source. Dot-source this file from a top-level script.

  Contract enforced by Invoke-TestRun:
    0 = at least one test executed, every executed test passed, no harness
        error, final evidence written
    1 = at least one executed test failed
    2 = zero tests executed (no tests registered, filter matched nothing,
        or every selected test was skipped)
    3 = harness/framework exception
    4 = evidence write failed
  Precedence: 3 > 4 > 1 > 2 > 0.
#>

$harnessExisting = Get-Variable -Name 'HarnessLoaded' -ErrorAction SilentlyContinue
if ($harnessExisting -and $harnessExisting.Value) { return }

$script:HarnessLoaded = $true
$script:HarnessVersion = '6.0.0'
$script:HarnessTestsDir = $PSScriptRoot
$script:HarnessRepoRootDefault = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$script:HarnessTests = New-Object System.Collections.ArrayList
$script:HarnessErrors = New-Object System.Collections.ArrayList
$script:HarnessEvidenceErrors = New-Object System.Collections.ArrayList
$script:HarnessFaultStage = ''
$script:HarnessCaseActual = ''
$script:HarnessCaseAssertions = 0

# ---------------------------------------------------------------- small utils --
function Get-HarnessTimestamp {
  return (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz')
}

function Write-HarnessJsonFile {
  param([string]$Path, $Object, [int]$Depth = 8)
  $parent = Split-Path -Parent $Path
  if (-not $parent) { $parent = (Get-Location).Path }
  New-HarnessDirectory -Path $parent
  $json = $Object | ConvertTo-Json -Depth $Depth
  if ($null -eq $json -or ([string]$json).Length -eq 0) { throw 'ConvertTo-Json produced empty output' }
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, ([string]$json + [Environment]::NewLine), $enc)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw ('evidence file missing after write: ' + $Path) }
  if ((Get-Item -LiteralPath $Path).Length -le 0) { throw ('evidence file is empty: ' + $Path) }
}

function New-HarnessDirectory {
  param([string]$Path)
  if (-not $Path) { throw 'directory path is empty' }
  if (Test-Path -LiteralPath $Path -PathType Leaf) { throw ('path is a file, not a directory: ' + $Path) }
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
  }
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw ('directory was not created: ' + $Path) }
}

function Resolve-HarnessPath {
  param([string]$Path, [string]$BaseDir)
  if (-not $Path) { throw 'path is empty' }
  if ([System.IO.Path]::IsPathRooted($Path)) { return [System.IO.Path]::GetFullPath($Path) }
  return [System.IO.Path]::GetFullPath((Join-Path $BaseDir $Path))
}

function Limit-HarnessText {
  param([string]$Text, [int]$Max = 4000)
  if (-not $Text) { return '' }
  if ($Text.Length -le $Max) { return $Text }
  return ($Text.Substring(0, $Max) + '...[truncated ' + [string]($Text.Length - $Max) + ' chars]')
}

function Protect-HarnessText {
  param([string]$Text)
  if (-not $Text) { return $Text }
  $t = [string]$Text
  $t = [regex]::Replace($t, '(?i)(password|passwd|pwd|secret|token)(\s*[:=]\s*)("[^"]*"|[^\s,;}]+)', '$1$2***')
  $t = [regex]::Replace($t, '(?i)(username|user)(\s*[:=]\s*)("[^"]*"|[^\s,;}]+)', '$1$2***')
  $t = [regex]::Replace($t, '(?i)(Basic\s+)([A-Za-z0-9+/=]{8,})', '$1***')
  return $t
}

function Format-HarnessValue {
  param($Value)
  if ($null -eq $Value) { return '<null>' }
  $s = ''
  try { $s = [string]$Value } catch { return '<unprintable>' }
  return (Limit-HarnessText -Text $s -Max 300)
}

function Get-HarnessOutcome {
  param([int]$Code)
  switch ($Code) {
    0 { return 'PASS' }
    1 { return 'FAIL' }
    2 { return 'NO_TESTS_EXECUTED' }
    3 { return 'HARNESS_ERROR' }
    4 { return 'EVIDENCE_ERROR' }
    default { return 'UNKNOWN' }
  }
}

# --------------------------------------------------------------- error stores --
function Add-HarnessError {
  param([string]$Stage = 'framework', [string]$Message = 'unspecified harness error', [string]$Detail = '')
  [void]$script:HarnessErrors.Add([ordered]@{
    stage = (Protect-HarnessText $Stage)
    message = (Protect-HarnessText $Message)
    detail = (Protect-HarnessText ([string]$Detail))
    at = (Get-HarnessTimestamp)
  })
}

function Add-EvidenceError {
  param([string]$Stage = 'evidence', [string]$Message = 'unspecified evidence error')
  [void]$script:HarnessEvidenceErrors.Add([ordered]@{
    stage = (Protect-HarnessText $Stage)
    message = (Protect-HarnessText $Message)
    at = (Get-HarnessTimestamp)
  })
}

# --------------------------------------------------------------- assertions ---
function New-HarnessAssertion {
  param([string]$Message)
  throw ('__HARNESS_ASSERT__:' + $Message)
}

function Assert-Fail {
  param([string]$Message = 'assertion failed')
  $script:HarnessCaseAssertions = [int]$script:HarnessCaseAssertions + 1
  New-HarnessAssertion $Message
}

function Assert-True {
  param($Condition, [string]$Message = 'expected condition to be true')
  $script:HarnessCaseAssertions = [int]$script:HarnessCaseAssertions + 1
  if (-not $Condition) { New-HarnessAssertion ($Message + ' (actual: ' + (Format-HarnessValue $Condition) + ')') }
}

function Assert-False {
  param($Condition, [string]$Message = 'expected condition to be false')
  $script:HarnessCaseAssertions = [int]$script:HarnessCaseAssertions + 1
  if ($Condition) { New-HarnessAssertion ($Message + ' (actual: ' + (Format-HarnessValue $Condition) + ')') }
}

function Test-HarnessEqual {
  param($Left, $Right)
  if ($null -eq $Left -and $null -eq $Right) { return $true }
  if ($null -eq $Left -or $null -eq $Right) { return $false }
  $leftIsArray = $Left -is [System.Array]
  $rightIsArray = $Right -is [System.Array]
  if ($leftIsArray -or $rightIsArray) {
    $la = @($Left)
    $ra = @($Right)
    if ($la.Count -ne $ra.Count) { return $false }
    for ($i = 0; $i -lt $la.Count; $i++) {
      if (-not (Test-HarnessEqual $la[$i] $ra[$i])) { return $false }
    }
    return $true
  }
  return ($Left -eq $Right)
}

function Assert-Equal {
  param($Expected, $Actual, [string]$Message = 'values are not equal')
  $script:HarnessCaseAssertions = [int]$script:HarnessCaseAssertions + 1
  if (-not (Test-HarnessEqual $Expected $Actual)) {
    New-HarnessAssertion ($Message + ' (expected: ' + (Format-HarnessValue $Expected) + '; actual: ' + (Format-HarnessValue $Actual) + ')')
  }
}

function Assert-NotEqual {
  param($Left, $Right, [string]$Message = 'values are equal')
  $script:HarnessCaseAssertions = [int]$script:HarnessCaseAssertions + 1
  if (Test-HarnessEqual $Left $Right) {
    New-HarnessAssertion ($Message + ' (both: ' + (Format-HarnessValue $Left) + ')')
  }
}

function Assert-Null {
  param($Value, [string]$Message = 'expected value to be null')
  $script:HarnessCaseAssertions = [int]$script:HarnessCaseAssertions + 1
  if ($null -ne $Value) { New-HarnessAssertion ($Message + ' (actual: ' + (Format-HarnessValue $Value) + ')') }
}

function Assert-NotNull {
  param($Value, [string]$Message = 'expected value not to be null')
  $script:HarnessCaseAssertions = [int]$script:HarnessCaseAssertions + 1
  if ($null -eq $Value) { New-HarnessAssertion $Message }
}

function Assert-Match {
  param([string]$Text, [string]$Pattern, [string]$Message = 'text did not match pattern')
  $script:HarnessCaseAssertions = [int]$script:HarnessCaseAssertions + 1
  if ($Text -notmatch $Pattern) {
    New-HarnessAssertion ($Message + ' (pattern: ' + $Pattern + '; actual: ' + (Format-HarnessValue $Text) + ')')
  }
}

function Assert-NotMatch {
  param([string]$Text, [string]$Pattern, [string]$Message = 'text matched forbidden pattern')
  $script:HarnessCaseAssertions = [int]$script:HarnessCaseAssertions + 1
  if ($Text -match $Pattern) {
    New-HarnessAssertion ($Message + ' (pattern: ' + $Pattern + '; actual: ' + (Format-HarnessValue $Text) + ')')
  }
}

function Assert-Contains {
  param([string]$Text, [string]$ExpectedSubstring, [string]$Message = 'text did not contain expected substring')
  $script:HarnessCaseAssertions = [int]$script:HarnessCaseAssertions + 1
  if ($null -eq $Text -or $Text.IndexOf($ExpectedSubstring, [System.StringComparison]::Ordinal) -lt 0) {
    New-HarnessAssertion ($Message + ' (substring: ' + $ExpectedSubstring + '; actual: ' + (Format-HarnessValue $Text) + ')')
  }
}

function Assert-NotContains {
  param([string]$Text, [string]$ForbiddenSubstring, [string]$Message = 'text contained forbidden substring')
  $script:HarnessCaseAssertions = [int]$script:HarnessCaseAssertions + 1
  if ($null -ne $Text -and $Text.IndexOf($ForbiddenSubstring, [System.StringComparison]::Ordinal) -ge 0) {
    New-HarnessAssertion ($Message + ' (substring: ' + $ForbiddenSubstring + '; actual: ' + (Format-HarnessValue $Text) + ')')
  }
}

function Assert-FileExists {
  param([string]$Path, [string]$Message = 'expected file to exist')
  $script:HarnessCaseAssertions = [int]$script:HarnessCaseAssertions + 1
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { New-HarnessAssertion ($Message + ' (path: ' + $Path + ')') }
}

function Assert-FileNotExists {
  param([string]$Path, [string]$Message = 'expected file not to exist')
  $script:HarnessCaseAssertions = [int]$script:HarnessCaseAssertions + 1
  if (Test-Path -LiteralPath $Path) { New-HarnessAssertion ($Message + ' (path: ' + $Path + ')') }
}

function Assert-FileHashEqual {
  param([string]$Path, [string]$ExpectedHash, [string]$Message = 'file hash mismatch')
  $script:HarnessCaseAssertions = [int]$script:HarnessCaseAssertions + 1
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { New-HarnessAssertion ($Message + ' (missing file: ' + $Path + ')'); return }
  $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
  if (([string]$actual).ToUpperInvariant() -ne ([string]$ExpectedHash).ToUpperInvariant()) {
    New-HarnessAssertion ($Message + ' (expected: ' + $ExpectedHash + '; actual: ' + $actual + ')')
  }
}

function Assert-Throws {
  param([scriptblock]$Action, [string]$Pattern = '', [string]$Message = 'expected action to throw')
  $script:HarnessCaseAssertions = [int]$script:HarnessCaseAssertions + 1
  $threw = $false
  $text = ''
  try { & $Action | Out-Null } catch { $threw = $true; $text = [string]$_.Exception.Message }
  if (-not $threw) { New-HarnessAssertion ($Message + ' (no exception was thrown)') }
  if ($Pattern -and ($text -notmatch $Pattern)) {
    New-HarnessAssertion ($Message + ' (exception did not match pattern: ' + $Pattern + '; actual: ' + (Format-HarnessValue $text) + ')')
  }
  return $text
}

function Assert-NoThrow {
  param([scriptblock]$Action, [string]$Message = 'expected action not to throw')
  $script:HarnessCaseAssertions = [int]$script:HarnessCaseAssertions + 1
  try { & $Action | Out-Null } catch {
    New-HarnessAssertion ($Message + ' (exception: ' + (Format-HarnessValue $_.Exception.Message) + ')')
  }
}

function Set-TestActual {
  param([string]$Value)
  $script:HarnessCaseActual = [string]$Value
}

function Skip-HarnessTest {
  param([string]$Reason = 'unspecified runtime skip')
  throw ('__HARNESS_SKIP__:' + $Reason)
}

# ------------------------------------------------------------------ registry --
function Register-Test {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Requirement,
    [Parameter(Mandatory = $true)][scriptblock]$Body,
    [string]$Precondition = '',
    [string]$InjectedFault = 'none',
    [string]$Expected = '',
    [switch]$Skip,
    [string]$SkipReason = ''
  )
  $isSkip = [bool]$Skip
  $reason = [string]$SkipReason
  if ($isSkip -and -not $reason) { $reason = 'unspecified registration skip' }
  [void]$script:HarnessTests.Add([pscustomobject]@{
    Id = [string]$Id
    Requirement = [string]$Requirement
    Precondition = [string]$Precondition
    InjectedFault = [string]$InjectedFault
    Expected = [string]$Expected
    Body = $Body
    Skip = $isSkip
    SkipReason = $reason
    RegisteredAt = (Get-HarnessTimestamp)
  })
}

function Test-HarnessRegistry {
  $seen = @{}
  foreach ($t in @($script:HarnessTests)) {
    $id = [string]$t.Id
    if (-not $id.Trim()) {
      Add-HarnessError 'validate' 'registered test has an empty id'
      continue
    }
    if ($seen.ContainsKey($id)) {
      Add-HarnessError 'validate' ('duplicate test id: ' + $id)
    } else {
      $seen[$id] = $true
    }
    if (-not ([string]$t.Requirement).Trim()) {
      Add-HarnessError 'validate' ('test has an empty requirement: ' + $id)
    }
    if ($null -eq $t.Body) {
      Add-HarnessError 'validate' ('test has no body: ' + $id)
    }
  }
}

function Select-HarnessTests {
  param([string]$Filter = '*')
  if (-not $Filter) { $Filter = '*' }
  return @($script:HarnessTests | Where-Object { ([string]$_.Id) -like $Filter })
}

function Get-HarnessCounts {
  param($Cases)
  $arr = @($Cases)
  $passed = 0
  $failed = 0
  $skipped = 0
  foreach ($c in $arr) {
    switch ([string]$c.status) {
      'pass' { $passed++ }
      'fail' { $failed++ }
      'skip' { $skipped++ }
      default { $failed++ }
    }
  }
  return [ordered]@{
    registered = $arr.Count
    executed = ($passed + $failed)
    passed = $passed
    failed = $failed
    skipped = $skipped
  }
}

# ------------------------------------------------------------------ git/host --
function Invoke-HarnessGit {
  param([string]$RepoRoot, [string[]]$GitArgs)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = & git -C $RepoRoot @GitArgs 2>$null
    $code = $LASTEXITCODE
    return [pscustomobject]@{ code = $code; output = @($output) }
  } catch {
    return [pscustomobject]@{ code = -1; output = @(); error = [string]$_.Exception.Message }
  } finally {
    $ErrorActionPreference = $prev
  }
}

function Get-HarnessGitInfo {
  param([string]$RepoRoot)
  $info = [ordered]@{ available = $false; head = $null; branch = $null; dirty = $null; error = $null }
  if (-not $RepoRoot) { $info.error = 'repo root not provided'; return $info }
  $head = Invoke-HarnessGit -RepoRoot $RepoRoot -GitArgs @('rev-parse', 'HEAD')
  if ($head.code -ne 0 -or @($head.output).Count -eq 0) {
    $info.error = 'git rev-parse HEAD failed'
    return $info
  }
  $info.head = ([string](@($head.output)[0])).Trim()
  $info.available = $true
  $branch = Invoke-HarnessGit -RepoRoot $RepoRoot -GitArgs @('rev-parse', '--abbrev-ref', 'HEAD')
  if ($branch.code -eq 0 -and @($branch.output).Count -gt 0) { $info.branch = ([string](@($branch.output)[0])).Trim() }
  $dirty = Invoke-HarnessGit -RepoRoot $RepoRoot -GitArgs @('status', '--porcelain')
  if ($dirty.code -eq 0) {
    $text = (@($dirty.output) -join [Environment]::NewLine).Trim()
    $info.dirty = ($text.Length -gt 0)
  }
  return $info
}

function Get-HarnessHostInfo {
  return [ordered]@{
    psVersion = $PSVersionTable.PSVersion.ToString()
    psEdition = [string]$PSVersionTable.PSEdition
    os = [System.Environment]::OSVersion.VersionString
    clr = [System.Environment]::Version.ToString()
    is64BitProcess = [System.Environment]::Is64BitProcess
    pid = $PID
  }
}

# -------------------------------------------------------------- fault injection --
function Invoke-HarnessFaultStage {
  param([string]$Stage)
  if ($script:HarnessFaultStage -and $script:HarnessFaultStage -eq $Stage) {
    throw ('injected harness fault at stage: ' + $Stage)
  }
}

# ------------------------------------------------------------- case execution --
function Invoke-HarnessCase {
  param($Test, [string]$EvidenceDir, [int]$Index)

  $startedAt = Get-HarnessTimestamp
  $clock = [System.Diagnostics.Stopwatch]::StartNew()
  $script:HarnessCaseActual = ''
  $script:HarnessCaseAssertions = 0
  $status = 'fail'
  $detail = ''
  $testOutput = ''

  if ($Test.Skip) {
    $status = 'skip'
    $detail = 'skipped at registration: ' + [string]$Test.SkipReason
    $script:HarnessCaseActual = 'skipped'
  } else {
    $prevEap = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Stop'
      $raw = & $Test.Body *>&1 | Out-String
      $testOutput = [string]$raw
      $status = 'pass'
      if ([int]$script:HarnessCaseAssertions -gt 0) {
        $detail = 'assertions passed: ' + [string]$script:HarnessCaseAssertions
        if (-not $script:HarnessCaseActual) { $script:HarnessCaseActual = 'all assertions passed' }
      } else {
        $detail = 'body completed without assertions or exceptions'
        if (-not $script:HarnessCaseActual) { $script:HarnessCaseActual = 'body completed' }
      }
    } catch {
      $msg = [string]$_.Exception.Message
      $assertPrefix = '__HARNESS_ASSERT__:'
      $skipPrefix = '__HARNESS_SKIP__:'
      if ($msg.StartsWith($skipPrefix)) {
        $status = 'skip'
        $detail = 'skipped at runtime: ' + $msg.Substring($skipPrefix.Length)
        $script:HarnessCaseActual = 'skipped'
      } elseif ($msg.StartsWith($assertPrefix)) {
        $status = 'fail'
        $detail = 'assertion failed: ' + $msg.Substring($assertPrefix.Length)
        if (-not $script:HarnessCaseActual) { $script:HarnessCaseActual = $detail }
      } else {
        $status = 'fail'
        $detail = 'unexpected exception: ' + $msg
        if ($_.ScriptStackTrace) {
          $stackText = (@([string]$_.ScriptStackTrace -split [Environment]::NewLine) | ForEach-Object { [string]$_ }) -join ' | '
          $detail = $detail + ' | stack: ' + $stackText
        }
        if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
          $atText = (@([string]$_.InvocationInfo.PositionMessage -split [Environment]::NewLine) | ForEach-Object { [string]$_ }) -join ' | '
          $detail = $detail + ' | at: ' + $atText
        }
        $script:HarnessCaseActual = 'unexpected exception'
      }
      $testOutput = [string]$testOutput
    } finally {
      $ErrorActionPreference = $prevEap
    }
  }

  $clock.Stop()
  if (-not $script:HarnessCaseActual) { $script:HarnessCaseActual = $status }
  $durationMs = [int][math]::Round($clock.Elapsed.TotalMilliseconds)
  $record = [ordered]@{
    id = [string]$Test.Id
    requirement = [string]$Test.Requirement
    precondition = Protect-HarnessText ([string]$Test.Precondition)
    injectedFault = Protect-HarnessText ([string]$Test.InjectedFault)
    expected = Protect-HarnessText ([string]$Test.Expected)
    actual = Protect-HarnessText ([string]$script:HarnessCaseActual)
    status = $status
    passed = ($status -eq 'pass')
    detail = Protect-HarnessText $detail
    durationMs = $durationMs
    assertions = [int]$script:HarnessCaseAssertions
    startedAt = $startedAt
    finishedAt = Get-HarnessTimestamp
    evidenceFile = ''
    testOutput = Protect-HarnessText (Limit-HarnessText -Text $testOutput -Max 8000)
  }

  if ($EvidenceDir) {
    $safe = ([string]$Test.Id) -replace '[^A-Za-z0-9._-]', '_'
    if ($safe.Length -gt 60) { $safe = $safe.Substring(0, 60) }
    $path = Join-Path $EvidenceDir ('{0:D4}-{1}.json' -f $Index, $safe)
    $record.evidenceFile = $path
    try {
      Write-HarnessJsonFile -Path $path -Object $record -Depth 6
    } catch {
      $record.evidenceFile = ''
      Add-EvidenceError 'case-evidence' ('failed to write case evidence for ' + [string]$Test.Id + ': ' + [string]$_.Exception.Message)
    }
  } else {
    Add-EvidenceError 'case-evidence' ('no evidence directory available for test ' + [string]$Test.Id)
  }
  return $record
}

# ------------------------------------------------------------------ reporting --
function Write-HarnessSummary {
  param($Result)
  Write-Host ''
  Write-Host ('== V6 TEST HARNESS ' + $script:HarnessVersion + ' ==')
  Write-Host ('Run ID: ' + [string]$Result.runId)
  if ($Result.git.available) {
    Write-Host ('Git HEAD: ' + [string]$Result.git.head)
    if ($Result.git.branch) { Write-Host ('Git branch: ' + [string]$Result.git.branch) }
  } else {
    Write-Host ('Git HEAD: unavailable (' + [string]$Result.git.error + ')')
  }
  Write-Host ('Filter: ' + [string]$Result.filter)
  Write-Host '--------------------------------------------------------------'
  foreach ($c in @($Result.cases)) {
    Write-Host ('[' + ([string]$c.status).ToUpperInvariant() + '] ' + [string]$c.id + ' (' + [string]$c.requirement + ') ' + [string]$c.durationMs + 'ms')
    if ([string]$c.status -eq 'fail') { Write-Host ('       ' + [string]$c.detail) }
    if ([string]$c.status -eq 'skip') { Write-Host ('       ' + [string]$c.detail) }
  }
  foreach ($e in @($Result.harnessErrors)) {
    Write-Host ('[HARNESS-ERROR] ' + [string]$e.stage + ': ' + [string]$e.message)
    if ($e.detail) { Write-Host ('       ' + [string]$e.detail) }
  }
  foreach ($e in @($Result.evidenceErrors)) {
    Write-Host ('[EVIDENCE-ERROR] ' + [string]$e.stage + ': ' + [string]$e.message)
  }
  Write-Host '--------------------------------------------------------------'
  Write-Host ('Counts: registered=' + [string]$Result.counts.registered + ' executed=' + [string]$Result.counts.executed + ' passed=' + [string]$Result.counts.passed + ' failed=' + [string]$Result.counts.failed + ' skipped=' + [string]$Result.counts.skipped + ' available=' + [string]$Result.counts.available)
  if ([int]$Result.counts.executed -eq 0) { Write-Host '[NO-TESTS] no test executed; a green result is not permitted (exit 2).' }
  if ($Result.evidenceFile) { Write-Host ('Evidence: ' + [string]$Result.evidenceFile) }
  else { Write-Host 'Evidence: NOT WRITTEN' }
  Write-Host ('RESULT: ' + [string]$Result.outcome + ' EXIT ' + [string]$Result.exitCode)
}

function Get-HarnessExitCode {
  param($Counts)
  if (@($script:HarnessErrors).Count -gt 0) { return 3 }
  if (@($script:HarnessEvidenceErrors).Count -gt 0) { return 4 }
  if ([int]$Counts.failed -gt 0) { return 1 }
  if ([int]$Counts.executed -eq 0) { return 2 }
  if ([int]$Counts.passed -ne [int]$Counts.executed) { return 1 }
  return 0
}

# ------------------------------------------------------------------- run entry --
function Invoke-TestRun {
  [CmdletBinding()]
  param(
    [string]$OutFile = '',
    [string]$EvidenceDir = '',
    [string]$Filter = '*',
    [string]$RepoRoot = '',
    [string]$FaultStage = '',
    [switch]$Quiet
  )

  $runStartedAt = Get-HarnessTimestamp
  $clock = [System.Diagnostics.Stopwatch]::StartNew()
  $runId = [guid]::NewGuid().ToString('N')
  $script:HarnessFaultStage = [string]$FaultStage
  $cases = New-Object System.Collections.ArrayList
  $selected = @()
  $resolvedOutFile = ''
  $resolvedEvidenceDir = ''
  $evidenceDirReady = $false

  try {
    if (-not $RepoRoot) { $RepoRoot = $script:HarnessRepoRootDefault }
    $runStamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $cwd = (Get-Location).Path
    if (-not $OutFile) {
      $base = Join-Path (Join-Path $script:HarnessRepoRootDefault 'proxy_v6\evidence') ('v6\' + $runStamp)
      $OutFile = Join-Path $base 'evidence.json'
    }
    $resolvedOutFile = Resolve-HarnessPath -Path $OutFile -BaseDir $cwd
    if (-not $EvidenceDir) {
      $outParent = Split-Path -Parent $resolvedOutFile
      $outLeaf = Split-Path -Leaf $resolvedOutFile
      $EvidenceDir = Join-Path $outParent ($outLeaf + '.cases')
    }
    $resolvedEvidenceDir = Resolve-HarnessPath -Path $EvidenceDir -BaseDir $cwd

    try {
      New-HarnessDirectory -Path $resolvedEvidenceDir
      $evidenceDirReady = $true
    } catch {
      Add-EvidenceError 'evidence-dir' ('cannot create evidence directory: ' + [string]$_.Exception.Message)
      $evidenceDirReady = $false
    }

    $knownFaultStages = @('after-start', 'after-validate', 'after-selection', 'before-summary')
    if ($script:HarnessFaultStage -and -not ($knownFaultStages -contains $script:HarnessFaultStage)) {
      Add-HarnessError 'fault-injection' ('unknown fault stage: ' + [string]$script:HarnessFaultStage)
    }

    Invoke-HarnessFaultStage 'after-start'
    Test-HarnessRegistry
    Invoke-HarnessFaultStage 'after-validate'
    $selected = @(Select-HarnessTests -Filter $Filter)
    Invoke-HarnessFaultStage 'after-selection'

    $index = 0
    foreach ($t in $selected) {
      $index++
      if ($evidenceDirReady) { $caseEvidenceDir = $resolvedEvidenceDir } else { $caseEvidenceDir = '' }
      $caseRecord = Invoke-HarnessCase -Test $t -EvidenceDir $caseEvidenceDir -Index $index
      [void]$cases.Add($caseRecord)
    }
    Invoke-HarnessFaultStage 'before-summary'
  } catch {
    Add-HarnessError 'framework' ('unhandled framework exception: ' + [string]$_.Exception.Message) ([string]$_.ScriptStackTrace)
  }

  $clock.Stop()
  $counts = Get-HarnessCounts -Cases $cases
  $counts.registered = @($selected).Count
  $counts.available = @($script:HarnessTests).Count
  $exitCode = Get-HarnessExitCode -Counts $counts
  $outcome = Get-HarnessOutcome -Code $exitCode
  $gitInfo = Get-HarnessGitInfo -RepoRoot $RepoRoot
  $finishedAt = Get-HarnessTimestamp

  $evidence = [ordered]@{
    schemaVersion = 1
    tool = 'proxy_v6/tests/Harness.ps1'
    harnessVersion = $script:HarnessVersion
    runId = $runId
    host = (Get-HarnessHostInfo)
    git = $gitInfo
    repoRoot = $RepoRoot
    filter = $Filter
    startedAt = $runStartedAt
    finishedAt = $finishedAt
    durationMs = [int][math]::Round($clock.Elapsed.TotalMilliseconds)
    counts = $counts
    exitCode = $exitCode
    outcome = $outcome
    harnessErrors = @($script:HarnessErrors)
    evidenceErrors = @($script:HarnessEvidenceErrors)
    cases = @($cases)
  }

  $evidenceFileWritten = $false
  if ($resolvedOutFile) {
    try {
      Write-HarnessJsonFile -Path $resolvedOutFile -Object $evidence -Depth 8
      $evidenceFileWritten = $true
    } catch {
      Add-EvidenceError 'final-evidence' ('failed to write final evidence: ' + [string]$_.Exception.Message)
    }
  } else {
    Add-EvidenceError 'final-evidence' 'no final evidence path was resolved'
  }

  if (-not $evidenceFileWritten) {
    $exitCode = Get-HarnessExitCode -Counts $counts
    $outcome = Get-HarnessOutcome -Code $exitCode
  }

  $result = [pscustomobject]@{
    runId = $runId
    outcome = $outcome
    exitCode = $exitCode
    counts = $counts
    cases = @($cases)
    harnessErrors = @($script:HarnessErrors)
    evidenceErrors = @($script:HarnessEvidenceErrors)
    evidenceFile = $(if ($evidenceFileWritten) { $resolvedOutFile } else { '' })
    evidenceDir = $resolvedEvidenceDir
    git = $gitInfo
    filter = $Filter
    startedAt = $runStartedAt
    finishedAt = (Get-HarnessTimestamp)
  }

  if (-not $Quiet) { Write-HarnessSummary -Result $result }
  return $result
}
