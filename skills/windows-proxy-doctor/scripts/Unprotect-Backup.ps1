#Requires -Version 5.1
<#
Decrypt a Protect-Backup .dpapi file to a new zip path and verify its SHA-256.
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
$enc = [System.IO.File]::ReadAllBytes($InFile)
try {
    $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect($enc, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
} catch { Write-Error 'DPAPI decrypt failed (wrong user or corrupt file)'; exit 3 }
$tmp = $OutFile + '.tmp'
[System.IO.File]::WriteAllBytes($tmp, $bytes)
$h = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash
if ($m.zipSha256 -and $h -ne [string]$m.zipSha256) { Remove-Item -LiteralPath $tmp -Force; Write-Error 'zip hash mismatch'; exit 3 }
Move-Item -LiteralPath $tmp -Destination $OutFile
Write-Host ('DECRYPTED ' + $OutFile + ' sha256=' + $h)
exit 0
