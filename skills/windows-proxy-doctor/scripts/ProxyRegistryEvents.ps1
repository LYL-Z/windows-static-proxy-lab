#Requires -Version 5.1

function ConvertFrom-ProxyDoctorRegistryEvent {
    param([xml]$EventXml, [string]$UserSid)

    $system = $EventXml.Event.System
    $fields = @{}
    foreach ($item in $EventXml.Event.EventData.Data) {
        $fields[$item.GetAttribute('Name')] = $item.InnerText
    }

    $key = "$UserSid\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
    $nativeKey = "\REGISTRY\USER\$key"
    $eventId = [string]$system.EventID
    $provider = $system.Provider.GetAttribute('Name')
    if ($eventId -eq '4657' -and $provider -eq 'Microsoft-Windows-Security-Auditing') {
        $eventKey = $fields.ObjectName
        $field = $fields.ObjectValueName
        $image = $fields.ProcessName
    } elseif ($eventId -eq '13' -and $provider -eq 'Microsoft-Windows-Sysmon') {
        $target = $fields.TargetObject -split '\\(?=[^\\]+$)', 2
        if ($target.Count -ne 2) { return }
        $eventKey = $target[0] -replace '^HKU\\', '\REGISTRY\USER\'
        $field = $target[1]
        $image = $fields.Image
    } else { return }

    $manualOrPac = $eventKey -eq $nativeKey -and $field -in @('ProxyEnable', 'ProxyServer', 'ProxyOverride', 'AutoConfigURL', 'AutoDetect')
    $connectionBlob = $eventKey -eq "$nativeKey\Connections" -and $field -in @('DefaultConnectionSettings', 'SavedLegacySettings')
    if (-not ($manualOrPac -or $connectionBlob)) { return }
    $process = [System.IO.Path]::GetFileName($image)
    $processId = $fields.ProcessId
    if ([string]::IsNullOrWhiteSpace($process) -or $process -in @('-', 'Unknown')) { return }
    [pscustomobject]@{
        timeUtc = $system.TimeCreated.GetAttribute('SystemTime')
        source = $provider
        field = $field
        process = $process
        processId = $(if ($processId -match '^(?:0x[0-9a-f]+|[0-9]+)$') { $processId })
        recordId = [string]$system.EventRecordID
    }
}

function Get-ProxyDoctorWriterEvidence {
    $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $start = (Get-Date).AddMinutes(-15)
    $limit = 1000
    $channels = [ordered]@{ 'Security' = 4657; 'Microsoft-Windows-Sysmon/Operational' = 13 }
    foreach ($log in $channels.Keys) {
        $status = 'complete'
        $events = @()
        try {
            $channel = Get-WinEvent -ListLog $log -ErrorAction Stop
            if (-not $channel.IsEnabled) {
                [pscustomobject]@{ log = $log; queryStatus = 'log_disabled'; events = @() }
                continue
            }
            $events = @(Get-WinEvent -FilterHashtable @{ LogName = $log; Id = $channels[$log]; StartTime = $start } -MaxEvents $limit -ErrorAction Stop)
            if ($events.Count -eq $limit) { $status = 'limit_reached' }
        } catch {
            $status = switch -Wildcard ($_.FullyQualifiedErrorId) {
                'NoMatchingEventsFound,*' { 'complete' }
                'NoMatchingLogsFound,*' { 'log_unavailable' }
                default { 'query_unavailable' }
            }
        }
        $matchesInLog = @(foreach ($event in $events) {
            try { ConvertFrom-ProxyDoctorRegistryEvent -EventXml $event.ToXml() -UserSid $sid }
            catch { $status = 'decode_incomplete' }
        })
        [pscustomobject]@{ log = $log; queryStatus = $status; events = $matchesInLog }
    }
}
