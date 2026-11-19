#Requires -Version 5.1
<#
Bounded, foreground monitoring. Reads local state and optionally measures HTTPS
through the expected loopback listener. Emits observations and local alerts.
#>
[CmdletBinding()]
param(
    [ValidateRange(2, 120)][int]$Samples = 12,
    [ValidateRange(2, 30)][int]$IntervalSeconds = 5,
    [ValidateRange(1, 65535)][int]$MixedPort = 7897,
    [ValidateRange(0, 65535)][int]$FirstHopPort = 0,
    [string]$HealthUrl,
    [string]$ApplicationUrl,
    [switch]$IncludeWriterEvidence,
    [switch]$Json,
    [string]$TestFixture
)
$ErrorActionPreference = 'Stop'
$snapshotScript = Join-Path $PSScriptRoot 'Get-ProxyDoctorSnapshot.ps1'
$probeScript = Join-Path $PSScriptRoot 'Test-NetworkPath.ps1'
. (Join-Path $PSScriptRoot 'ProxyRegistryEvents.ps1')

if ($ApplicationUrl -and -not $HealthUrl) { throw 'An application probe requires a separate health endpoint.' }
if ($ApplicationUrl -and $ApplicationUrl -eq $HealthUrl) { throw 'Use distinct health and application endpoints.' }
if ($FirstHopPort -eq $MixedPort) { throw 'Use different mixed and first-hop ports.' }
foreach ($endpoint in @($HealthUrl, $ApplicationUrl) | Where-Object { $_ }) {
    [uri]$uri = $null
    if (-not [uri]::TryCreate($endpoint, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
        throw 'Supply HTTPS probe URLs without credentials, queries or fragments.'
    }
}
$sampleCount = $Samples
if ($TestFixture) {
    if ($HealthUrl -or $ApplicationUrl -or $IncludeWriterEvidence) { throw 'Fixture mode uses supplied observations only.' }
    $decoded = Get-Content -LiteralPath $TestFixture -Raw | ConvertFrom-Json
    $fixtures = @($decoded | Where-Object { $null -ne $_ })
    if ($fixtures.Count -lt 1 -or $fixtures.Count -gt 120) { throw 'Supply 1 through 120 synthetic samples.' }
    $sampleCount = $fixtures.Count
}

function Get-LifecycleState($sample, $health, $application) {
    if ($sample.uiEnabled -eq $false -and $sample.proxyEnabled -eq $false -and $sample.pacConfigured -eq $false) { return 'PROXY_DISABLED' }
    if ($sample.uiEnabled -eq $false -and $sample.proxyEnabled -eq $true -and $sample.pacConfigured -eq $false -and
        $sample.proxyTargetsMixedPort -eq $false) { return 'OTHER_PROXY_SELECTED' }
    if ($sample.proxyEnabled -eq $true -and $sample.pacConfigured -eq $false -and $sample.proxyTargetsMixedPort -eq $false) { return 'PROXY_TARGET_CHANGED' }
    if ($null -ne $sample.uiEnabled -and $null -ne $sample.proxyEnabled -and $sample.uiEnabled -ne $sample.proxyEnabled -and $sample.pacConfigured -eq $false) { return 'PROXY_TOGGLES_DIFFER' }
    if ($sample.coreRunning -eq $false) { return 'CORE_STOPPED' }
    if ($sample.mixedPortOpen -eq $false) { return 'MIXED_LISTENER_MISSING' }
    if ($sample.mixedPortOpen -eq $true -and $sample.mixedIPv4CoreOwned -eq $false) { return 'MIXED_IPV4_CORE_UNVERIFIED' }
    if ($FirstHopPort -and $sample.firstHopOpen -eq $false) { return 'FIRST_HOP_LISTENER_MISSING' }
    if ($sample.pacConfigured -ne $false -or $sample.uiEnabled -ne $true -or $sample.proxyTargetsMixedPort -ne $true -or
        $sample.coreRunning -ne $true -or $sample.mixedIPv4CoreOwned -ne $true -or ($FirstHopPort -and $sample.firstHopOpen -ne $true)) { return 'UNKNOWN' }
    if ($null -eq $health) { return 'LOCAL_READY' }
    if ($health.status -in @('skipped', 'unavailable')) { return 'UNKNOWN' }
    if ($health.status -ne 'ok') { return 'HTTPS_PATH_NOT_READY' }
    if ($null -ne $application -and $application.status -ne 'ok') {
        if ($application.status -in @('skipped', 'unavailable')) { return 'UNKNOWN' }
        return 'APPLICATION_PROBE_FAILED'
    }
    return 'HTTPS_PROBE_OK'
}

function Get-LifecycleAdvice([string]$state) {
    switch -Regex ($state) {
        '^PROXY_(TARGET_CHANGED|TOGGLES_DIFFER)$' { 'Review saved intent and Windows proxy settings. Confirm a single system-proxy owner before using the client UI to restore it.' }
        '^(CORE_STOPPED|MIXED_LISTENER_MISSING|MIXED_IPV4_CORE_UNVERIFIED)$' { 'Check the proxy client UI and its core startup log. If it was closed intentionally, keep it stopped.' }
        '^FIRST_HOP_LISTENER_MISSING$' { 'Check acceleration and reconnect status in the first-hop client UI. Allow its listener and the HTTPS path to recover separately.' }
        '^HTTPS_PATH_NOT_READY$' { 'Check upstream readiness and the probe failure stage in the client logs. A single endpoint cannot identify which upstream failed.' }
        '^APPLICATION_PROBE_FAILED$' { 'The health endpoint responded through the local proxy. Check the application endpoint, routing rule and application-specific proxy selection.' }
        '^UNKNOWN$' { 'Check which settings or socket data could be read. PAC, auto-detection and application overrides require separate checks.' }
    }
}

$previous = $null
$candidate = $null
$confirmed = $null
$same = 0
for ($i = 0; $i -lt $sampleCount; $i++) {
    $health = $null
    $application = $null
    if ($TestFixture) {
        $sample = $fixtures[$i]
        $health = $sample.healthProbe
        $application = $sample.applicationProbe
    } else {
        $sample = & $snapshotScript -AsObject -MixedPort $MixedPort -FirstHopPort $FirstHopPort
        if ($HealthUrl -and $sample.mixedIPv4CoreOwned -eq $true -and $sample.uiEnabled -eq $true -and
            $sample.proxyEnabled -eq $true -and $sample.pacConfigured -eq $false) {
            $urls = @($HealthUrl)
            if ($ApplicationUrl) { $urls += $ApplicationUrl }
            try {
                $measured = & $probeScript -Proxy "http://127.0.0.1:$MixedPort" -Urls $urls -DnsNames @() -Json | ConvertFrom-Json
                if ($measured.http.Count -ne $urls.Count -or @($measured.http | Where-Object { -not $_.status }).Count) {
                    throw 'Probe results are incomplete.'
                }
                $health = $measured.http[0] | Select-Object status, code, failureStage
                if ($ApplicationUrl) { $application = $measured.http[1] | Select-Object status, code, failureStage }
            } catch { $health = @{ status = 'unavailable' } }
        }
    }
    $observed = Get-LifecycleState $sample $health $application
    if ($observed -eq $candidate) { $same++ } else { $candidate = $observed; $same = 1 }
    $transition = $null
    $level = 'sample'
    if ($same -ge 2 -and $observed -ne $confirmed) {
        $transition = [ordered]@{ from = $confirmed; to = $observed }
        $level = if ($observed -in @('UNKNOWN','PROXY_DISABLED','OTHER_PROXY_SELECTED','LOCAL_READY','HTTPS_PROBE_OK')) { 'info' } else { 'warning' }
        $confirmed = $observed
    }

    $settings = [pscustomobject][ordered]@{
        enabled = $sample.proxyEnabled; server = $sample.proxyServer; targetsMixedPort = $sample.proxyTargetsMixedPort
        pacConfigured = $sample.pacConfigured; savedClientIntent = $sample.uiEnabled
    }
    $changes = @(if ($previous) {
        foreach ($name in $settings.PSObject.Properties.Name) {
            if ($settings.$name -cne $previous.proxy.$name) { $name }
        }
    })
    $record = [ordered]@{
        sample = $i + 1; observedAt = $sample.ts; completedAt = (Get-Date).ToString('o'); source = $sample.source
        observed = $observed; confirmed = $confirmed; transition = $transition; level = $level
        proxy = $settings; clientProcessRunning = $sample.processRunning; coreRunning = $sample.coreRunning
        mixedPort = $MixedPort; mixedPortOpen = $sample.mixedPortOpen
        mixedIPv4CoreOwned = $sample.mixedIPv4CoreOwned; mixedPortProcesses = $sample.mixedPortProcesses
        healthProbe = $health; applicationProbe = $application
    }
    if ($FirstHopPort) {
        $record.firstHopPort = $FirstHopPort
        $record.firstHopPortOpen = $sample.firstHopOpen
        $record.firstHopPortProcesses = $sample.firstHopPortProcesses
        $record.firstHopListenerProcessIds = $sample.firstHopListenerProcessIds
    }
    if ($transition) { $record.advice = Get-LifecycleAdvice $observed }
    $listenerChanges = @(if ($previous) {
        foreach ($field in 'clientProcessRunning','coreRunning','mixedPortOpen','mixedIPv4CoreOwned','firstHopPortOpen') {
            if ($record[$field] -ne $previous.$field) { $field }
        }
        if (($record.firstHopListenerProcessIds -join ',') -ne ($previous.firstHopListenerProcessIds -join ',')) { 'firstHopListenerProcessIds' }
    })
    if ($listenerChanges.Count) { $record.listenerChanges = $listenerChanges }
    if ($changes.Count) {
        $record.proxyChange = @{ before = $previous.proxy; after = $settings; fields = $changes; actor = 'unknown' }
        if ($IncludeWriterEvidence -and $null -ne $sample.proxyEnabled -and $null -ne $previous.proxy.enabled -and
            @($changes | Where-Object { $_ -ne 'savedClientIntent' }).Count) {
            $record.writerEvidence = @(Get-ProxyDoctorWriterEvidence | ForEach-Object {
                $source = $_
                $source.events = @($source.events | Where-Object {
                    [DateTimeOffset]$time = [DateTimeOffset]::MinValue
                    [DateTimeOffset]::TryParse($_.timeUtc, [ref]$time) -and
                        $time -ge [DateTimeOffset]$previous.observedAt -and $time -le [DateTimeOffset]$sample.ts
                })
                $source
            })
        }
    }
    $previous = [pscustomobject]$record
    if ($Json) { $record | ConvertTo-Json -Depth 8 -Compress }
    elseif ($level -eq 'warning') { Write-Warning ('{0} {1}. {2}' -f $record.observedAt, $observed, $record.advice) }
    elseif ($i -eq 0 -or $transition -or $changes.Count -or $listenerChanges.Count) {
        $message = '{0} {1}' -f $record.observedAt, $observed
        if ($listenerChanges.Count) { $message += ' | Listener/process observations: ' + ($listenerChanges -join ', ') }
        if ($changes.Count) { $message += ' | Proxy settings changed: ' + ($changes -join ', ') }
        Write-Host $message
    }
    if (-not $TestFixture -and $i -lt ($sampleCount - 1)) { Start-Sleep -Seconds $IntervalSeconds }
}
