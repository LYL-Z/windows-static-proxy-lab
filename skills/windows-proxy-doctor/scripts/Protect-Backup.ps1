#Requires -Version 5.1
<#
Create a DPAPI (CurrentUser) encrypted copy of a backup directory.
Default is a dry run. -Apply is required to write.
Plaintext originals are not deleted.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$OutFile,
    [switch]$Apply
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Path -PathType Container)) { Write-Error 'backup directory not found'; exit 3 }
if (-not $Apply) {
    Write-Host ('DRY RUN: would zip ' + $Path + ' and encrypt to ' + $OutFile)
    Write-Host 'Re-run with -Apply. No files changed.'
    exit 0
}
if (Test-Path -LiteralPath $OutFile) { Write-Error 'output already exists; refusing overwrite'; exit 3 }
Add-Type -AssemblyName System.Security
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('wpdoctor-' + [guid]::NewGuid().ToString('N') + '.zip')
try {
    Compress-Archive -Path (Join-Path $Path '*') -DestinationPath $tmp -CompressionLevel Optimal
    $zipHash = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash
    $bytes = [System.IO.File]::ReadAllBytes($tmp)
    $enc = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    [System.IO.File]::WriteAllBytes($OutFile, $enc)
    $manifest = [ordered]@{
        schema = 1
        ts = (Get-Date).ToString('o')
        source = (Resolve-Path -LiteralPath $Path).Path
        zipSha256 = $zipHash
        encryptedSha256 = (Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash
        scope = 'CurrentUser-DPAPI'
        note = 'Plaintext originals are not deleted.'
    }
    [System.IO.File]::WriteAllText(($OutFile + '.json'), ($manifest | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ('ENCRYPTED ' + $OutFile + ' zipSha256=' + $zipHash)
    exit 0
}
finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
