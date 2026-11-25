#Requires -Version 5.1
<#
  Runs the reviewed proxy_v4 rollback script inside a temporary test root.
  V4_TEST_MODE is process-local logic, not an OS sandbox.
  The caller must pass the reviewed SHA-256 of rollback-v4.ps1 and V4.ps1.
  This script does not read or write the live HKCU proxy.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$EngineRoot,
    [Parameter(Mandatory = $true)][string]$WorkRoot,
    [Parameter(Mandatory = $true)][string]$ExpectedRollbackSha,
    [Parameter(Mandatory = $true)][string]$ExpectedLibrarySha
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Test-StrictChild([string]$Parent, [string]$Child) {
    $parentFull = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\', '/')
    $childFull = [System.IO.Path]::GetFullPath($Child).TrimEnd('\', '/')
    $prefix = $parentFull + [System.IO.Path]::DirectorySeparatorChar
    if (-not $childFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    $cursor = $childFull
    while ($cursor.Length -ge $parentFull.Length) {
        $item = Get-Item -LiteralPath $cursor -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        if ($cursor.Equals($parentFull, [StringComparison]::OrdinalIgnoreCase)) { break }
        $next = Split-Path -Parent $cursor
        if (-not $next -or $next.Equals($cursor, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        $cursor = $next
    }
    return $true
}

function Assert-ReviewedHash([string]$Path, [string]$Expected) {
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'refusing a reparse point' }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if (-not $actual.Equals($Expected, [StringComparison]::OrdinalIgnoreCase)) { throw 'reviewed hash mismatch' }
}

function Copy-ReviewedFile([string]$Source, [string]$Destination, [string]$Expected) {
    $stream = [System.IO.File]::Open($Source, 'Open', 'Read', 'Read')
    try {
        $memory = New-Object System.IO.MemoryStream
        $stream.CopyTo($memory)
        $bytes = $memory.ToArray()
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '') }
        finally { $sha.Dispose() }
        if (-not $hash.Equals($Expected, [StringComparison]::OrdinalIgnoreCase)) { throw 'reviewed hash mismatch while copying' }
        [System.IO.File]::WriteAllBytes($Destination, $bytes)
    }
    finally { $stream.Dispose() }
    Assert-ReviewedHash $Destination $Expected
}

foreach ($name in @(
    'V4_TEST_APPDATA', 'V4_TEST_RUNTIME', 'V4_TEST_INSTALL', 'V4_TEST_EXE', 'V4_TEST_CORE',
    'V4_TEST_UI_CONFIG', 'V4_TEST_UI_SYSTEM_PROXY', 'V4_TEST_PROXY_ENABLE', 'V4_TEST_PROXY_SERVER',
    'V4_TEST_ROOT', 'V4_TEST_START_LOG', 'V4_TEST_EXIT_AFTER_JOURNAL', 'PROXY_DOCTOR_ENGINE'
)) {
    Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue
}
$env:V4_TEST_MODE = '1'

$work = [System.IO.Path]::GetFullPath($WorkRoot)
$engine = [System.IO.Path]::GetFullPath($EngineRoot)
$temp = [System.IO.Path]::GetFullPath($env:TEMP)
if (-not (Test-StrictChild $temp $work)) { throw 'work root is not contained in TEMP' }
if ((Test-StrictChild $engine $work) -or (Test-StrictChild $work $engine)) { throw 'work root overlaps the engine' }
$rollbackSource = Join-Path $engine 'proxy_v4\rollback-v4.ps1'
$librarySource = Join-Path $engine 'proxy_v4\lib\V4.ps1'
Assert-ReviewedHash $rollbackSource $ExpectedRollbackSha
Assert-ReviewedHash $librarySource $ExpectedLibrarySha

$trace = Join-Path $work 'trace.log'
function Trace([string]$Message) {
    Add-Content -LiteralPath $trace -Value ((Get-Date).ToString('HH:mm:ss.fff') + ' ' + $Message)
}
Trace 'start'

$app = Join-Path $work 'appdata'
$snap = Join-Path $work 'snapshot'
New-Item -ItemType Directory -Path (Join-Path $app 'profiles') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $work 'lib') -Force | Out-Null
$beforeProfile = "fixture-profile-before`n"
$profile = Join-Path $app 'profiles.yaml'
[System.IO.File]::WriteAllText($profile, $beforeProfile)
Copy-ReviewedFile $rollbackSource (Join-Path $work 'rollback-v4.ps1') $ExpectedRollbackSha
Copy-ReviewedFile $librarySource (Join-Path $work 'lib\V4.ps1') $ExpectedLibrarySha

