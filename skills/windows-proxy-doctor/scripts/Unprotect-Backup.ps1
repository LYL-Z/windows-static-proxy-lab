#Requires -Version 5.1
<#
Verify a Protect-Backup .dpapi file, then decrypt to a new zip path.
Refuses to overwrite. Does not extract or modify the source.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$InFile,
    [Parameter(Mandatory=$true)][string]$OutFile
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $InFile)) { Write-Error 'encrypted file not found'; exit 3 }
if (Test-Path -LiteralPath $OutFile) { Write-Error 'output already exists; refusing overwrite'; exit 3 }
Add-Type -AssemblyName System.Security
$manifestPath = $InFile + '.json'
if (-not (Test-Path -LiteralPath $manifestPath)) { Write-Error 'manifest not found'; exit 3 }
$m = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($m.schema -ne 1 -or $m.scope -ne 'CurrentUser-DPAPI' -or
    $m.encryptedSha256 -notmatch '^[0-9A-Fa-f]{64}$' -or $m.zipSha256 -notmatch '^[0-9A-Fa-f]{64}$') {
    throw 'invalid DPAPI backup manifest'
}
$enc = [System.IO.File]::ReadAllBytes($InFile)
$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $encryptedHash = [BitConverter]::ToString($sha.ComputeHash($enc)).Replace('-', '')
    if ($encryptedHash -ne $m.encryptedSha256) { throw 'encrypted backup hash mismatch' }
    try {
        $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect($enc, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    } catch { throw 'DPAPI decrypt failed (wrong user or corrupt file)' }
    $h = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '')
    if ($h -ne $m.zipSha256) { throw 'zip hash mismatch' }
} finally { $sha.Dispose() }

$destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile)
$output = [System.IO.File]::Open($destination, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
try {
    try {
        $output.Write($bytes, 0, $bytes.Length)
        $output.Flush()
    } finally { $output.Dispose() }
} catch {
    Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
    throw
}
Write-Host ('DECRYPTED ' + $OutFile + ' sha256=' + $h)
exit 0
