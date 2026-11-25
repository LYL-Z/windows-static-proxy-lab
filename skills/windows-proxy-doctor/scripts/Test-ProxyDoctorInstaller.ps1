#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InstallerPath,
    [Parameter(Mandatory)][uri]$SourceUrl,
    [ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$ExpectedSha256,
    [ValidatePattern('^[0-9A-Fa-f]{40}$')][string]$ExpectedSignerThumbprint,
    [switch]$Json
)
$ErrorActionPreference = 'Stop'
if (-not $SourceUrl.IsAbsoluteUri -or $SourceUrl.Scheme -ne 'https' -or -not $SourceUrl.Host -or
    $SourceUrl.UserInfo -or $SourceUrl.Query -or $SourceUrl.Fragment) {
    throw 'Provide a plain HTTPS release or download URL, without credentials, query parameters, or fragments.'
}
$item = Get-Item -LiteralPath $InstallerPath -ErrorAction SilentlyContinue
if ($item -isnot [IO.FileInfo] -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw 'Select an existing regular installer file.'
}
for ($parent = $item.Directory; $parent; $parent = $parent.Parent) {
    if ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Select an installer in a regular directory.'
    }
}
$actualHash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
$signatureStatus = 'UNKNOWN'
$signerThumbprint = $null
try {
    $signature = Get-AuthenticodeSignature -LiteralPath $item.FullName
    $signatureStatus = $signature.Status.ToString()
    if ($signature.SignerCertificate) { $signerThumbprint = $signature.SignerCertificate.Thumbprint }
} catch {
    Write-Verbose 'Windows could not read the Authenticode signature.'
}
$digestMatch = if ($ExpectedSha256) { $actualHash -eq $ExpectedSha256 }
$signerMatch = if ($ExpectedSignerThumbprint) { $signatureStatus -eq 'Valid' -and $signerThumbprint -eq $ExpectedSignerThumbprint }
$status = if ($digestMatch -eq $false -or $signerMatch -eq $false) { 'REJECTED' }
    elseif ($digestMatch -eq $true -or $signerMatch -eq $true) { 'MATCHES_EXPECTED' }
    else { 'UNVERIFIED' }
$result = [ordered]@{
    status = $status
    sha256 = $actualHash
    signatureStatus = $signatureStatus
    expectedDigestMatched = $digestMatch
    expectedSignerMatched = $signerMatch
    sourceAuthenticity = 'REQUIRES_INDEPENDENT_OFFICIAL_SOURCE_CHECK'
    installerExecution = 'NOT_RUN'
}
if ($Json) { $result | ConvertTo-Json -Depth 3 }
else { [pscustomobject]$result }
