#Requires -Version 5.1
<#
  Counts sensitive-looking tracked text without printing the matches.
#>
param([string]$Repo = (Get-Location).Path, [string]$Revision = 'HEAD')
$ErrorActionPreference = 'Stop'
$files = @(git -C $Repo ls-tree -r --name-only $Revision)
$counts = [ordered]@{ files = 0; privatePathFiles = 0; publicAddressFiles = 0; mailFiles = 0; privateKeyFiles = 0; passwordLiteralFiles = 0 }
$reserved = { param($ip)
    if ($ip -match '^(0\.|10\.|127\.|192\.168\.|169\.254\.|203\.0\.113\.|198\.51\.100\.|192\.0\.2\.)') { return $true }
    if ($ip -match '^172\.(1[6-9]|2[0-9]|3[0-1])\.') { return $true }
    if ($ip -match '^255\.|^224\.|^100\.64\.') { return $true }
    return $false
}
foreach ($rel in $files) {
    if ($rel -match '\.(png|jpg|jpeg|gif|webp|zip|exe|dll|pdb)$') { continue }
    $counts.files++
    $text = git -C $Repo show --no-textconv ($Revision + ':' + $rel) 2>$null
    if (-not $text) { continue }
    $blob = $text | Out-String
    if ($blob -match '[A-Za-z]:\\Users\\') { $counts.privatePathFiles++ }
    $ips = [regex]::Matches($blob, '\b(?:\d{1,3}\.){3}\d{1,3}\b') | ForEach-Object { $_.Value }
    $public = $false
    foreach ($ip in $ips) { if (-not (& $reserved $ip)) { $public = $true; break } }
    if ($public) { $counts.publicAddressFiles++ }
    if ($blob -match '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}') { $counts.mailFiles++ }
    if ($blob -match 'BEGIN [A-Z ]*PRIVATE KEY') { $counts.privateKeyFiles++; Write-Host ('private-key-file=' + $rel) }
    if ($blob -match '(?i)(password|passwd|secret)\s*[:=]\s*\S+') { $counts.passwordLiteralFiles++ }
}
$counts.GetEnumerator() | ForEach-Object { Write-Host ($_.Key + '=' + $_.Value) }