$env:V4_TEST_ROOT = $work
$env:V4_TEST_APPDATA = $app
$env:V4_TEST_PROXY_ENABLE = '0'
$env:V4_TEST_PROXY_SERVER = 'old:8080'
$env:V4_FIXTURE_PROXY_WRITE_LOG = Join-Path $work 'proxy-write.log'
. (Join-Path $work 'lib\V4.ps1')
if (-not $script:TestMode) { throw 'test mode was not enabled' }
$null = New-V4SnapshotFiles -AppData $app -ProfilesDir (Join-Path $app 'profiles') -Dir $snap -SystemProxy ([pscustomobject]@{ enabled = $true; server = 'old:8080' }) -ClashRunningBefore $false -Reason 'desktop-isolated'
$expectedHash = (Get-FileHash -LiteralPath (Join-Path $snap 'profiles.yaml') -Algorithm SHA256).Hash
[System.IO.File]::WriteAllText($profile, "fixture-profile-changed`n")

$stub = @'
if (-not $script:TestMode) { throw 'rollback fixture requires V4_TEST_MODE' }
Set-V4TestRegistryWriter {
    param($enabled, $server)
    $line = 'enabled=' + [int][bool]$enabled + ' server=' + $server
    Add-Content -LiteralPath $env:V4_FIXTURE_PROXY_WRITE_LOG -Value $line
    $env:V4_TEST_PROXY_ENABLE = if ($enabled) { '1' } else { '0' }
    $env:V4_TEST_PROXY_SERVER = $server
    [IO.File]::WriteAllText((Join-Path $env:V4_TEST_ROOT 'selection.json'), (@{ enabled = [bool]$enabled; server = [string]$server } | ConvertTo-Json -Compress))
}
function Start-V4Clash {
    param($TimeoutSec, $Port)
    $env:V4_TEST_PROXY_ENABLE = '1'
    $env:V4_TEST_PROXY_SERVER = 'old:8080'
    return $true
}
'@
Add-Content -LiteralPath (Join-Path $work 'lib\V4.ps1') -Encoding Ascii -Value $stub

$copied = Join-Path $work 'rollback-v4.ps1'
$saved = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
Trace 'child-begin'
try {
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $copied -SnapshotDir $snap 2>&1
    $code = $LASTEXITCODE
}
finally {
    Trace ('child-end code=' + $code)
    $ErrorActionPreference = $saved
}
if ($null -eq $code) { $code = 40 }

$writes = if (Test-Path -LiteralPath $env:V4_FIXTURE_PROXY_WRITE_LOG) { (Get-Content -LiteralPath $env:V4_FIXTURE_PROXY_WRITE_LOG -Raw) } else { '' }
$restoredHash = if (Test-Path -LiteralPath $profile) { (Get-FileHash -LiteralPath $profile -Algorithm SHA256).Hash } else { '' }
$tail = @($output | Select-Object -Last 8) -join ' | '
$traceTail = if (Test-Path -LiteralPath $trace) { (@(Get-Content -LiteralPath $trace | Select-Object -Last 6) -join ' | ') } else { '' }
$result = [ordered]@{
    exitCode = [int]$code
    writes = [string]$writes
    journalRemains = [bool](Test-Path -LiteralPath (Join-Path $work 'config\transaction.json'))
    profileRestored = ($restoredHash -eq $expectedHash)
    detail = ($tail + ' || ' + $traceTail)
    scriptStarted = $true
    liveRegistryTouched = $false
}
[System.IO.File]::WriteAllText((Join-Path $work 'result.json'), ($result | ConvertTo-Json -Compress))
exit 0
