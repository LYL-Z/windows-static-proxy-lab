#Requires -Version 5.1
<#
.SYNOPSIS
  Read-only Windows proxy lifecycle classification.
.DESCRIPTION
  -SelfTest classifies in-memory fixtures and does not read the registry or the TCP table.
  Without -SelfTest, the script reads HKCU Internet Settings ProxyEnable, ProxyServer, and
  AutoConfigURL, and lists processes listening on 127.0.0.1:7897 and 127.0.0.1:11119.
  It never changes proxy settings, processes, services, firewall rules, DNS, or routes.
  ProxyServer is printed only when it is exactly 127.0.0.1:7897 or 127.0.0.1:11119.
  AutoConfigURL is reported only as EMPTY or SET.
#>
[CmdletBinding()]
param(
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
$VerbosePreference = 'SilentlyContinue'

$script:CoreServer = '127.0.0.1:7897'
$script:HopServer = '127.0.0.1:11119'
$script:CorePort = 7897
$script:HopPort = 11119
$script:ForbiddenCalls = 0

function ConvertTo-SafeProcessName {
    param([AllowNull()][string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return 'UNKNOWN' }
    $trimmed = $Name.Trim()
    if ($trimmed.Length -gt 64) { return 'REDACTED' }
    if ($trimmed -match '[\\/:]') { return 'REDACTED' }
    if ($trimmed -match '\d{1,3}(\.\d{1,3}){3}') { return 'REDACTED' }
    return $trimmed
}

function ConvertTo-ProxyEnable {
    param($Value)
    if ($null -eq $Value) { return $null }
    $integral = @(
        'System.Byte', 'System.Int16', 'System.UInt16', 'System.Int32',
        'System.UInt32', 'System.Int64', 'System.UInt64'
    )
    if ($integral -notcontains $Value.GetType().FullName) { return $null }
    try { $number = [uint64]$Value }
    catch { return $null }
    if ($number -eq 0 -or $number -eq 1) { return [int]$number }
    return $null
}

function ConvertTo-ReportedServer {
    param([AllowNull()][string]$Server)
    if ($Server -eq $script:CoreServer -or $Server -eq $script:HopServer) { return [string]$Server }
    return 'TARGET_OTHER'
}

function Get-V69ListenerRows {
    param([object[]]$Listeners)
    $seen = @{}
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @($Listeners)) {
        if ($null -eq $entry) { continue }
        $port = 0
        try { $port = [int]$entry.port } catch { continue }
        if ($port -ne $script:CorePort -and $port -ne $script:HopPort) { continue }
        $processName = ConvertTo-SafeProcessName ([string]$entry.processName)
        $key = '{0}|{1}' -f $port, $processName
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $rows.Add([pscustomobject]@{ port = $port; processName = $processName })
    }
    return @($rows.ToArray() | Sort-Object port, processName)
}

function Test-V69Port {
    param([object[]]$Rows, [int]$Port)
    foreach ($row in @($Rows)) {
        if ($null -eq $row) { continue }
        if ([int]$row.port -eq $Port) { return $true }
    }
    return $false
}

function Get-V69Classification {
    param(
        [bool]$SettingsReadable,
        [bool]$ListenersReadable,
        $ProxyEnable,
        [AllowNull()][AllowEmptyString()][string]$ProxyServer,
        [bool]$AutomaticProxyKnown,
        [bool]$AutomaticProxyEmpty,
        [object[]]$Listeners
    )

    $rows = @()
    if ($ListenersReadable) { $rows = @(Get-V69ListenerRows $Listeners) }
    $coreUp = $ListenersReadable -and (Test-V69Port $rows $script:CorePort)
    $hopUp = $ListenersReadable -and (Test-V69Port $rows $script:HopPort)

    $enable = $null
    $reportedServer = $null
    if ($SettingsReadable) {
        $enable = ConvertTo-ProxyEnable $ProxyEnable
        $reportedServer = ConvertTo-ReportedServer $ProxyServer
    }

    $classification = 'UNKNOWN'
    if ($SettingsReadable -and $ListenersReadable -and $null -ne $enable) {
        if ($enable -eq 0) {
            $classification = 'USER_OFF'
        }
        elseif ($enable -eq 1 -and $ProxyServer -eq $script:HopServer -and $coreUp) {
            $classification = 'PROXY_DRIFT'
        }
        elseif ($enable -eq 1 -and $ProxyServer -eq $script:CoreServer -and -not $coreUp) {
            $classification = 'CORE_DOWN'
        }
        elseif ($enable -eq 1 -and $ProxyServer -eq $script:CoreServer -and $coreUp -and -not $hopUp) {
            $classification = 'FIRST_HOP_DOWN'
        }
        elseif ($enable -eq 1 -and $ProxyServer -eq $script:CoreServer -and $coreUp -and $hopUp) {
            $classification = 'ALIGNED'
        }
    }

    $automaticProxy = $null
    if ($AutomaticProxyKnown) {
        $automaticProxy = $(if ($AutomaticProxyEmpty) { 'EMPTY' } else { 'SET' })
    }

    $note = switch ($classification) {
        'USER_OFF' { 'ProxyEnable is 0. This is not a fault to repair.' }
        'PROXY_DRIFT' { 'ProxyEnable is 1 and ProxyServer is 127.0.0.1:11119 while a process is listening on 7897.' }
        'CORE_DOWN' { 'ProxyEnable is 1 and ProxyServer is 127.0.0.1:7897, and nothing is listening on 7897.' }
        'FIRST_HOP_DOWN' { 'ProxyEnable is 1 and ProxyServer is 127.0.0.1:7897. Port 7897 is listening and port 11119 is not.' }
        'ALIGNED' { 'ProxyEnable is 1 and ProxyServer is 127.0.0.1:7897. Both 7897 and 11119 are listening. This does not prove an application path.' }
        default { 'The read failed or the combination is not one of the named classes. No system setting was changed.' }
    }

    $listenerValue = @()
    if ($ListenersReadable -and $rows.Count -gt 0) { $listenerValue = @($rows) }

    return [pscustomobject][ordered]@{
        classification = $classification
        proxyEnable = $enable
        proxyServer = $reportedServer
        automaticProxy = $automaticProxy
        settingsReadable = [bool]$SettingsReadable
        listenersReadable = [bool]$ListenersReadable
        listeners = $listenerValue
        applicationPathProven = $false
        faultToRepair = $false
        note = $note
    }
}

function Get-V69LiveReport {
    $settingsReadable = $false
    $enable = $null
    $server = $null
    $automaticKnown = $false
    $automaticEmpty = $true
    try {
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
        $item = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
        $names = @($item.PSObject.Properties.Name)
        $settingsReadable = $true
        if ($names -contains 'ProxyEnable') { $enable = $item.ProxyEnable }
        if ($names -contains 'ProxyServer') { $server = [string]$item.ProxyServer }
        $automaticKnown = $true
        if ($names -contains 'AutoConfigURL') {
            $autoValue = [string]$item.AutoConfigURL
            $automaticEmpty = [string]::IsNullOrWhiteSpace($autoValue)
            $autoValue = $null
        }
        $item = $null
    }
    catch {
        $settingsReadable = $false
        $enable = $null
        $server = $null
        $automaticKnown = $false
    }

    $listenersReadable = $false
    $listeners = @()
    try {
        $table = @(Get-NetTCPConnection -State Listen -ErrorAction Stop)
        $picked = New-Object System.Collections.Generic.List[object]
        foreach ($row in $table) {
            if ([string]$row.LocalAddress -ne '127.0.0.1') { continue }
            $port = [int]$row.LocalPort
            if ($port -ne $script:CorePort -and $port -ne $script:HopPort) { continue }
            $processName = 'UNKNOWN'
            try {
                $process = Get-Process -Id ([int]$row.OwningProcess) -ErrorAction Stop
                $processName = ConvertTo-SafeProcessName ([string]$process.ProcessName)
            }
            catch { $processName = 'UNKNOWN' }
            $picked.Add([pscustomobject]@{ port = $port; processName = $processName })
        }
        $table = $null
        $listeners = @($picked.ToArray())
        $listenersReadable = $true
    }
    catch {
        $listenersReadable = $false
        $listeners = @()
    }

    return Get-V69Classification -SettingsReadable $settingsReadable -ListenersReadable $listenersReadable `
        -ProxyEnable $enable -ProxyServer $server -AutomaticProxyKnown $automaticKnown `
        -AutomaticProxyEmpty $automaticEmpty -Listeners $listeners
}

function New-V69UnknownDocument {
    param([string]$Mode)
    return [pscustomobject][ordered]@{
        mode = $Mode
        readOnly = $true
        changedSystem = $false
        classification = 'UNKNOWN'
        proxyEnable = $null
        proxyServer = $null
        automaticProxy = $null
        settingsReadable = $false
        listenersReadable = $false
        listeners = @()
        applicationPathProven = $false
        faultToRepair = $false
        note = 'The read failed or the combination is not one of the named classes. No system setting was changed.'
    }
}

function ConvertTo-V69Json {
    param($Value)
    return ($Value | ConvertTo-Json -Depth 6)
}

function Test-V69TextSafe {
    param([string]$Json, [string[]]$Forbidden)
    foreach ($item in @($Forbidden)) {
        if ([string]::IsNullOrEmpty($item)) { continue }
        if ($Json.IndexOf($item, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $false }
    }
    $profile = [Environment]::GetFolderPath('UserProfile')
    if (-not [string]::IsNullOrWhiteSpace($profile) -and
        $Json.IndexOf($profile, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $false }
    return $true
}

function Invoke-V69SelfTest {
    $script:ForbiddenCalls = 0
    function script:Get-ItemProperty { $script:ForbiddenCalls++; throw 'forbidden-read' }
    function script:Get-Item { $script:ForbiddenCalls++; throw 'forbidden-read' }
    function script:Set-ItemProperty { $script:ForbiddenCalls++; throw 'forbidden-read' }
    function script:New-ItemProperty { $script:ForbiddenCalls++; throw 'forbidden-read' }
    function script:Remove-ItemProperty { $script:ForbiddenCalls++; throw 'forbidden-read' }
    function script:Clear-ItemProperty { $script:ForbiddenCalls++; throw 'forbidden-read' }
    function script:Get-NetTCPConnection { $script:ForbiddenCalls++; throw 'forbidden-read' }
    function script:Get-CimInstance { $script:ForbiddenCalls++; throw 'forbidden-read' }
    function script:Get-WmiObject { $script:ForbiddenCalls++; throw 'forbidden-read' }

    $otherServer = 'unexpected.example:8080'
    $paddedServer = '127.0.0.1:7897 '
    $pacSecret = 'fixture-pac-secret'
    $both = @(
        @{ port = 7897; processName = 'fixture-core' }
        @{ port = 11119; processName = 'fixture-hop' }
    )
    $coreOnly = @(@{ port = 7897; processName = 'fixture-core' })
    $hopOnly = @(@{ port = 11119; processName = 'fixture-hop' })
    $none = @()

    $fixtures = @(
        @{
            Name = 'user-off'; Expected = 'USER_OFF'; SettingsReadable = $true; ListenersReadable = $true
            ProxyEnable = [int]0; ProxyServer = $script:CoreServer; AutomaticProxyKnown = $true; AutomaticProxyEmpty = $true
            Listeners = $both; ExpectedServer = $script:CoreServer; ExpectedAutomatic = 'EMPTY'; ExpectedListeners = 2
        }
        @{
            Name = 'user-off-other-target'; Expected = 'USER_OFF'; SettingsReadable = $true; ListenersReadable = $true
            ProxyEnable = [int]0; ProxyServer = $otherServer; AutomaticProxyKnown = $true; AutomaticProxyEmpty = $true
            Listeners = $none; ExpectedServer = 'TARGET_OTHER'; ExpectedAutomatic = 'EMPTY'; ExpectedListeners = 0
        }
        @{
            Name = 'proxy-drift'; Expected = 'PROXY_DRIFT'; SettingsReadable = $true; ListenersReadable = $true
            ProxyEnable = [int]1; ProxyServer = $script:HopServer; AutomaticProxyKnown = $true; AutomaticProxyEmpty = $true
            Listeners = $both; ExpectedServer = $script:HopServer; ExpectedAutomatic = 'EMPTY'; ExpectedListeners = 2
        }
        @{
            Name = 'proxy-drift-core-only'; Expected = 'PROXY_DRIFT'; SettingsReadable = $true; ListenersReadable = $true
            ProxyEnable = [int]1; ProxyServer = $script:HopServer; AutomaticProxyKnown = $true; AutomaticProxyEmpty = $true
            Listeners = $coreOnly; ExpectedServer = $script:HopServer; ExpectedAutomatic = 'EMPTY'; ExpectedListeners = 1
        }
        @{
            Name = 'core-down'; Expected = 'CORE_DOWN'; SettingsReadable = $true; ListenersReadable = $true
            ProxyEnable = [int]1; ProxyServer = $script:CoreServer; AutomaticProxyKnown = $true; AutomaticProxyEmpty = $true
            Listeners = $hopOnly; ExpectedServer = $script:CoreServer; ExpectedAutomatic = 'EMPTY'; ExpectedListeners = 1
        }
        @{
            Name = 'core-down-both-down'; Expected = 'CORE_DOWN'; SettingsReadable = $true; ListenersReadable = $true
            ProxyEnable = [int]1; ProxyServer = $script:CoreServer; AutomaticProxyKnown = $true; AutomaticProxyEmpty = $true
            Listeners = $none; ExpectedServer = $script:CoreServer; ExpectedAutomatic = 'EMPTY'; ExpectedListeners = 0
        }
        @{
            Name = 'first-hop-down'; Expected = 'FIRST_HOP_DOWN'; SettingsReadable = $true; ListenersReadable = $true
            ProxyEnable = [int]1; ProxyServer = $script:CoreServer; AutomaticProxyKnown = $true; AutomaticProxyEmpty = $false
            Listeners = $coreOnly; ExpectedServer = $script:CoreServer; ExpectedAutomatic = 'SET'; ExpectedListeners = 1
        }
        @{
            Name = 'aligned'; Expected = 'ALIGNED'; SettingsReadable = $true; ListenersReadable = $true
            ProxyEnable = [int]1; ProxyServer = $script:CoreServer; AutomaticProxyKnown = $true; AutomaticProxyEmpty = $true
            Listeners = @($both + @{ port = 80; processName = 'fixture-other' })
            ExpectedServer = $script:CoreServer; ExpectedAutomatic = 'EMPTY'; ExpectedListeners = 2
        }
        @{
            Name = 'unknown-settings'; Expected = 'UNKNOWN'; SettingsReadable = $false; ListenersReadable = $true
            ProxyEnable = [int]1; ProxyServer = $otherServer; AutomaticProxyKnown = $false; AutomaticProxyEmpty = $true
            Listeners = $both; ExpectedServer = $null; ExpectedAutomatic = $null; ExpectedListeners = 2
        }
        @{
            Name = 'unknown-listeners'; Expected = 'UNKNOWN'; SettingsReadable = $true; ListenersReadable = $false
            ProxyEnable = [int]0; ProxyServer = $script:CoreServer; AutomaticProxyKnown = $true; AutomaticProxyEmpty = $true
            Listeners = $both; ExpectedServer = $script:CoreServer; ExpectedAutomatic = 'EMPTY'; ExpectedListeners = 0
        }
        @{
            Name = 'unknown-other-target'; Expected = 'UNKNOWN'; SettingsReadable = $true; ListenersReadable = $true
            ProxyEnable = [int]1; ProxyServer = $otherServer; AutomaticProxyKnown = $true; AutomaticProxyEmpty = $true
            Listeners = $both; ExpectedServer = 'TARGET_OTHER'; ExpectedAutomatic = 'EMPTY'; ExpectedListeners = 2
        }
        @{
            Name = 'unknown-hop-without-core'; Expected = 'UNKNOWN'; SettingsReadable = $true; ListenersReadable = $true
            ProxyEnable = [int]1; ProxyServer = $script:HopServer; AutomaticProxyKnown = $true; AutomaticProxyEmpty = $true
            Listeners = $hopOnly; ExpectedServer = $script:HopServer; ExpectedAutomatic = 'EMPTY'; ExpectedListeners = 1
        }
        @{
            Name = 'unknown-padded-server'; Expected = 'UNKNOWN'; SettingsReadable = $true; ListenersReadable = $true
            ProxyEnable = [int]1; ProxyServer = $paddedServer; AutomaticProxyKnown = $true; AutomaticProxyEmpty = $true
            Listeners = $both; ExpectedServer = 'TARGET_OTHER'; ExpectedAutomatic = 'EMPTY'; ExpectedListeners = 2
        }
        @{
            Name = 'unknown-string-enable'; Expected = 'UNKNOWN'; SettingsReadable = $true; ListenersReadable = $true
            ProxyEnable = '0'; ProxyServer = $script:CoreServer; AutomaticProxyKnown = $true; AutomaticProxyEmpty = $true
            Listeners = $none; ExpectedServer = $script:CoreServer; ExpectedAutomatic = 'EMPTY'; ExpectedListeners = 0
        }
    )

    $cases = New-Object System.Collections.Generic.List[object]
    $passedCount = 0
    foreach ($fixture in $fixtures) {
        $report = $null
        $threw = $false
        try {
            $report = Get-V69Classification -SettingsReadable $fixture.SettingsReadable -ListenersReadable $fixture.ListenersReadable `
                -ProxyEnable $fixture.ProxyEnable -ProxyServer $fixture.ProxyServer `
                -AutomaticProxyKnown $fixture.AutomaticProxyKnown -AutomaticProxyEmpty $fixture.AutomaticProxyEmpty `
                -Listeners $fixture.Listeners
        }
        catch {
            $threw = $true
            $report = Get-V69Classification -SettingsReadable $false -ListenersReadable $false -ProxyEnable $null `
                -ProxyServer $null -AutomaticProxyKnown $false -AutomaticProxyEmpty $true -Listeners @()
        }

        $listenerCount = 0
        $caseJson = ''
        try {
            $listenerCount = @($report.listeners).Count
            if ($report.listeners -is [System.Array] -and $report.listeners.Length -eq 0) { $listenerCount = 0 }
            $caseJson = ConvertTo-V69Json $report
        }
        catch { $threw = $true }

        $casePassed = (-not $threw) -and ($report.classification -eq $fixture.Expected) -and
            ($report.proxyServer -eq $fixture.ExpectedServer) -and ($report.automaticProxy -eq $fixture.ExpectedAutomatic) -and
            ($listenerCount -eq $fixture.ExpectedListeners) -and (-not $report.faultToRepair) -and
            (-not $report.applicationPathProven)
        if ($fixture.Expected -eq 'USER_OFF') {
            $casePassed = $casePassed -and ($report.note -eq 'ProxyEnable is 0. This is not a fault to repair.')
        }
        if ($fixture.Expected -eq 'ALIGNED') {
            $casePassed = $casePassed -and ($report.note -like '*does not prove an application path*')
        }
        if ($fixture.ExpectedListeners -eq 0 -and $caseJson -notmatch '"listeners"\s*:\s*\[\s*\]') { $casePassed = $false }
        if ($fixture.ExpectedListeners -eq 1 -and $caseJson -match '"listeners"\s*:\s*\{') { $casePassed = $false }
        if ($fixture.ExpectedListeners -gt 0 -and $caseJson -notmatch '"listeners"\s*:\s*\[') { $casePassed = $false }
        $allowed = @($null, 'TARGET_OTHER', $script:CoreServer, $script:HopServer)
        if ($allowed -notcontains $report.proxyServer) { $casePassed = $false }
        $allowedAuto = @($null, 'EMPTY', 'SET')
        if ($allowedAuto -notcontains $report.automaticProxy) { $casePassed = $false }
        if ($casePassed) { $passedCount++ }

        $cases.Add([pscustomobject][ordered]@{
            name = [string]$fixture.Name
            expected = [string]$fixture.Expected
            passed = [bool]$casePassed
            classification = [string]$report.classification
            proxyEnable = $report.proxyEnable
            proxyServer = $report.proxyServer
            automaticProxy = $report.automaticProxy
            settingsReadable = [bool]$report.settingsReadable
            listenersReadable = [bool]$report.listenersReadable
            listeners = @($report.listeners)
            applicationPathProven = $false
            faultToRepair = [bool]$report.faultToRepair
            note = [string]$report.note
        })
    }

    $required = @('USER_OFF', 'PROXY_DRIFT', 'CORE_DOWN', 'FIRST_HOP_DOWN', 'ALIGNED', 'UNKNOWN')
    $covered = New-Object System.Collections.Generic.List[string]
    foreach ($name in $required) {
        $found = $false
        foreach ($case in $cases) {
            if ($case.passed -and $case.classification -eq $name) { $found = $true }
        }
        if ($found) { [void]$covered.Add($name) }
    }

    $passed = ($passedCount -eq $fixtures.Count -and $covered.Count -eq $required.Count -and $script:ForbiddenCalls -eq 0)
    $document = [pscustomobject][ordered]@{
        mode = 'self-test'
        readOnly = $true
        changedSystem = $false
        registryTouched = ($script:ForbiddenCalls -ne 0)
        passed = [bool]$passed
        caseCount = $fixtures.Count
        passedCount = $passedCount
        classesCovered = @($covered.ToArray())
        cases = @($cases.ToArray())
    }
    $json = ConvertTo-V69Json $document
    $safe = Test-V69TextSafe $json @(
        $otherServer, $paddedServer, $pacSecret, 'fixture-other', 'fixture-pac-secret',
        'CommandLine', 'OwningProcess', 'LocalAddress', 'AutoConfigURL'
    )
    if (-not $safe -or $json -notlike '*not a fault to repair*' -or $json -notlike '*does not prove an application path*') {
        $passed = $false
        $document = [pscustomobject][ordered]@{
            mode = 'self-test'
            readOnly = $true
            changedSystem = $false
            registryTouched = ($script:ForbiddenCalls -ne 0)
            passed = $false
            classification = 'UNKNOWN'
            note = 'Self-test withheld its report because redaction failed. No system setting was changed.'
        }
        $json = ConvertTo-V69Json $document
    }
    return [pscustomobject]@{ Json = $json; ExitCode = $(if ($passed) { 0 } else { 1 }) }
}

if ($SelfTest) {
    $payload = $null
    try { $payload = Invoke-V69SelfTest }
    catch { $payload = $null }
    if ($null -eq $payload -or [string]::IsNullOrWhiteSpace([string]$payload.Json)) {
        $failed = New-V69UnknownDocument -Mode 'self-test'
        $failed | Add-Member -NotePropertyName passed -NotePropertyValue $false -Force
        $failed | Add-Member -NotePropertyName registryTouched -NotePropertyValue $false -Force
        [Console]::Out.WriteLine((ConvertTo-V69Json $failed))
        exit 1
    }
    [Console]::Out.WriteLine($payload.Json)
    exit $payload.ExitCode
}

$liveJson = $null
try {
    $live = Get-V69LiveReport
    $liveDocument = [pscustomobject][ordered]@{
        mode = 'live'
        readOnly = $true
        changedSystem = $false
        classification = [string]$live.classification
        proxyEnable = $live.proxyEnable
        proxyServer = $live.proxyServer
        automaticProxy = $live.automaticProxy
        settingsReadable = [bool]$live.settingsReadable
        listenersReadable = [bool]$live.listenersReadable
        listeners = @($live.listeners)
        applicationPathProven = $false
        faultToRepair = $false
        note = [string]$live.note
    }
    $liveJson = ConvertTo-V69Json $liveDocument
    $profile = [Environment]::GetFolderPath('UserProfile')
    if (-not (Test-V69TextSafe $liveJson @('CommandLine', 'OwningProcess', 'LocalAddress', 'AutoConfigURL', $profile))) {
        $liveJson = ConvertTo-V69Json (New-V69UnknownDocument -Mode 'live')
    }
}
catch {
    $liveJson = ConvertTo-V69Json (New-V69UnknownDocument -Mode 'live')
}
[Console]::Out.WriteLine($liveJson)
exit 0
