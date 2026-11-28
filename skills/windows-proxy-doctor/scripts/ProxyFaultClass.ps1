#Requires -Version 5.1
<#
Pure classification of proxy observations supplied by the caller.
No registry, process, socket, or network access. No setting changes,
no repair, and no elevation.
#>

function Get-ProxyDoctorFaultNote {
    'An alert or UI status is not proof the network was blocked.'
}

function Get-ProxyDoctorFaultField($Object, [string]$Name) {
    $missing = [pscustomobject]@{ State = 'missing'; Value = $null }
    if ($null -eq $Object) { return $missing }
    $present = $false
    $raw = $null
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { $present = $true; $raw = $Object[$Name] }
    } else {
        $property = $Object.PSObject.Properties[$Name]
        if ($null -ne $property) { $present = $true; $raw = $property.Value }
    }
    if (-not $present -or $null -eq $raw) { return $missing }
    if ($raw -is [bool]) { return [pscustomobject]@{ State = 'bool'; Value = [bool]$raw } }
    return [pscustomobject]@{ State = 'invalid'; Value = $null }
}

function New-ProxyDoctorFaultResult([string]$Class, [string]$Advice) {
    [pscustomobject][ordered]@{
        class = $Class
        advice = $Advice
        recommendRestore = $false
        applicationSuccess = $false
        note = (Get-ProxyDoctorFaultNote)
    }
}

function ConvertTo-ProxyDoctorFaultObservation($Environment) {
    $proxy = $null
    $clients = $null
    if ($null -ne $Environment) {
        $proxy = $Environment.proxy
        $clients = $Environment.clients
    }
    $observation = @{}
    foreach ($pair in @(
        @{ From = 'manualEnabled'; To = 'proxyEnabled' },
        @{ From = 'clashSavedEnabled'; To = 'uiEnabled' },
        @{ From = 'pacConfigured'; To = 'pacConfigured' }
    )) {
        $read = Get-ProxyDoctorFaultField $proxy $pair.From
        if ($read.State -eq 'invalid') { $observation.invalidEvidence = $true }
        elseif ($read.State -eq 'bool') { $observation[$pair.To] = $read.Value }
    }
    $other = Get-ProxyDoctorFaultField $proxy 'targetIsOtherProcess'
    $listening = Get-ProxyDoctorFaultField $proxy 'targetListenerObserved'
    if ($other.State -eq 'invalid' -or $listening.State -eq 'invalid') { $observation.invalidEvidence = $true }
    $clientName = $null
    $clientRaw = $null
    $clientPresent = $false
    if ($proxy -is [System.Collections.IDictionary]) {
        if ($proxy.Contains('targetClient')) { $clientPresent = $true; $clientRaw = $proxy['targetClient'] }
    } elseif ($null -ne $proxy) {
        $clientProperty = $proxy.PSObject.Properties['targetClient']
        if ($null -ne $clientProperty) { $clientPresent = $true; $clientRaw = $clientProperty.Value }
    }
    if ($clientPresent -and $clientRaw -is [string] -and $clientRaw) { $clientName = $clientRaw }
    if ($other.Value -eq $true) { $observation.proxyTargetsExpected = $false }
    elseif ($listening.Value -eq $true -and $clientName -in @('clashVerge', 'mihomo')) { $observation.proxyTargetsExpected = $true }

    $sawCore = $false
    $coreUp = $false
    foreach ($name in @('mihomo', 'clashVerge')) {
        $client = $null
        if ($clients -is [System.Collections.IDictionary]) {
            if ($clients.Contains($name)) { $client = $clients[$name] }
        } elseif ($null -ne $clients) { $client = $clients.$name }
        $running = Get-ProxyDoctorFaultField $client 'running'
        if ($running.State -eq 'invalid') { $observation.invalidEvidence = $true }
        elseif ($running.State -eq 'bool') { $sawCore = $true; if ($running.Value) { $coreUp = $true } }
    }
    if ($sawCore) { $observation.coreRunning = $coreUp }
    return ,$observation
}

