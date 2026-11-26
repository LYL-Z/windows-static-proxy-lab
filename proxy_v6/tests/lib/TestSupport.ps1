#Requires -Version 5.1
<#
  TestSupport.ps1 - isolation and child-process helpers for V6 scenario tests.
  ASCII-only source. Dot-source after Harness.ps1 (Run-Tests.ps1 does this).
  Every scenario test should work under a directory returned by New-TestTempRoot
  and must remove it in a finally block with Remove-TestTempRoot.
#>

$supportExisting = Get-Variable -Name 'TestSupportLoaded' -ErrorAction SilentlyContinue
if ($supportExisting -and $supportExisting.Value) { return }

$script:TestSupportLoaded = $true

function New-TestDirectory {
  param([string]$Path)
  if (-not $Path) { throw 'directory path is empty' }
  if (Test-Path -LiteralPath $Path -PathType Leaf) { throw ('path is a file, not a directory: ' + $Path) }
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
  }
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw ('directory was not created: ' + $Path) }
}

function New-TestTempRoot {
  param([string]$Prefix = 'v6-test')
  if (-not $env:TEMP) { throw 'TEMP is not defined; isolated tests require a temp directory' }
  $base = Join-Path $env:TEMP 'v6-tests'
  New-TestDirectory -Path $base
  $safe = ($Prefix -replace '[^A-Za-z0-9._-]', '_')
  if ($safe.Length -gt 40) { $safe = $safe.Substring(0, 40) }
  $leaf = $safe + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
  $root = Join-Path $base $leaf
  New-TestDirectory -Path $root
  return $root
}

function Remove-TestTempRoot {
  param([string]$Path)
  if (-not $Path) { return $true }
  for ($i = 0; $i -lt 6; $i++) {
    try {
      if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
      }
      if (-not (Test-Path -LiteralPath $Path)) { return $true }
    } catch {
      Start-Sleep -Milliseconds (150 * ($i + 1))
    }
  }
  return (-not (Test-Path -LiteralPath $Path))
}

function Write-TestTextFile {
  param([string]$Path, [string]$Content = '')
  $parent = Split-Path -Parent $Path
  if ($parent) { New-TestDirectory -Path $parent }
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, ([string]$Content), $enc)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw ('file was not written: ' + $Path) }
}

function Read-TestTextFile {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Get-TestFileHash {
  param([string]$Path)
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function New-TestBlockingFile {
  param([string]$Path)
  Write-TestTextFile -Path $Path -Content 'blocking file: a directory cannot be created at this path'
  return $Path
}

function Get-TestPowerShellPath {
  $candidate = Join-Path $PSHOME 'powershell.exe'
  if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
  return 'powershell.exe'
}

function Quote-TestProcessArgument {
  param([string]$Value)
  $v = [string]$Value
  if ($v -notmatch '[\s"]') { return $v }
  return ('"' + ($v -replace '"', '\"') + '"')
}

function Invoke-TestChildPowerShell {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    [string[]]$Arguments = @(),
    [int]$TimeoutMs = 180000
  )
  if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) { throw ('child script not found: ' + $ScriptPath) }
  $exe = Get-TestPowerShellPath
  $argParts = New-Object System.Collections.ArrayList
  [void]$argParts.Add('-NoProfile')
  [void]$argParts.Add('-NonInteractive')
  [void]$argParts.Add('-ExecutionPolicy')
  [void]$argParts.Add('Bypass')
  [void]$argParts.Add('-File')
  [void]$argParts.Add((Quote-TestProcessArgument $ScriptPath))
  foreach ($a in @($Arguments)) { [void]$argParts.Add((Quote-TestProcessArgument ([string]$a))) }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $exe
  $psi.Arguments = ($argParts -join ' ')
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.WorkingDirectory = (Get-Location).Path

  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $psi
  $started = $false
  try {
    $started = $process.Start()
    if (-not $started) { throw 'child process failed to start' }
    $outTask = $process.StandardOutput.ReadToEndAsync()
    $errTask = $process.StandardError.ReadToEndAsync()
    $exited = $process.WaitForExit($TimeoutMs)
    $timedOut = -not $exited
    if ($timedOut) {
      try { $process.Kill() } catch { }
      [void]$process.WaitForExit(10000)
    }
    $stdout = ''
    $stderr = ''
    try { $stdout = [string]$outTask.Result } catch { $stdout = '' }
    try { $stderr = [string]$errTask.Result } catch { $stderr = '' }
    $code = -1
    if ($exited) {
      try { $code = [int]$process.ExitCode } catch { $code = -1 }
    }
    return [pscustomobject]@{
      ExitCode = $code
      TimedOut = $timedOut
      StdOut = $stdout
      StdErr = $stderr
      FileName = $exe
      Arguments = $psi.Arguments
    }
  } finally {
    if ($started) { try { $process.Dispose() } catch { } }
  }
}
