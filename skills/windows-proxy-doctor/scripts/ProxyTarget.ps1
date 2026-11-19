# Compare the manual HTTP(S) proxy with the expected loopback listener.
function Test-ProxyDoctorTarget {
    param([string]$Server, [int]$Port)
    if ($Port -lt 1 -or $Port -gt 65535 -or -not $Server) { return $null }
    $expected = '^(?:(?:https?)://)?(?:127\.0\.0\.1|localhost|\[::1\]):' + $Port + '$'
    if (-not $Server.Contains('=')) { return ($Server.Trim() -match $expected) }

    $mapping = @{}
    foreach ($entry in $Server.Split(';')) {
        if (-not $entry.Trim()) { continue }
        $pair = $entry.Split('=', 2)
        if ($pair.Count -ne 2 -or -not $pair[0].Trim() -or $mapping.ContainsKey($pair[0].Trim())) { return $null }
        $mapping[$pair[0].Trim()] = $pair[1].Trim()
    }
    return ($mapping['http'] -match $expected -and $mapping['https'] -match $expected)
}