function Get-ProxyDoctorFaultClass($Observation) {
    # Explicit user-off wins, including when the core or first hop is also down.
    # Both saved choice and Windows being off is user-off unless the caller says
    # the user did not turn it off. Drift is next, then core, then first hop.
    # ALIGNED means those local observations agree. It is not application success.
    $invalid = Get-ProxyDoctorFaultField $Observation 'invalidEvidence'
    if ($invalid.State -eq 'invalid' -or $invalid.Value -eq $true) {
        return (New-ProxyDoctorFaultResult 'UNKNOWN' 'The observation does not identify one of the known causes.')
    }
    $names = @(
        'userTurnedProxyOff', 'proxyEnabled', 'uiEnabled', 'pacConfigured', 'proxyTargetsExpected',
        'coreRunning', 'mixedPortOpen', 'mixedIPv4CoreOwned', 'firstHopExpected', 'firstHopOpen'
    )
    $field = @{}
    foreach ($name in $names) {
        $read = Get-ProxyDoctorFaultField $Observation $name
        if ($read.State -eq 'invalid') {
            return (New-ProxyDoctorFaultResult 'UNKNOWN' 'The observation does not identify one of the known causes.')
        }
        $field[$name] = $read
    }

    if ($field.userTurnedProxyOff.Value -eq $true) {
        return (New-ProxyDoctorFaultResult 'USER_OFF' 'The user turned the proxy off. Keep the proxy off.')
    }
    if ($field.pacConfigured.Value -ne $false) {
        return (New-ProxyDoctorFaultResult 'UNKNOWN' 'The observation does not identify one of the known causes.')
    }
    if ($field.proxyEnabled.State -ne 'bool' -or $field.uiEnabled.State -ne 'bool') {
        return (New-ProxyDoctorFaultResult 'UNKNOWN' 'The observation does not identify one of the known causes.')
    }
    if ($field.proxyEnabled.Value -eq $false -and $field.uiEnabled.Value -eq $false) {
        if ($field.userTurnedProxyOff.Value -eq $false) {
            return (New-ProxyDoctorFaultResult 'PROXY_DRIFT' 'Windows and the saved client choice are off, but the user did not turn the proxy off. Confirm who changed them before any edit.')
        }
        if ($field.userTurnedProxyOff.Value -ne $true) {
            return (New-ProxyDoctorFaultResult 'OBSERVED_OFF' 'Windows and the saved client choice are off. No recorded user decision was supplied, so do not turn the proxy on and do not treat this as confirmed intent.')
        }
        return (New-ProxyDoctorFaultResult 'USER_OFF' 'The user turned the proxy off. Keep the proxy off.')
    }
    if ($field.proxyEnabled.Value -ne $field.uiEnabled.Value -or $field.proxyTargetsExpected.Value -eq $false) {
        return (New-ProxyDoctorFaultResult 'PROXY_DRIFT' 'The Windows proxy selection differs from the saved client choice. Confirm the intended setting before any change.')
    }
    if ($field.proxyTargetsExpected.Value -ne $true) {
        return (New-ProxyDoctorFaultResult 'UNKNOWN' 'The observation does not identify one of the known causes.')
    }
    if ($field.coreRunning.Value -eq $false -or $field.mixedPortOpen.Value -eq $false) {
        return (New-ProxyDoctorFaultResult 'CORE_DOWN' 'The local proxy core or its listener is down. Check that process and listening port before changing Windows settings.')
    }
    if ($field.coreRunning.Value -ne $true -or $field.mixedPortOpen.Value -ne $true -or $field.mixedIPv4CoreOwned.Value -ne $true) {
        return (New-ProxyDoctorFaultResult 'UNKNOWN' 'The observation does not identify one of the known causes.')
    }
    if ($field.firstHopExpected.Value -eq $false -or $field.firstHopOpen.Value -eq $true) {
        return (New-ProxyDoctorFaultResult 'ALIGNED' 'Local proxy settings and listeners agree. This is not application success.')
    }
    if ($field.firstHopOpen.Value -eq $false) {
        return (New-ProxyDoctorFaultResult 'FIRST_HOP_DOWN' 'The first-hop listener is down while the local proxy core is up. Check the first hop separately from the core.')
    }
    return (New-ProxyDoctorFaultResult 'UNKNOWN' 'The observation does not identify one of the known causes.')
}

