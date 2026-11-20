function Get-DoctorVerification {
    param(
        [string]$Source,
        [int[]]$StatusCodes,
        [string]$DiagnosticCode,
        [string]$NetworkStatus,
        [string]$Change,
        [string]$ApplicationObservation,
        [string]$ConfigurationObservation
    )
    $https = if (-not $StatusCodes.Count) { 'NOT_TESTED' }
        elseif (@($StatusCodes | Where-Object { $_ -lt 200 -or $_ -ge 300 }).Count -eq 0) { 'HTTPS_REACHABLE' }
        else { 'PARTIAL_OR_FAILED' }
    $local = switch ($DiagnosticCode) {
        'CHECK_APPLICATION' { 'LOCAL_CHECKS_COMPLETE' }
        'UNKNOWN_LOCAL_STATE' { 'UNKNOWN' }
        default { 'NEEDS_REVIEW' }
    }
    $application = switch ($ApplicationObservation) {
        'UserPassed' { 'USER_OBSERVED_PASS' }
        'UserFailed' { 'USER_OBSERVED_FAIL' }
        'AgentPassed' { 'AGENT_OBSERVED_PASS' }
        'AgentFailed' { 'AGENT_OBSERVED_FAIL' }
        default { 'NOT_TESTED' }
    }
    $configuration = 'NOT_TESTED'
    if ($Change -in @('Reported','RollbackReported')) {
        $configuration = 'PENDING'
        if ($ConfigurationObservation -eq 'AgentMismatch' -or $NetworkStatus -eq 'Broken' -or
            $application -like '*_FAIL' -or $https -eq 'PARTIAL_OR_FAILED') {
            $configuration = 'NEEDS_REVIEW'
        } elseif ($Source -eq 'live-read-only' -and $local -eq 'LOCAL_CHECKS_COMPLETE' -and
            $https -eq 'HTTPS_REACHABLE' -and $application -like '*_PASS' -and $ConfigurationObservation -eq 'AgentMatched') {
            $configuration = if ($Change -eq 'RollbackReported') { 'ROLLBACK_VERIFIED' } else { 'CONFIGURATION_VERIFIED' }
        }
    }
    [ordered]@{
        status = $https
        statusCodes = @($StatusCodes)
        local = $local
        application = $application
        configuration = $configuration
        lifecycle = 'NOT_TESTED'
        userReportedNetwork = $NetworkStatus
    }
}
