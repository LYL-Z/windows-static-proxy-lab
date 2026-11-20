function ConvertFrom-ProxyDoctorCurlResult {
    param([string]$Raw, [int]$ExitCode)
    $origin = $null
    $connect = $null
    if ($Raw -match '^([0-9]{3}) ([0-9]{3})$') {
        $origin = [int]$Matches[1]
        $connect = [int]$Matches[2]
    }
    $status = if ($connect -ge 300) { 'proxy_connect_error' }
        elseif ($ExitCode -ne 0) { 'transport_error' }
        elseif ($origin -ge 400) { 'http_error' }
        elseif ($origin -ge 200 -and $origin -lt 400) { 'ok' }
        else { 'no_http_response' }
    $failureStage = switch ($status) {
        'proxy_connect_error' { 'http_connect' }
        'http_error' { 'http_response' }
        'transport_error' {
            switch ($ExitCode) {
                5 { 'proxy_dns' }
                6 { 'destination_dns' }
                7 { 'connect' }
                28 { 'timeout_stage_unknown' }
                35 { 'tls_handshake' }
                60 { 'tls_certificate' }
                97 { 'proxy_handshake' }
                default { 'transport_stage_unknown' }
            }
        }
        default { $null }
    }
    $code = if ($null -ne $origin) { $origin.ToString('000') } else { $null }
    return [ordered]@{ status=$status; code=$code; connectCode=$connect; curlExit=$ExitCode; failureStage=$failureStage }
}