function Resolve-ProxyDoctorUserRequest([string]$Text) {
    $value = if ($null -eq $Text) { '' } else { $Text.Trim() }
    $keepOriginal = -join @([char]0x4FDD, [char]0x6301, [char]0x539F, [char]0x914D, [char]0x7F6E)
    $keepCurrent = -join @([char]0x4FDD, [char]0x7559, [char]0x73B0, [char]0x6709, [char]0x914D, [char]0x7F6E)
    $preserveCurrent = -join @([char]0x4FDD, [char]0x6301, [char]0x73B0, [char]0x6709, [char]0x914D, [char]0x7F6E)
    $doNotModify = -join @([char]0x4E0D, [char]0x64C5, [char]0x81EA, [char]0x4FEE, [char]0x6539)
    $doNotChange = -join @([char]0x4E0D, [char]0x8981, [char]0x4FEE, [char]0x6539)
    if ($value.Contains($keepOriginal) -or $value.Contains($keepCurrent) -or $value.Contains($preserveCurrent) -or
        $value.Contains($doNotModify) -or $value.Contains($doNotChange)) {
        return [pscustomobject][ordered]@{
            goal = 'NoModify'
            intent = 'no-modify'
            entry = $null
            classify = $null
            script = $null
            authorization = 'do-not-modify'
        }
    }
    $proxy = -join @([char]0x4EE3, [char]0x7406)
    $faultPhrases = @(
        -join @([char]0x6CA1, [char]0x6709, [char]0x6B63, [char]0x5E38, [char]0x5DE5, [char]0x4F5C),
        -join @([char]0x4E0D, [char]0x6B63, [char]0x5E38, [char]0x5DE5, [char]0x4F5C),
        -join @([char]0x65E0, [char]0x6CD5, [char]0x6B63, [char]0x5E38, [char]0x5DE5, [char]0x4F5C),
        -join @([char]0x4E0D, [char]0x80FD, [char]0x6B63, [char]0x5E38, [char]0x5DE5, [char]0x4F5C)
    )
    $fault = $false
    if ($value.Contains($proxy)) {
        foreach ($phrase in $faultPhrases) {
            if ($value.Contains($phrase)) { $fault = $true }
        }
    }
    if ($value -match '(?i)why\s+(?:isn''t|is not|doesn''t|does not)\s+(?:my\s+|the\s+)?proxy\s+(?:work|working)\b') { $fault = $true }
    if ($value -match '(?i)why\s+(?:is|does)\s+(?:my\s+|the\s+)?proxy\s+not\s+(?:work|working)\b') { $fault = $true }
    if ($value -match '(?i)\bproxy\s+(?:is\s+not|isn''t|does\s+not|doesn''t)\s+working\b') { $fault = $true }
    if ($value -match '(?i)\b(?:check|diagnose)\b.{0,48}\bproxy\b.{0,48}\b(?:not working|broken)\b') { $fault = $true }
    $reopened = -join @([char]0x5DF2, [char]0x7ECF, [char]0x91CD, [char]0x65B0, [char]0x5F00, [char]0x542F)
    $noTraffic = -join @([char]0x6CA1, [char]0x6709, [char]0x6D41, [char]0x91CF)
    $mentionsStarSky = $value.IndexOf('StarSky', [StringComparison]::OrdinalIgnoreCase) -ge 0
    $mentionsClash = $value.IndexOf('Clash', [StringComparison]::OrdinalIgnoreCase) -ge 0
    if ($mentionsStarSky -and $mentionsClash -and $value.Contains($reopened) -and $value.Contains($noTraffic)) { $fault = $true }
    $configCheck = -join @([char]0x7535, [char]0x8111, [char]0x7F51, [char]0x7EDC, [char]0x914D, [char]0x7F6E, [char]0x662F, [char]0x5426, [char]0x6B63, [char]0x5E38)
    if ($value.Contains($configCheck)) { $fault = $true }
    $networkFault = -join @([char]0x7F51, [char]0x7EDC, [char]0x6545, [char]0x969C)
    $recoveryPlan = -join @([char]0x6062, [char]0x590D, [char]0x65B9, [char]0x6848)
    if ($value.Contains($networkFault) -and $value.Contains($recoveryPlan)) { $fault = $true }
    if ($value -match '(?i)starsky.+clash.+(?:no traffic|without traffic)') { $fault = $true }
    $checkMyNetwork = -join @([char]0x68C0, [char]0x67E5, [char]0x6211, [char]0x7684, [char]0x7F51, [char]0x7EDC)
    $checkNetwork = -join @([char]0x68C0, [char]0x67E5, [char]0x7F51, [char]0x7EDC)
    if ($value.Contains($checkMyNetwork) -or $value.Contains($checkNetwork) -or $value -match '(?i)\bcheck (?:my|the) network\b') { $fault = $true }
    $stopped = -join @([char]0x505C, [char]0x6B62, [char]0x8FD0, [char]0x884C)
    if ($mentionsStarSky -and $value.Contains($stopped)) { $fault = $true }
    if ($mentionsClash -and $value.Contains($noTraffic)) { $fault = $true }
    $checkAbnormal = -join @([char]0x68C0, [char]0x67E5, [char]0x5F02, [char]0x5E38)
    if ($value.Contains($checkAbnormal) -and $value.Contains($recoveryPlan)) { $fault = $true }
    if ($fault) {
        return [pscustomobject][ordered]@{
            goal = 'Diagnose'
            intent = 'diagnose'
            entry = 'scripts/Start-ProxyDoctor.ps1 -Goal Diagnose'
            classify = 'Get-ProxyDoctorFaultClass'
            script = 'scripts/ProxyFaultClass.ps1'
            authorization = 'read-only until the user accepts one specific change'
        }
    }
    [pscustomobject][ordered]@{
        goal = 'Unspecified'
        intent = 'unspecified'
        entry = $null
        classify = $null
        script = $null
        authorization = $null
    }
}
