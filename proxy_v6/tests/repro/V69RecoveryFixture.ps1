# Appended only to a temporary copy of V4.ps1 by V69Recovery.py.
if (-not $script:TestMode) { throw 'isolated root required' }
$script:probeCount = 0
$script:selectionFile = Join-Path $script:Root 'selection.json'
function Read-FixtureSelection { Get-Content -LiteralPath $script:selectionFile -Raw | ConvertFrom-Json }
function Write-FixtureSelection($value) {
    [IO.File]::WriteAllText($script:selectionFile, ($value | ConvertTo-Json -Compress))
}
function Trace-Fixture($label) {
    [IO.File]::AppendAllText((Join-Path $script:Root 'events'), $label + [Environment]::NewLine)
}
function Get-V4Settings {
    param([switch]$StatusOnly)
    Trace-Fixture ('settings-status-only=' + [bool]$StatusOnly)
    @{host='203.0.113.10'; hopPort=19321; mixedPort=19322}
}
function Get-V4Paths { @{AppData=$script:Root; Core='fixture.exe'} }
function Get-V4Integrity { @{markerOk=$true; runtimeMarkerOk=$true; profileHash='fixture'} }
function Get-V4UiSystemProxy { $true }
function Get-V4AutomaticProxyStatus { 'NOT_OBSERVED' }
function Test-V4ClashListener {
    param($Port, $ExpectedCore, [switch]$RequireImagePath)
    if (-not $RequireImagePath) { throw 'repair did not request the full listener image path' }
    return ($env:V69_RECOVERY_CASE -ne 'unknown-image')
}
function Test-V4FirstHop { @{ok=$true; detail='fixture CONNECT'} }
function Get-V4SystemProxy { Read-FixtureSelection }
function Get-V4ExitIp {
    $script:probeCount++
    Trace-Fixture ('probe-' + $script:probeCount)
    if ($script:probeCount -eq 2) {
        switch ($env:V69_RECOVERY_CASE) {
            'post-exit-mismatch' { return '198.51.100.20' }
            'rollback-error' { return $null }
            'external-disable' {
                $selection = Read-FixtureSelection
                $selection.enabled = $false
                Write-FixtureSelection $selection
                Trace-Fixture 'user-disabled'
            }
        }
    }
    if ($env:V69_RECOVERY_CASE -eq 'ambiguous-probe') { return @('203.0.113.10','203.0.113.10') }
    return '203.0.113.10'
}
function Stop-V4Clash { Trace-Fixture 'unexpected-restart'; throw 'unexpected stop' }
function Start-V4Clash { Trace-Fixture 'unexpected-restart'; throw 'unexpected start' }
Set-V4TestRegistryWriter {
    param($Enabled,$Server)
    $selection = Read-FixtureSelection
    Trace-Fixture ('write-' + $Server)
    if ($env:V69_RECOVERY_CASE -eq 'rollback-error' -and $Server -eq '127.0.0.1:19321') {
        throw 'injected restore failure'
    }
    $selection.server = $Server
    $selection.enabled = $Enabled
    Write-FixtureSelection $selection
    if ($env:V69_RECOVERY_CASE -eq 'interrupted' -and $Server -eq '127.0.0.1:19322') {
        [Environment]::Exit(91)
    }
    if ($env:V69_RECOVERY_CASE -eq 'partial-setter' -and $Server -eq '127.0.0.1:19322') {
        throw 'notification failed after target write'
    }
}
