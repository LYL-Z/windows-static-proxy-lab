#Requires -Version 5.1
<#
  Runs the real proxy_v4 rollback script inside a temporary test root.
  V4_TEST_MODE is forced on. The script refuses to use a work directory
  outside TEMP, and the appended library stub throws unless test mode is on.
  It does not read or write the live HKCU proxy.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$EngineRoot,
    [Parameter(Mandatory = $true)][string]$WorkRoot
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$trace = Join-Path $env:TEMP 'proxy-doctor-trace.txt'
function Trace([string]$Message) {
    Add-Content -LiteralPath $trace -Value ((Get-Date).ToString('HH:mm:ss.fff') + ' ' + $Message)
}
Trace ('start pid=' + $PID + ' test=' + $env:V4_TEST_MODE + ' ps=' + $PSVersionTable.PSVersion + ' powershell=' + (Get-Command powershell.exe).Source)

function Fail([string]$Message) {
    @{ ok = $false; exitCode = 40; detail = $Message; scriptStarted = $true; liveRegistryTouched = $false } |
        ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $WorkRoot 'result.json') -Encoding UTF8
    exit 2
}

$work = [System.IO.Path]::GetFullPath($WorkRoot)
$engine = [System.IO.Path]::GetFullPath($EngineRoot)
$temp = [System.IO.Path]::GetFullPath($env:TEMP)
if (-not $work.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)) { throw 'work root must stay inside TEMP' }
if ($work.StartsWith($engine, [StringComparison]::OrdinalIgnoreCase)) { throw 'work root must not sit inside the engine' }
$rollbackSource = Join-Path $engine 'proxy_v4\rollback-v4.ps1'
$librarySource = Join-Path $engine 'proxy_v4\lib\V4.ps1'
if (-not (Test-Path -LiteralPath $rollbackSource) -or -not (Test-Path -LiteralPath $librarySource)) {
    throw 'engine root does not contain proxy_v4 rollback and V4.ps1'
}

$env:V4_TEST_MODE = '1'
$env:V4_TEST_ROOT = $work
$app = Join-Path $work 'appdata'
$snap = Join-Path $work 'snapshot'
New-Item -ItemType Directory -Path (Join-Path $app 'profiles') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $work 'lib') -Force | Out-Null
$beforeProfile = "fixture-profile-before`n"
$profile = Join-Path $app 'profiles.yaml'
[System.IO.File]::WriteAllText($profile, $beforeProfile)
Copy-Item -LiteralPath $rollbackSource -Destination (Join-Path $work 'rollback-v4.ps1')
Copy-Item -LiteralPath $librarySource -Destination (Join-Path $work 'lib\V4.ps1')

$env:V4_TEST_APPDATA = $app
$env:V4_TEST_PROXY_ENABLE = '0'
$env:V4_TEST_PROXY_SERVER = 'old:8080'
$env:V4_FIXTURE_PROXY_WRITE_LOG = Join-Path $work 'proxy-write.log'
Trace 'snapshot-begin'
. $librarySource
$null = New-V4SnapshotFiles -AppData $app -ProfilesDir (Join-Path $app 'profiles') -Dir $snap -SystemProxy ([pscustomobject]@{ enabled = $true; server = 'old:8080' }) -ClashRunningBefore $false -Reason 'desktop-isolated'
Trace 'snapshot-end'
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
$result = [ordered]@{
    ok = ($code -eq 32)
    exitCode = [int]$code
    writes = [string]$writes
    journalRemains = [bool](Test-Path -LiteralPath (Join-Path $work 'config\transaction.json'))
    profileRestored = ($restoredHash -eq $expectedHash)
    detail = $tail
    scriptStarted = $true
    liveRegistryTouched = $false
}
[System.IO.File]::WriteAllText((Join-Path $work 'result.json'), ($result | ConvertTo-Json -Compress))
exit 0
