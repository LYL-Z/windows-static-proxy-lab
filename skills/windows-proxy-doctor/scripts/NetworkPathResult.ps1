function ConvertFrom-ProxyDoctorCurlResult {
    param([string]$Raw, [int]$ExitCode)
    $origin = $null
    $connect = $null
    if ($Raw -match '^([0-9]{3}) ([0-9]{3})$') {
        $origin = [int]$Matches[1]
        $connect = [int]$Matches[2]
    }
    $status = if ($connect -ge 400) { 'proxy_connect_error' }
        elseif ($ExitCode -ne 0) { 'transport_error' }
        elseif ($origin -ge 400) { 'http_error' }
        elseif ($origin -ge 200 -and $origin -lt 400) { 'ok' }
        else { 'no_http_response' }
    $code = if ($null -ne $origin) { $origin.ToString('000') } else { $null }
    return [ordered]@{ status=$status; code=$code; connectCode=$connect; curlExit=$ExitCode }
}
